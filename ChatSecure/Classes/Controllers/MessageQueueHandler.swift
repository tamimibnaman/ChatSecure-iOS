      //
//  MessageQueueHandler.swift
//  ChatSecure
//
//  Created by David Chiles on 5/4/16.
//  Copyright © 2016 Chris Ballinger. All rights reserved.
//

import Foundation
import YapTaskQueue
      
/// This is just small struct to store the necessary inormation about a message while we wait for delegate callbacks from the XMPPStream
private struct OutstandingMessageInfo {
    let messageKey:String
    let messageCollection:String
    let messageSecurity:OTRMessageTransportSecurity
    let timer:Timer?
    let completion:((_ success: Bool, _ retryTimeout: TimeInterval) -> Void)
}

/// Needed so we can store the struct in a dictionary 
extension OutstandingMessageInfo: Hashable {
    var hashValue: Int {
        get {
            return "\(self.messageKey)\(self.messageCollection)".hashValue
        }
    }
}

extension OutstandingMessageInfo: Equatable {}
private func ==(lhs: OutstandingMessageInfo, rhs: OutstandingMessageInfo) -> Bool {
    return lhs.messageKey == rhs.messageKey && lhs.messageCollection == rhs.messageCollection
}

public class MessageQueueHandler:NSObject {
    
    public var accountRetryTimeout:TimeInterval = 30
    public var otrTimeout:TimeInterval = 7
    public var messageRetryTimeout:TimeInterval = 10
    public var maxFailureCount:UInt = 2
    
    let operationQueue = OperationQueue()
    let databaseConnection:YapDatabaseConnection
    fileprivate var outstandingMessages = [String:OutstandingMessageInfo]()
    fileprivate var outstandingBuddies = [String:OutstandingMessageInfo]()
    fileprivate var outstandingAccounts = [String:Set<OutstandingMessageInfo>]()
    fileprivate let isolationQueue = DispatchQueue(label: "MessageQueueHandler-IsolationQueue", attributes: [])
    fileprivate var accountLoginNotificationObserver:NSObjectProtocol?
    fileprivate var messageStateDidChangeNotificationObserver:NSObjectProtocol?
    
    public init(dbConnection:YapDatabaseConnection) {
        self.databaseConnection = dbConnection
        self.operationQueue.maxConcurrentOperationCount = 1
        super.init()
        self.accountLoginNotificationObserver = NotificationCenter.default.addObserver(forName: NSNotification.Name(rawValue: kOTRProtocolLoginSuccess), object: nil, queue: self.operationQueue, using: { [weak self] (notification) in
            self?.handleAccountLoginNotification(notification)
        })
        self.messageStateDidChangeNotificationObserver = NotificationCenter.default.addObserver(forName: NSNotification.Name.OTRMessageStateDidChange, object: nil, queue: self.operationQueue) {[weak self] (notification) in
            self?.handleMessageStateDidChangeNotification(notification)
        }
    }
    
    deinit {
        if let observer = self.accountLoginNotificationObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        
        if let observer = self.messageStateDidChangeNotificationObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        
    }
    
    //MARK: Access to outstanding messages and account
    
    fileprivate func waitingForAccount(_ accountString:String,messageKey:String,messageCollection:String,messageSecurity:OTRMessageTransportSecurity,completion:@escaping (_ success: Bool, _ retryTimeout: TimeInterval) -> Void) {
        
        self.isolationQueue.async {
            
            // Get the set out or create a new one
            var messageSet = self.outstandingAccounts[accountString]
            if messageSet == nil {
                messageSet = Set<OutstandingMessageInfo>()
            }
            
            // Guarantee set is real
            guard var set = messageSet else {
                return
            }
            // Add new item
            set.insert(OutstandingMessageInfo(messageKey: messageKey, messageCollection: messageCollection,messageSecurity:messageSecurity,timer:nil, completion: completion))
            //Insert back into dictionary
            self.outstandingAccounts.updateValue(set, forKey: accountString)
        }
        
        
    }
    
    fileprivate func popWaitingAccount(_ accountString:String) -> Set<OutstandingMessageInfo>? {
        var messageInfoSet:Set<OutstandingMessageInfo>? = nil
        self.isolationQueue.sync {
            messageInfoSet = self.outstandingAccounts.removeValue(forKey: accountString)
        }
        
        return messageInfoSet
    }
    
    fileprivate func waitingForBuddy(_ buddyKey:String,messageKey:String, messageCollection:String, messageSecurity:OTRMessageTransportSecurity, timer:Timer,completion:@escaping (_ success: Bool, _ retryTimeout: TimeInterval) -> Void) {
        
        let messageInfo = OutstandingMessageInfo(messageKey: messageKey, messageCollection: messageCollection,messageSecurity:messageSecurity, timer:nil, completion: completion)
        
        self.isolationQueue.async { 
            self.outstandingBuddies.updateValue(messageInfo, forKey: buddyKey)
        }
    }
    
    fileprivate func popWaitingBuddy(_ buddyKey:String) -> OutstandingMessageInfo? {
        var messageInfo:OutstandingMessageInfo? = nil
        self.isolationQueue.sync { 
            messageInfo = self.outstandingBuddies.removeValue(forKey: buddyKey)
        }
        return messageInfo
    }
    
    fileprivate func waitingForMessage(_ messageKey:String,messageCollection:String,messageSecurity:OTRMessageTransportSecurity,completion:@escaping (_ success: Bool, _ retryTimeout: TimeInterval) -> Void) {
        let messageInfo = OutstandingMessageInfo(messageKey: messageKey, messageCollection: messageCollection, messageSecurity:messageSecurity, timer:nil, completion: completion)
        let key = "\(messageKey)\(messageCollection)"
        
        self.isolationQueue.async { 
            self.outstandingMessages.updateValue(messageInfo, forKey: key)
        }
    }
    
    /** 
     * Remove a waiting message info from the outstaning message dictionary. After the message info is removed the completion block should be called.
     * This ensures that the outstandingMessages dictionary is accessed from the correct queue.
     * 
     * - parameter messageKey: The yap database messsage key.
     * - parameter messageCollection: The yap database message key.
     * - returns: The OutstandingMessageInfo if one exists. Removed from the waiting dictioanry.
     */
    fileprivate func popWaitingMessage(_ messageKey:String,messageCollection:String) -> OutstandingMessageInfo? {
        var messageInfo:OutstandingMessageInfo? = nil
        let key = "\(messageKey)\(messageCollection)"
        self.isolationQueue.sync { 
            messageInfo = self.outstandingMessages.removeValue(forKey: key)
        }
        
        return messageInfo
    }
    
    //MARK: Database Functions
    
    fileprivate func fetchMessage(_ key:String, collection:String, transaction:YapDatabaseReadTransaction) -> OTROutgoingMessage? {
        
        guard let message = transaction.object(forKey: key, inCollection: collection) as? OTROutgoingMessage else {
            return nil
        }
        return message
    }
    
    fileprivate func fetchSendingAction(_ messageKey:String, messageCollection:String, transaction:YapDatabaseReadTransaction) -> OTRYapMessageSendAction? {
        let key = OTRYapMessageSendAction.actionKey(forMessageKey: messageKey, messageCollection: messageCollection)
        guard let action = OTRYapMessageSendAction.fetch(withUniqueID: key, transaction: transaction) else {
            return nil
        }
        return action
    }
    
    //MARK: XMPPManager functions
    
    fileprivate func sendMessage(_ outstandingMessage:OutstandingMessageInfo) {
        self.operationQueue.addOperation { [weak self] in
            guard let strongSelf = self else { return }
            var msg:OTROutgoingMessage? = nil
            strongSelf.databaseConnection.read({ (transaction) in
                msg = transaction.object(forKey: outstandingMessage.messageKey, inCollection: outstandingMessage.messageCollection) as? OTROutgoingMessage
            })
            
            guard let message = msg else {
                outstandingMessage.completion(true, 0.0)
                return
            }
            
            strongSelf.sendMessage(message, completion: outstandingMessage.completion)
        }
    }
    
    fileprivate func sendMessage(_ message:OTROutgoingMessage, completion:@escaping (_ success: Bool, _ retryTimeout: TimeInterval) -> Void) {
        
        var bud:OTRBuddy? = nil
        var acc:OTRAccount? = nil
        self.databaseConnection.read({ (transaction) in
            bud = OTRBuddy.fetch(withUniqueID: message.buddyUniqueId, transaction: transaction)
            if let accountKey = bud?.accountUniqueId {
                acc = OTRAccount.fetch(withUniqueID: accountKey, transaction: transaction)
            }
            
        })
        guard let buddy = bud,let account = acc else {
            completion(true, 0.0)
            return
        }
        
        //Get the XMPP procol manager associated with this message and therefore account
        guard let accountProtocol = OTRProtocolManager.sharedInstance().protocol(for: account) as? OTRXMPPManager else {
            completion(true, 0.0)
            return
        }
        
        /**
         * Message is considered successuflly sent if the stream responds with didSendMessage.
         * When XEP-0198 is enabled and when an ack is reveived in (x) seconds then it is later makered as failed. It is up to the user to resubmit
         * a msesage to be sent.
         */
        //Some way to store a message dictionary with the key and block
        let messageCollection = OTROutgoingMessage.collection()
        
        
        //Ensure protocol is connected or if not and autologin then connnect
        if (accountProtocol.connectionStatus() == .connected) {
            
            switch message.messageSecurity() {
            case .plaintext:
                self.waitingForMessage(message.uniqueId, messageCollection: messageCollection, messageSecurity:message.messageSecurity(), completion: completion)
                OTRProtocolManager.sharedInstance().send(message)
                break
            case .plaintextWithOTR:
                self.sendOTRMessage(message: message, buddyKey: buddy.uniqueId, buddyUsername: buddy.username, accountUsername: account.username, accountProtocolStrintg: account.protocolTypeString(), requiresActiveSession: false, completion: completion)
                break
            case .OTR:
                self.sendOTRMessage(message: message, buddyKey: buddy.uniqueId, buddyUsername: buddy.username, accountUsername: account.username, accountProtocolStrintg: account.protocolTypeString(), requiresActiveSession: true, completion: completion)
                break
            case .OMEMO:
                self.sendOMEMOMessage(message: message, accountProtocol: accountProtocol, completion: completion)
                break
            }
        } else if (account.autologin == true) {
            self.waitingForAccount(account.uniqueId, messageKey: message.uniqueId, messageCollection: messageCollection, messageSecurity:message.messageSecurity(), completion: completion)
            accountProtocol.connectUserInitiated(false)
        } else {
            // The account might be connected then? even if not auto connecting we might just start up faster then the
            // can enter credentials. Try again in a bit myabe the account will be ready
            
            // Decided that this won't go into the retry failure because we're just waiting on the user to manually connect the account.
            // Not really a 'failure' but we should still try to push the messages through at some point.
            
            completion(false, self.accountRetryTimeout)
        }

    }
    
    //Mark: Callback for Account
    
    fileprivate func handleAccountLoginNotification(_ notification:Notification) {
        guard let userInfo = notification.userInfo as? [String:AnyObject] else {
            return
        }
        if let accountKey = userInfo[kOTRNotificationAccountUniqueIdKey] as? String, let accountCollection = userInfo[kOTRNotificationAccountCollectionKey] as? String  {
            self.didConnectAccount(accountKey, accountCollection: accountCollection)
        }
    }
    
    fileprivate func didConnectAccount(_ accountKey:String, accountCollection:String) {
        
        guard let messageSet = self.popWaitingAccount(accountKey) else {
            return
        }
        
        for messageInfo in messageSet {
            self.sendMessage(messageInfo)
        }
    }
    
    //Mark: Callback for OTRSession
    
    fileprivate func handleMessageStateDidChangeNotification(_ notification:Notification) {
        guard let buddy = notification.object as? OTRBuddy,
            let messageStateInt = (notification.userInfo?[OTRMessageStateKey] as? NSNumber)?.uintValue else {
            return
        }
        
        if  messageStateInt == OTREncryptionMessageState.encrypted.rawValue {
            // Buddy has gone encrypted
            // Check if we have an outstanding messages for this buddy
            guard let messageInfo = self.popWaitingBuddy(buddy.uniqueId) else {
                return
            }
            //Cancle outsanding timer
            messageInfo.timer?.invalidate()
            self.sendMessage(messageInfo)
        }
    }
    
    //Mark: OTR timeout
    @objc public func otrInitatiateTimeout(_ timer:Timer) {
        
        guard let buddyKey = timer.userInfo as? String else {
            return
        }
        
        self.operationQueue.addOperation { [weak self] in
            guard let strongSelf = self else {return}
            
            guard let messageInfo = strongSelf.popWaitingBuddy(buddyKey) else {
                return
            }
            
            let err = NSError.chatSecureError(EncryptionError.unableToCreateOTRSession, userInfo: nil)
            
            strongSelf.databaseConnection.readWrite({ (transaction) in
                if let message = (transaction.object(forKey: messageInfo.messageKey, inCollection: messageInfo.messageCollection)as? OTRBaseMessage)?.copy() as? OTRBaseMessage {
                    message.error = err
                    message.save(with: transaction)
                }
            })
            
            
            messageInfo.completion(true, 0.0)
        }
        
    }
    
    
    
}

//MARK: Callback from protocol
extension MessageQueueHandler: OTRXMPPMessageStatusModuleDelegate {
    
    public func didSendMessage(_ messageKey: String, messageCollection: String) {
        
        guard let messageInfo = self.popWaitingMessage(messageKey, messageCollection: messageCollection) else {
            return;
        }
        
        //Update date sent
        self.databaseConnection.asyncReadWrite { (transaction) in
            guard let object = transaction.object(forKey: messageKey, inCollection: messageCollection) as? NSCopying, let message = object.copy() as? OTROutgoingMessage else {
                return
            }
            message.dateSent = Date()
            message.save(with: transaction)
        }
        
        messageInfo.completion(true, 0.0)
    }
    
    public func didFailToSendMessage(_ messageKey:String, messageCollection:String, error:NSError?) {
        guard let messageInfo = self.popWaitingMessage(messageKey, messageCollection: messageCollection) else {
            return;
        }
        
        //Even though this action failed we need to keep the queue moving.
        messageInfo.completion(true, 0.0)
    }
}
      
//MARK: YapTaskQueueHandler Protocol
extension MessageQueueHandler: YapTaskQueueHandler {
        /** This method is called when an item is available to be exectued. Call completion once finished with the action item.
         
         */
    
    public func handleNextItem(_ action:YapTaskQueueAction, completion:@escaping (_ success:Bool, _ retryTimeout:TimeInterval)->Void) {
        //Get the real message out of the database
        guard let messageSendingAction = action as? OTRYapMessageSendAction else {
            return
        }
        
        let messageKey = messageSendingAction.messageKey
        let messageCollection = messageSendingAction.messageCollection
        var msg:OTROutgoingMessage? = nil
        self.databaseConnection.read { (transaction) in
            msg = self.fetchMessage(messageKey, collection: messageCollection, transaction: transaction)
        }
        
        guard let message = msg else {
            // Somehow we have an action without a message. This is very strange. Do not like.
            // We tell the queue broker that we handle it successfully so it will be rmeoved and go on to the next action.
            completion(true, 0.0)
            return
        }
        
        self.sendMessage(message, completion: completion)
    }
}
      
// Message sending logic
extension MessageQueueHandler {
    typealias MessageQueueHandlerCompletion = (_ success: Bool, _ retryTimeout: TimeInterval) -> Void
    
    func sendOTRMessage(message:OTROutgoingMessage, buddyKey:String, buddyUsername:String, accountUsername:String, accountProtocolStrintg:String, requiresActiveSession:Bool, completion:@escaping MessageQueueHandlerCompletion) {
        
        guard let text = message.text else {
            completion(true, 0.0)
            return
        }
        //We're connected now we need to check encryption requirements
        let otrKit = OTRProtocolManager.sharedInstance().encryptionManager.otrKit
        let otrKitSend = {
            self.waitingForMessage(message.uniqueId, messageCollection: OTROutgoingMessage.collection(), messageSecurity:message.messageSecurity(), completion: completion)
            otrKit.encodeMessage(text, tlvs: nil, username:buddyUsername , accountName: accountUsername, protocol: accountProtocolStrintg, tag: message)
        }
        
        if (requiresActiveSession && otrKit.messageState(forUsername: buddyUsername, accountName: accountUsername, protocol: accountProtocolStrintg) != .encrypted) {
            //We need to initiate an OTR session
            
            //Timeout at some point waiting for OTR session
            DispatchQueue.main.async {
                let timer = Timer.scheduledTimer(timeInterval: self.otrTimeout, target: self, selector: #selector(MessageQueueHandler.otrInitatiateTimeout(_:)), userInfo: buddyKey, repeats: false)
                self.waitingForBuddy(buddyKey, messageKey: message.uniqueId, messageCollection: OTROutgoingMessage.collection(),messageSecurity:message.messageSecurity(), timer:timer, completion: completion)
                otrKit.initiateEncryption(withUsername: buddyUsername, accountName: accountUsername, protocol: accountProtocolStrintg)
            }
        } else {
            // If we need to send it encrypted and we have a session or we don't need to encrypt send out message
            otrKitSend()
        }
    }
    
    func sendOMEMOMessage(message:OTROutgoingMessage, accountProtocol:OTRXMPPManager,completion:@escaping MessageQueueHandlerCompletion) {
        guard let text = message.text else {
            completion(true, 0.0)
            return
        }
        
        guard let signalCoordinator = accountProtocol.omemoSignalCoordinator else {
            self.databaseConnection.asyncReadWrite({ (transaction) in
                guard let message = OTROutgoingMessage.fetch(withUniqueID: message.uniqueId, transaction: transaction)?.copy() as? OTROutgoingMessage else {
                    return
                }
                message.error = NSError.chatSecureError(EncryptionError.omemoNotSuported, userInfo: nil)
                message.save(with: transaction)
            })
            completion(true, 0.0)
            return
        }
        self.waitingForMessage(message.uniqueId, messageCollection: OTROutgoingMessage.collection(), messageSecurity:message.messageSecurity(), completion: completion)
        
        
        
        signalCoordinator.encryptAndSendMessage(text, buddyYapKey: message.buddyUniqueId, messageId: message.messageId, completion: { [weak self] (success, error) in
            guard let strongSelf = self else {
                return
            }
            
            if (success == false) {
                //Something went wrong getting ready to send the message
                //Save error object to message
                strongSelf.databaseConnection.readWrite({ (transaction) in
                    guard let message = OTROutgoingMessage.fetch(withUniqueID: message.uniqueId, transaction: transaction)?.copy() as? OTROutgoingMessage else {
                        return
                    }
                    message.error = error
                    message.save(with: transaction)
                })
                
                if let messageInfo = strongSelf.popWaitingMessage(message.uniqueId, messageCollection: type(of: message).collection()) {
                    //Even though we were not succesfull in sending a message. The action needs to be removed from the queue so the next message can be handled.
                    messageInfo.completion(true, 0.0)
                }
            }
            })
    }
}
