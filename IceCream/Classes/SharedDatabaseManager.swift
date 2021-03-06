//
//  SharedDatabaseManager.swift
//  IceCream
//
//  Created by Peter Livesey on 8/15/19.
//  Copyright © 2019 蔡越. All rights reserved.
//

#if os(macOS)
import Cocoa
#else
import UIKit
#endif

import CloudKit

final class SharedDatabaseManager: DatabaseManager {

    let container: CKContainer
    let database: CKDatabase

    let syncObjects: [Syncable]

    public init(objects: [Syncable], container: CKContainer) {
        self.syncObjects = objects
        self.container = container
        self.database = container.sharedCloudDatabase
    }

    func fetchChangesInDatabase(_ callback: ((Error?) -> Void)?) {
        let changesOperation = CKFetchDatabaseChangesOperation(previousServerChangeToken: databaseChangeToken)

        // We assume that the user wants to know about progress here
        if callback != nil {
            changesOperation.qualityOfService = .userInitiated
            changesOperation.timeoutIntervalForRequest = 30
        }

        /// Only update the changeToken when fetch process completes
        changesOperation.changeTokenUpdatedBlock = { [weak self] newToken in
            self?.databaseChangeToken = newToken
        }

        changesOperation.fetchDatabaseChangesCompletionBlock = { newToken, _, error in
            switch ErrorHandler.shared.resultType(with: error) {
            case .success:
                self.databaseChangeToken = newToken
                // Fetch the changes in zone level
                self.fetchChangesInZones(callback)
            case .retry(let timeToWait, _, let error):
                if let callback = callback {
                    // If the user is waiting for this error, then let's not retry and let's return the error
                    callback(error)
                } else {
                    ErrorHandler.shared.retryOperationIfPossible(retryAfter: timeToWait, block: {
                        self.fetchChangesInDatabase(callback)
                    })
                }
            case .recoverableError(let reason, _, let error):
                switch reason {
                case .changeTokenExpired:
                    /// The previousServerChangeToken value is too old and the client must re-sync from scratch
                    self.databaseChangeToken = nil
                    self.fetchChangesInDatabase(callback)
                default:
                    callback?(error)
                }
            case .fail(_, _, let error):
                callback?(error)
            case .chunk:
                callback?(IceCreamError(message: "Unexpected error type: failed to get changes token."))
            }
        }

        database.add(changesOperation)
    }

    func createCustomZonesIfAllowed() {
        // No-op. There's no need to create zones for shared databases because by definition, they should already be created
    }

    func createDatabaseSubscriptionIfHaveNot() {
        #if os(iOS) || os(tvOS) || os(macOS)
        guard !subscriptionIsLocallyCached else { return }
        let subscription = CKDatabaseSubscription(subscriptionID: IceCreamSubscription.cloudKitSharedDatabaseSubscriptionID.id)

        let notificationInfo = CKSubscription.NotificationInfo()
        notificationInfo.shouldSendContentAvailable = true // Silent Push

        subscription.notificationInfo = notificationInfo

        let createOp = CKModifySubscriptionsOperation(subscriptionsToSave: [subscription], subscriptionIDsToDelete: [])
        createOp.modifySubscriptionsCompletionBlock = { _, _, error in
            guard error == nil else { return }
            self.subscriptionIsLocallyCached = true
        }
        createOp.qualityOfService = .utility
        database.add(createOp)
        #endif
    }

    func startObservingTermination() {
        #if os(iOS) || os(tvOS)

        NotificationCenter.default.addObserver(self, selector: #selector(self.cleanUp), name: UIApplication.willTerminateNotification, object: nil)

        #elseif os(macOS)

        NotificationCenter.default.addObserver(self, selector: #selector(self.cleanUp), name: NSApplication.willTerminateNotification, object: nil)

        #endif
    }

    func registerLocalDatabase() {
        self.syncObjects.forEach { object in
            DispatchQueue.main.async {
                object.registerLocalDatabase()
            }
        }
    }

    private func fetchChangesInZones(_ callback: ((Error?) -> Void)? = nil) {
        let changesOp = CKFetchRecordZoneChangesOperation(recordZoneIDs: zoneIds, optionsByRecordZoneID: zoneIdOptions)
        changesOp.fetchAllChanges = true

        // We assume that the user wants to know about progress here
        if callback != nil {
            changesOp.qualityOfService = .userInitiated
            changesOp.timeoutIntervalForRequest = 60
        }

        var changedRecords = [String: [CKRecord]]()
        var deletedRecordIds = [CKRecord.ID]()

        changesOp.recordZoneChangeTokensUpdatedBlock = { [weak self] zoneId, token, _ in
            guard let self = self else { return }
            self.syncObjects.filter { $0.zoneID == zoneId }.forEach { $0.zoneChangesToken = token }
        }

        changesOp.recordChangedBlock = { record in
            /// The Cloud will return the modified record since the last zoneChangesToken, we need to do local cache here.
            /// Handle the record:
            let currentRecords = changedRecords[record.recordType] ?? []
            changedRecords[record.recordType] = currentRecords + [record]
        }

        changesOp.recordWithIDWasDeletedBlock = { recordId, _ in
            deletedRecordIds.append(recordId)
        }

        changesOp.recordZoneFetchCompletionBlock = { (zoneId ,token, _, _, error) in
            switch ErrorHandler.shared.resultType(with: error) {
            case .success:
                self.syncObjects.filter { $0.zoneID == zoneId }.forEach { $0.zoneChangesToken = token }
            case .retry(let timeToWait, _, let error):
                if let callback = callback {
                    // If the user is waiting for this error, then let's not retry and let's return the error
                    callback(error)
                } else {
                    ErrorHandler.shared.retryOperationIfPossible(retryAfter: timeToWait, block: {
                        self.fetchChangesInZones(callback)
                    })
                }
            case .recoverableError(let reason, _, let error):
                switch reason {
                case .changeTokenExpired:
                    /// The previousServerChangeToken value is too old and the client must re-sync from scratch
                    self.syncObjects.filter { $0.zoneID == zoneId }.forEach { $0.zoneChangesToken = nil }
                    self.fetchChangesInZones(callback)
                default:
                    callback?(error)
                }
            case .fail(_, _, let error):
                callback?(error)
            case .chunk:
                callback?(IceCreamError(message: "Unexpected error type: failed to get database changes."))
            }
        }

        changesOp.fetchRecordZoneChangesCompletionBlock = { [weak self] error in
            guard let self = self else {
                callback?(error)
                return
            }

            // Save to the sync objects in order. This way, parents are always added first and children second so there are no dangling references
            for syncObject in self.syncObjects {
                for recordType in syncObject.recordTypes {
                    if let records = changedRecords[recordType] {
                        records.forEach {
                            syncObject.add(record: $0)
                        }

                        changedRecords[recordType] = nil
                    }
                }
            }

            for recordId in deletedRecordIds {
                self.syncObjects.filter { $0.zoneID == recordId.zoneID }.forEach { $0.delete(recordID: recordId) }
            }

            callback?(error)
        }

        database.add(changesOp)
    }
}

extension SharedDatabaseManager {
    /// The changes token, for more please reference to https://developer.apple.com/videos/play/wwdc2016/231/
    var databaseChangeToken: CKServerChangeToken? {
        get {
            /// For the very first time when launching, the token will be nil and the server will be giving everything on the Cloud to client
            /// In other situation just get the unarchive the data object
            guard let tokenData = UserDefaults.standard.object(forKey: IceCreamKey.sharedDatabaseChangesTokenKey.value) as? Data else { return nil }
            return NSKeyedUnarchiver.unarchiveObject(with: tokenData) as? CKServerChangeToken
        }
        set {
            guard let n = newValue else {
                UserDefaults.standard.removeObject(forKey: IceCreamKey.sharedDatabaseChangesTokenKey.value)
                return
            }
            let data = NSKeyedArchiver.archivedData(withRootObject: n)
            UserDefaults.standard.set(data, forKey: IceCreamKey.sharedDatabaseChangesTokenKey.value)
        }
    }

    var subscriptionIsLocallyCached: Bool {
        get {
            guard let flag = UserDefaults.standard.object(forKey: IceCreamKey.sharedSubscriptionIsLocallyCachedKey.value) as? Bool  else { return false }
            return flag
        }
        set {
            UserDefaults.standard.set(newValue, forKey: IceCreamKey.sharedSubscriptionIsLocallyCachedKey.value)
        }
    }

    private var zoneIds: [CKRecordZone.ID] {
        return syncObjects.map { $0.zoneID }
    }

    private var zoneIdOptions: [CKRecordZone.ID: CKFetchRecordZoneChangesOperation.ZoneOptions] {
        return syncObjects.reduce([CKRecordZone.ID: CKFetchRecordZoneChangesOperation.ZoneOptions]()) { (dict, syncObject) -> [CKRecordZone.ID: CKFetchRecordZoneChangesOperation.ZoneOptions] in
            var dict = dict
            let zoneChangesOptions = CKFetchRecordZoneChangesOperation.ZoneOptions()
            zoneChangesOptions.previousServerChangeToken = syncObject.zoneChangesToken
            dict[syncObject.zoneID] = zoneChangesOptions
            return dict
        }
    }

    @objc func cleanUp() {
        for syncObject in syncObjects {
            syncObject.cleanUp()
        }
    }
}
