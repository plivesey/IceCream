//
//  DatabaseManager.swift
//  IceCream
//
//  Created by caiyue on 2019/4/22.
//

import CloudKit

public protocol DatabaseManager: class {
    
    /// A conduit for accessing and performing operations on the data of an app container.
    var database: CKDatabase { get }
    
    /// An encapsulation of content associated with an app.
    var container: CKContainer { get }
    
    var syncObjects: [Syncable] { get }
    
    init(objects: [Syncable], container: CKContainer)
    
    func prepare()
    
    func fetchChangesInDatabase(_ callback: ((Error?) -> Void)?)
        
    func createCustomZonesIfAllowed()
    func startObservingRemoteChanges()
    func startObservingTermination()
    func createDatabaseSubscriptionIfHaveNot()
    func registerLocalDatabase()
    
    func cleanUp()
}

extension DatabaseManager {
    
    func prepare() {
        syncObjects.forEach {
            $0.pipeToEngine = { [weak self] recordsToStore, recordIDsToDelete in
                guard let self = self else { return }
                self.syncRecordsToCloudKit(recordsToStore: recordsToStore, recordIDsToDelete: recordIDsToDelete)
            }

            $0.pipeToEngine = { [weak self] recordsToStore, recordIDsToDelete in
                guard let self = self else { return }
                self.syncRecordsToCloudKit(recordsToStore: recordsToStore, recordIDsToDelete: recordIDsToDelete, allowsCellularAccess: false)
            }
        }
    }
    
    func startObservingRemoteChanges() {
        NotificationCenter.default.addObserver(forName: Notifications.cloudKitDataDidChangeRemotely.name, object: nil, queue: nil, using: { [weak self](_) in
            guard let self = self else { return }
            DispatchQueue.global(qos: .utility).async {
                self.fetchChangesInDatabase(nil)
            }
        })
    }
    
    /// Sync local data to CloudKit
    /// For more about the savePolicy: https://developer.apple.com/documentation/cloudkit/ckrecordsavepolicy
    /// TODO: This function does not set qualityOfService, timeoutIntervalForRequest or stop retries when there's a completion block. This means this task could run for a while.
    public func syncRecordsToCloudKit(recordsToStore: [CKRecord], recordIDsToDelete: [CKRecord.ID], allowsCellularAccess: Bool = true, completion: ((Error?) -> ())? = nil) {
        let modifyOpe = CKModifyRecordsOperation(recordsToSave: recordsToStore, recordIDsToDelete: recordIDsToDelete)
        
        if #available(iOS 11.0, OSX 10.13, tvOS 11.0, watchOS 4.0, *) {
            let config = CKOperation.Configuration()
            config.isLongLived = true
            config.allowsCellularAccess = allowsCellularAccess
            modifyOpe.configuration = config
        } else {
            // Fallback on earlier versions
            modifyOpe.isLongLived = true
            modifyOpe.allowsCellularAccess = allowsCellularAccess
        }
        
        // We use .changedKeys savePolicy to do unlocked changes here cause my app is contentious and off-line first
        // Apple suggests using .ifServerRecordUnchanged save policy
        // For more, see Advanced CloudKit(https://developer.apple.com/videos/play/wwdc2014/231/)
        modifyOpe.savePolicy = .changedKeys
        
        // To avoid CKError.partialFailure, make the operation atomic (if one record fails to get modified, they all fail)
        // If you want to handle partial failures, set .isAtomic to false and implement CKOperationResultType .fail(reason: .partialFailure) where appropriate
        modifyOpe.isAtomic = true
        
        modifyOpe.modifyRecordsCompletionBlock = {
            [weak self]
            (_, _, error) in
            
            guard let self = self else { return }
            
            switch ErrorHandler.shared.resultType(with: error) {
            case .success:
                DispatchQueue.main.async {
                    completion?(nil)
                }
            case .retry(let timeToWait, _, _):
                ErrorHandler.shared.retryOperationIfPossible(retryAfter: timeToWait) {
                    self.syncRecordsToCloudKit(recordsToStore: recordsToStore, recordIDsToDelete: recordIDsToDelete, completion: completion)
                }
            case .chunk:
                /// CloudKit says maximum number of items in a single request is 400.
                /// So I think 300 should be fine by them.
                let chunkedRecords = recordsToStore.chunkItUp(by: 300)
                for chunk in chunkedRecords {
                    self.syncRecordsToCloudKit(recordsToStore: chunk, recordIDsToDelete: recordIDsToDelete, completion: completion)
                }
            default:
                return
            }
        }
        
        database.add(modifyOpe)
    }
    
}
