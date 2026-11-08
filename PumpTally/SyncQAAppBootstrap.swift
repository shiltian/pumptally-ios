import CloudKit
import Foundation
import SwiftData

/// Only the SyncQA configuration compiles this composition root. The full app
/// uses the native transport with an explicit, isolated Development container.
@MainActor
enum AppBootstrap {
    static func makeEnvironment() throws -> ApplicationEnvironment {
        let schema = Schema(versionedSchema: SchemaV6.self)
        let container = try ModelContainer(
            for: schema,
            migrationPlan: PumpTallyMigrationPlan.self,
            configurations: [ModelConfiguration(schema: schema, cloudKitDatabase: .none)]
        )
        let writer = OwnedModelStore(container: container)
        let native = NativeCloudSyncEnvironment(
            container: CKContainer(identifier: "iCloud.me.tianshilei.fuelio.CloudKitProbe"))
        let syncService = CloudSyncService(writer: writer, environment: native)
        return ApplicationEnvironment(
            writer: writer, cloudSyncService: syncService,
            lifecycle: ApplicationLifecycleCoordinator(writer: writer, syncService: syncService))
    }
}
