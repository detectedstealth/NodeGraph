/// One step that upgrades a document's JSON from version `from` to `from + 1`.
///
/// The transform edits the JSON tree in place. It does not set `schemaVersion`; the chain does.
public struct DocumentMigration: Sendable {
    public let from: Int
    public let transform: @Sendable (inout JSONValue) throws -> Void

    public init(from: Int, transform: @escaping @Sendable (inout JSONValue) throws -> Void) {
        self.from = from
        self.transform = transform
    }
}

/// An ordered set of migrations that brings old documents up to `targetVersion`.
///
/// Migrations run on the JSON tree, before decoding, so the typed models only ever need to
/// understand the newest format. Add a migration here whenever the format changes.
public struct MigrationChain: Sendable {
    /// The version the typed models decode. Documents are migrated to exactly this.
    public let targetVersion: Int
    private let migrations: [Int: DocumentMigration]

    public init(targetVersion: Int, migrations: [DocumentMigration] = []) {
        self.targetVersion = targetVersion
        self.migrations = Dictionary(migrations.map { ($0.from, $0) }, uniquingKeysWith: { _, last in last })
    }

    /// The chain for the current format. Empty while the format is still version 1.
    public static let standard = MigrationChain(targetVersion: NodeGraphCore.documentSchemaVersion)

    /// Upgrades `tree` from `version` to ``targetVersion``, updating its `schemaVersion`.
    func migrate(_ tree: inout JSONValue, from version: Int) throws {
        var current = version
        while current < targetVersion {
            guard let migration = migrations[current] else {
                throw GraphDocumentError.noMigrationPath(from: current)
            }
            do {
                try migration.transform(&tree)
            } catch {
                throw GraphDocumentError.migrationFailed(from: current, reason: "\(error)")
            }
            current += 1
            tree["schemaVersion"] = .int(Int64(current))
        }
    }
}
