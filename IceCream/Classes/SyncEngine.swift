//
//  SyncEngine.swift
//  IceCream
//
//  Created by 蔡越 on 08/11/2017.
//

import CloudKit

/// SyncEngine talks to CloudKit directly.
/// Logically,
/// 1. it takes care of the operations of **CKDatabase**
/// 2. it handles all of the CloudKit config stuffs, such as subscriptions
/// 3. it hands over CKRecordZone stuffs to SyncObject so that it can have an effect on local Realm Database

public final class SyncEngine {

    public let runLoopQueue = RunloopQueue(named: "SyncEngine")
    
    private let databaseManager: DatabaseManager
    
    public convenience init(objects: [Syncable], databaseScope: CKDatabase.Scope = .private, container: CKContainer = .default(), pullComplete: @escaping (Error?) -> Void = { _ in }) {
        switch databaseScope {
        case .private:
            let privateDatabaseManager = PrivateDatabaseManager(objects: objects, container: container)
            self.init(databaseManager: privateDatabaseManager, pullComplete: pullComplete)
        case .public:
            let publicDatabaseManager = PublicDatabaseManager(objects: objects, container: container)
            self.init(databaseManager: publicDatabaseManager, pullComplete: pullComplete)
        case .shared:
            let sharedDatabaseManager = SharedDatabaseManager(objects: objects, container: container)
            self.init(databaseManager: sharedDatabaseManager, pullComplete: pullComplete)
        @unknown default:
            fatalError("This option is not supported yet")
        }

        objects.forEach { $0.runLoopQueue = runLoopQueue }
    }
    
    private init(databaseManager: DatabaseManager, pullComplete: @escaping (Error?) -> Void) {
        self.databaseManager = databaseManager
        setup(pullComplete: pullComplete)
    }
    
    public func setup(pullComplete: @escaping (Error?) -> Void = { _ in }) {
        databaseManager.prepare()
        databaseManager.registerLocalDatabase()

        databaseManager.container.accountStatus { [weak self] (status, error) in
            guard let self = self else { return }
            switch status {
            case .available:
                self.databaseManager.createCustomZonesIfAllowed()
                self.databaseManager.fetchChangesInDatabase(pullComplete)
                // This seems to crash and I don't think it's necessary
//                self.databaseManager.resumeLongLivedOperationIfPossible()
                self.databaseManager.startObservingRemoteChanges()
                self.databaseManager.startObservingTermination()
                self.databaseManager.createDatabaseSubscriptionIfHaveNot()
            case .noAccount, .restricted:
                guard self.databaseManager is PublicDatabaseManager else { break }
                self.databaseManager.fetchChangesInDatabase(pullComplete)
                // This seems to crash and I don't think it's necessary
//                self.databaseManager.resumeLongLivedOperationIfPossible()
                self.databaseManager.startObservingRemoteChanges()
                self.databaseManager.startObservingTermination()
                self.databaseManager.createDatabaseSubscriptionIfHaveNot()
            case .couldNotDetermine:
                // Maybe this should throw an error here, but unclear what useful error there is to return
                pullComplete(nil)
            @unknown default:
                pullComplete(nil)
            }
        }
    }
    
}

// MARK: Public Method
extension SyncEngine {
    
    /// Fetch data on the CloudKit and merge with local
    ///
    /// - Parameter completionHandler: Supported in the `privateCloudDatabase` when the fetch data process completes, completionHandler will be called. The error will be returned when anything wrong happens. Otherwise the error will be `nil`.
    public func pull(completionHandler: ((Error?) -> Void)? = nil) {
        // If completionHandler is nil, keep it that way because it affects how things are fetched
        let completion = completionHandler.map { originalCompletion in
            return { error in
                // Wait for all the run loop tasks to complete before returning
                self.runLoopQueue.async {
                    DispatchQueue.main.async {
                        originalCompletion(error)
                    }
                }
            }
        }

        databaseManager.fetchChangesInDatabase(completion)
    }
    
    /// Push all existing local data to CloudKit
    /// You should NOT to call this method too frequently
    public func pushAll(allowsCellularAccess: Bool = true) {
        databaseManager.syncObjects.forEach { $0.pushLocalObjectsToCloudKit(allowsCellularAccess: allowsCellularAccess) }
    }

    public func syncRecordsToCloudKit(recordsToStore: [CKRecord], recordIDsToDelete: [CKRecord.ID], allowsCellularAccess: Bool = true, completion: ((Error?) -> ())? = nil) {
        databaseManager.syncRecordsToCloudKit(recordsToStore: recordsToStore,
                                              recordIDsToDelete: recordIDsToDelete,
                                              allowsCellularAccess: allowsCellularAccess,
                                              completion: completion)
    }
}

public enum Notifications: String, NotificationName {
    case cloudKitDataDidChangeRemotely
}

public enum IceCreamKey: String {
    /// Tokens
    case databaseChangesTokenKey
    case sharedDatabaseChangesTokenKey
    case zoneChangesTokenKey
    
    /// Flags
    case subscriptionIsLocallyCachedKey
    case sharedSubscriptionIsLocallyCachedKey
    case hasCustomZoneCreatedKey
    
    var value: String {
        return "icecream.keys." + rawValue
    }
}

/// Dangerous part:
/// In most cases, you should not change the string value cause it is related to user settings.
/// e.g.: the cloudKitSubscriptionID, if you don't want to use "private_changes" and use another string. You should remove the old subsription first.
/// Or your user will not save the same subscription again. So you got trouble.
/// The right way is remove old subscription first and then save new subscription.
public enum IceCreamSubscription: String, CaseIterable {
    case cloudKitPrivateDatabaseSubscriptionID = "private_changes"
    case cloudKitPublicDatabaseSubscriptionID = "cloudKitPublicDatabaseSubcriptionID"
    case cloudKitSharedDatabaseSubscriptionID = "shared_changes"
    
    var id: String {
        return rawValue
    }
    
    public static var allIDs: [String] {
        return IceCreamSubscription.allCases.map { $0.rawValue }
    }
}
