import Foundation
import SwiftData

/// Included in ordinary Debug and Release builds. Xcode's Testing configuration
/// substitutes the bootstrap in PumpTallyTests/Support at compile time.
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
        let syncService = CloudSyncService(writer: writer)
        return ApplicationEnvironment(
            writer: writer, cloudSyncService: syncService,
            lifecycle: ApplicationLifecycleCoordinator(writer: writer, syncService: syncService))
    }
}
