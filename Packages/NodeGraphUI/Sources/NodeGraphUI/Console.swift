#if !os(tvOS) && !os(watchOS)
import Foundation
import Logging
import NodeGraphCore
import Observation

/// How serious a console line is.
public enum ConsoleLevel: Int, Hashable, Sendable, Comparable, CaseIterable {
    case debug, info, warning, error

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    public var title: String {
        switch self {
        case .debug: "Debug"
        case .info: "Info"
        case .warning: "Warning"
        case .error: "Error"
        }
    }

    init(_ level: Logger.Level) {
        switch level {
        case .trace, .debug: self = .debug
        case .info, .notice: self = .info
        case .warning: self = .warning
        case .error, .critical: self = .error
        }
    }
}

/// Where a console line came from.
public enum ConsoleSource: String, Hashable, Sendable, CaseIterable {
    /// A node's logger, such as the Log node.
    case node
    /// The run itself: a node that failed, a pass that finished.
    case run
    /// Core's validator.
    case validation
    /// The app or a tool, such as the assistant.
    case app
}

/// One line of the console.
public struct ConsoleEntry: Identifiable, Hashable, Sendable {
    public var id: Int
    public var date: Date
    public var level: ConsoleLevel
    public var source: ConsoleSource
    public var text: String
    /// The node the line is about, so the console can select it.
    public var node: NodeID?
}

/// A swift-log handler that turns each log call into a ``ConsoleEntry``. Hand its logger to
/// ``GraphRunner`` and everything the nodes log, the Log node included, appears in the console.
/// The runner tags every node's logger with `node` and `type` metadata; the node becomes the
/// entry's ``ConsoleEntry/node``.
struct ConsoleLogHandler: LogHandler {
    var metadata: Logger.Metadata = [:]
    var logLevel: Logger.Level = .debug
    let emit: @Sendable (_ level: ConsoleLevel, _ text: String, _ node: NodeID?) -> Void

    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    func log(event: LogEvent) {
        var merged = metadata
        if let extra = event.metadata { merged.merge(extra) { _, new in new } }
        let node = merged["node"].flatMap { UUID(uuidString: "\($0)") }.map(NodeID.init(uuid:))
        emit(ConsoleLevel(event.level), "\(event.message)", node)
    }
}

/// What the console shows: lines from nodes, runs and checks, newest last.
///
/// Feed it a run with ``logger`` (give that to `GraphRunner(logger:)`) and ``record(_:name:)``
/// (each pass's `TickResult`). The app adds its own lines with ``append(_:_:node:source:)``.
/// Lines arrive from any thread through a stream and are added on the main actor.
@MainActor
@Observable
public final class ConsoleModel {
    public private(set) var entries: [ConsoleEntry] = []
    /// The levels ``visibleEntries`` shows. Hidden lines are kept, not discarded. Each level is
    /// its own switch, so showing warnings does not also show errors.
    public var visibleLevels: Set<ConsoleLevel> = [.info, .warning, .error]
    /// The oldest lines are dropped beyond this many.
    public var capacity: Int

    /// A logger whose output goes to this console.
    @ObservationIgnored public let logger: Logger
    @ObservationIgnored private let continuation: AsyncStream<(ConsoleLevel, String, NodeID?)>.Continuation
    @ObservationIgnored private var pump: Task<Void, Never>?
    @ObservationIgnored private var nextID = 0
    /// The last failure line per node, so a run that repeats (continuous) says each failure once.
    @ObservationIgnored private var lastFailures: [NodeID: String] = [:]

    public init(capacity: Int = 2000) {
        self.capacity = capacity
        let (stream, continuation) = AsyncStream.makeStream(of: (ConsoleLevel, String, NodeID?).self)
        self.continuation = continuation
        logger = Logger(label: "NodeGraph.console") { _ in
            ConsoleLogHandler { level, text, node in continuation.yield((level, text, node)) }
        }
        pump = Task { [weak self] in
            for await (level, text, node) in stream {
                guard let self else { return }
                self.append(level, text, node: node, source: .node)
            }
        }
    }

    isolated deinit {
        pump?.cancel()
        continuation.finish()
    }

    public var visibleEntries: [ConsoleEntry] { entries.filter { visibleLevels.contains($0.level) } }

    /// How many lines of each level there are, for the counts beside the filter.
    public func count(of level: ConsoleLevel) -> Int { entries.reduce(0) { $0 + ($1.level == level ? 1 : 0) } }

    public func append(_ level: ConsoleLevel, _ text: String, node: NodeID? = nil, source: ConsoleSource = .app) {
        entries.append(ConsoleEntry(id: nextID, date: Date(), level: level, source: source, text: text, node: node))
        nextID += 1
        if entries.count > capacity { entries.removeFirst(entries.count - capacity) }
    }

    public func clear() { entries.removeAll() }

    /// Starts a run's lines: forgets which failures were already shown, so they show again.
    public func beginRun(_ title: String) {
        lastFailures = [:]
        append(.info, title, source: .run)
    }

    /// Adds a line for each node that failed in `result`, and one for the pass unless `summarize`
    /// is false. `name` gives a node's name for the text. A node that fails with the same message
    /// as in the last recorded pass is not repeated. Nodes skipped because another failed are debug lines.
    public func record(_ result: TickResult, summarize: Bool = true, name: (NodeID) -> String) {
        var failed = 0
        for node in result.results.values {
            switch node.outcome {
            case .failure(let failure):
                failed += 1
                guard lastFailures[node.node] != failure.message else { continue }
                lastFailures[node.node] = failure.message
                append(.error, "\(name(node.node)) failed: \(failure.message)", node: node.node, source: .run)
            case .skipped(let reason) where reason == .upstreamFailed:
                guard lastFailures[node.node] != "skipped" else { continue }
                lastFailures[node.node] = "skipped"
                append(.debug, "\(name(node.node)) skipped: a node feeding it failed", node: node.node, source: .run)
            case .cancelled:
                append(.warning, "\(name(node.node)) was cancelled", node: node.node, source: .run)
            default:
                lastFailures[node.node] = nil
            }
        }
        guard summarize else { return }
        let milliseconds = Double(result.duration.components.attoseconds) / 1e15
            + Double(result.duration.components.seconds) * 1000
        let summary = "Pass \(result.tick): \(result.results.count) nodes, \(failed) failed, "
            + String(format: "%.1f ms", milliseconds)
        append(failed > 0 ? .warning : .info, summary + (result.wasCancelled ? " (cancelled)" : ""), source: .run)
    }

    /// Adds a line for each problem the validator found.
    public func record(_ diagnostics: [GraphDiagnostic], name: (NodeID) -> String) {
        for diagnostic in diagnostics {
            append(
                diagnostic.severity == .error ? .error : .warning,
                (diagnostic.node.map { name($0) + ": " } ?? "") + diagnostic.message,
                node: diagnostic.node, source: .validation)
        }
    }
}

extension GraphEditorModel {
    /// What to call a node in the console: its title, or its type's name.
    public func consoleName(of node: NodeID) -> String {
        guard let found = graph.nodes[node] else { return "A removed node" }
        return found.title ?? definition(of: found)?.displayName ?? found.typeID.rawValue
    }

    /// Selects the node a console line is about and scrolls the view to it.
    public func reveal(node: NodeID) {
        guard graph.nodes[node] != nil else { return }
        select(node: node)
        let frame = editor.nodes.frame(of: graph.nodes[node]!)
        camera.center(on: GraphPoint(x: (frame.minX + frame.maxX) / 2, y: (frame.minY + frame.maxY) / 2), in: viewSize)
    }
}
#endif
