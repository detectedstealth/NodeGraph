import Foundation
import NodeGraphCore
import NodeGraphNodes
import NodeGraphRobotics
import NodeGraphVideo

/// Why a run could not start.
public enum GraphRunError: Error, Hashable, Sendable, CustomStringConvertible {
    /// A `--var` argument is not `name=json`.
    case malformedVariable(String)
    case invalidVariableValue(name: String, reason: String)

    public var description: String {
        switch self {
        case .malformedVariable(let text): "Variable '\(text)' is not in the form name=value"
        case .invalidVariableValue(let name, let reason): "Variable '\(name)': \(reason)"
        }
    }
}

/// What the headless runner did, in a form that prints as JSON.
public struct RunReport: Codable, Hashable, Sendable {
    public struct NodeReport: Codable, Hashable, Sendable {
        public var id: String
        public var type: String
        public var title: String?
        /// `success`, `cached`, `bypassed`, `failure`, `cancelled` or `skipped`.
        public var status: String
        /// Data outputs by port name. Empty unless the node ran.
        public var outputs: [String: GraphValue]
        /// Trigger outputs that fired.
        public var triggers: [String]
        public var error: String?
    }

    public struct TickReport: Codable, Hashable, Sendable {
        public var tick: Int
        public var succeeded: Bool
        public var nodes: [NodeReport]
    }

    public var ticks: [TickReport]

    /// Whether every node of every tick ran (or was served from the cache).
    public var succeeded: Bool { ticks.allSatisfy(\.succeeded) }

    /// JSON with sorted keys, so equal runs give equal bytes.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

/// Runs a document headless with the built-in node packs and the robotics and video packs.
public enum GraphRun {
    /// The registries the tools use: every node in ``StandardPack``, ``RoboticsPack`` and ``VideoPack``,
    /// with their port types.
    public static func standardRegistries() -> (nodes: NodeRegistry, types: TypeRegistry) {
        var nodes = NodeRegistry()
        var types = TypeRegistry()
        StandardTypes.register(in: &types)
        StandardPack.register(nodes: &nodes, types: &types)
        RoboticsPack.register(nodes: &nodes, types: &types)
        VideoPack.register(nodes: &nodes, types: &types)
        return (nodes, types)
    }

    /// The node registry the runner uses. See ``standardRegistries()``.
    public static func standardRegistry() -> NodeRegistry {
        standardRegistries().nodes
    }

    /// Parses `name=value` arguments, where a value is plain JSON (not the tagged form documents use). A value that is not valid JSON is taken as a string, so
    /// `speed=3`, `flag=true` and `label=hello` all work.
    public static func parseVariables(_ arguments: [String]) throws -> [String: GraphValue] {
        var values: [String: GraphValue] = [:]
        for argument in arguments {
            guard let split = argument.firstIndex(of: "="), split != argument.startIndex else {
                throw GraphRunError.malformedVariable(argument)
            }
            let name = String(argument[..<split]), text = String(argument[argument.index(after: split)...])
            if let json = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) {
                values[name] = graphValue(json)
            } else {
                values[name] = .string(text)
            }
        }
        return values
    }

    private static func graphValue(_ json: JSONValue) -> GraphValue {
        switch json {
        case .null: .null
        case .bool(let v): .bool(v)
        case .int(let v): .int(v)
        case .double(let v): .double(v)
        case .string(let v): .string(v)
        case .array(let v): .array(v.map(graphValue))
        case .object(let v): .object(v.mapValues(graphValue))
        }
    }

    /// Runs `document` for `ticks` passes (at least one) with simulated time advancing by
    /// `delta` per pass, so the same inputs give the same report.
    /// - Throws: ``ExecutionPlanError`` for an unbreakable cycle, ``VariableOverrideError`` for a
    ///   refused variable.
    public static func run(
        _ document: GraphDocument,
        ticks: Int = 1,
        delta: Duration = .milliseconds(16),
        variables: [String: GraphValue] = [:],
        registry: NodeRegistry = standardRegistry()
    ) async throws -> RunReport {
        let runner = try GraphRunner(
            document: document, registry: registry, variables: widened(variables, toMatch: document.graph))
        var reports: [RunReport.TickReport] = []
        for await tick in runner.run(.deterministic(fixedDelta: delta, ticks: max(1, ticks))) {
            reports.append(report(of: tick, in: document.graph))
        }
        return RunReport(ticks: reports)
    }

    /// `--var margin=2` reads as an integer, but a variable declared as a decimal number only takes
    /// decimals. A whole number given for one is widened to match, which loses nothing.
    static func widened(_ overrides: [String: GraphValue], toMatch graph: Graph) -> [String: GraphValue] {
        var result = overrides
        for (name, value) in overrides {
            if case .int(let whole) = value, case .double? = graph.variables[name]?.value {
                result[name] = .double(Double(whole))
            }
        }
        return result
    }

    private static func report(of tick: TickResult, in graph: Graph) -> RunReport.TickReport {
        let nodes = tick.results.values.map { result -> RunReport.NodeReport in
            let node = graph.nodes[result.node]
            var outputs: NodeOutputs?
            var status: String
            var error: String?
            switch result.outcome {
            case .success(let o): (status, outputs) = ("success", o)
            case .cached(let o): (status, outputs) = ("cached", o)
            case .bypassed(let o): (status, outputs) = ("bypassed", o)
            case .failure(let failure): (status, error) = ("failure", failure.message)
            case .cancelled: status = "cancelled"
            case .skipped(let reason): (status, error) = ("skipped", reason.rawValue)
            }
            return RunReport.NodeReport(
                id: result.node.description, type: node?.typeID.description ?? "",
                title: node?.title, status: status,
                outputs: Dictionary(uniqueKeysWithValues: (outputs?.values ?? [:]).map { ($0.key.description, $0.value) }),
                triggers: (outputs?.triggers ?? []).map(\.description).sorted(), error: error)
        }
        return RunReport.TickReport(tick: tick.tick, succeeded: tick.succeeded, nodes: nodes)
    }
}
