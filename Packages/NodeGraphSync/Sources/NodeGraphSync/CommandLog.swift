import Foundation
import NodeGraphCore

/// Why a ``CommandLog`` could not be replayed.
public enum CommandLogError: Error, Hashable, Sendable {
    /// The editor is not at the revision the log starts from.
    case baseMismatch(expected: Int, actual: Int)
}

/// The changes applied to a graph after some revision, in order. The change log a server keeps and
/// a client sends: replaying it on an editor at ``baseRevision`` reproduces the edits.
///
/// Collect changes from ``GraphEditor/changes()`` and append them. The log keeps each change's
/// inverse as well, so a log can also be walked backwards.
public struct CommandLog: Hashable, Sendable, Codable {
    /// The editor revision the first change applies to.
    public var baseRevision: Int
    public private(set) var changes: [GraphChange]

    public init(baseRevision: Int = 0, changes: [GraphChange] = []) {
        self.baseRevision = baseRevision
        self.changes = changes
    }

    /// The editor revision after the last change.
    public var revision: Int { changes.last?.revision ?? baseRevision }

    /// Adds a change, which must be the next one: its revision is one past the log's.
    /// - Returns: False, leaving the log as it was, if a change was missed or repeated.
    @discardableResult
    public mutating func append(_ change: GraphChange) -> Bool {
        guard change.revision == revision + 1 else { return false }
        changes.append(change)
        return true
    }

    /// The changes after `revision`, for a client that has everything up to it.
    public func changes(since revision: Int) -> ArraySlice<GraphChange> {
        changes.drop { $0.revision <= revision }
    }

    /// Applies every command to `editor` in order, which must be at ``baseRevision``.
    /// - Throws: ``CommandLogError/baseMismatch(expected:actual:)``, or the edit error of the first
    ///   command that fails (earlier commands stay applied).
    public func replay(on editor: GraphEditor) throws {
        guard editor.revision == baseRevision else {
            throw CommandLogError.baseMismatch(expected: baseRevision, actual: editor.revision)
        }
        for change in changes { try editor.apply(change.command) }
    }

    /// JSON with sorted keys, so equal logs give equal bytes.
    public func encoded(prettyPrinted: Bool = true) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = prettyPrinted
            ? [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes] : [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    public static func decode(from data: Data) throws -> CommandLog {
        try JSONDecoder().decode(CommandLog.self, from: data)
    }
}
