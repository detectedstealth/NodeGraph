import Foundation
import FoundationModels
import NodeGraphAssistant
import NodeGraphCore

/// What staged generation produced.
public struct GenerationOutcome: Sendable {
    /// The graph as the model chose it, after links the editor would not accept were dropped.
    public var spec: GraphSpec
    /// The proposal to preview. Nothing has been applied (decision 211).
    public var change: PendingChange
    /// How many repair rounds were used.
    public var repairs: Int
    /// What was left out and why, in words for the person.
    public var notes: [String]
}

public enum GenerationError: Error, Hashable, Sendable, CustomStringConvertible {
    case noNodes

    public var description: String {
        switch self {
        case .noNodes: "The model did not choose any node type that exists."
        }
    }
}

/// Builds a graph in small, constrained steps so a model with a 4K context can do it (decision 228).
///
/// 1. Pick node types, from the best matches for the request.
/// 2. Set each node's properties, one small request per node.
/// 3. Choose links, from the ones the editor would accept between the chosen nodes.
///
/// Links that do not fit together (two into one input, a cycle) are found by the real compiler and
/// the model is asked again, up to ``maxRepairs`` rounds; what is still wrong is dropped and
/// reported, never applied. Aliases are assigned here (`number1`, `add1`), so the model cannot
/// write an invalid one. Every request carries its own context, so the generator needs no memory.
public struct GraphGenerator: Sendable {
    public var workspace: AssistantWorkspace
    public var generator: any StructuredGenerator
    public var maxNodes: Int
    public var maxRepairs: Int

    public init(
        workspace: AssistantWorkspace, generator: any StructuredGenerator, maxNodes: Int = 10, maxRepairs: Int = 2
    ) {
        self.workspace = workspace
        self.generator = generator
        self.maxNodes = maxNodes
        self.maxRepairs = maxRepairs
    }

    public func generate(_ request: String) async throws -> GenerationOutcome {
        var notes: [String] = []
        var specs = try await pickNodes(request, notes: &notes)
        for index in specs.indices {
            specs[index].properties = try await properties(of: specs[index], request: request, notes: &notes)
        }
        let chosen = try await chooseLinks(request, nodes: specs)
        // Drop what the compiler still rejects, so the proposal holds only links that fit.
        let final = partition(chosen.links, nodes: specs)
        var rejections = chosen.rejected
        for (link, message) in final.rejected { rejections[link] = message }
        for (link, message) in rejections.sorted(by: { Self.text(of: $0.key) < Self.text(of: $1.key) }) where !final.kept.contains(link) {
            notes.append("Left out \(Self.text(of: link)): \(message)")
        }
        let links = final.kept
        let repairs = chosen.repairs

        let spec = GraphSpec(nodes: specs, links: links)
        let change = workspace.proposeGeneration(spec, title: "Generate: " + request)
        return GenerationOutcome(spec: spec, change: change, repairs: repairs, notes: notes)
    }

    // MARK: Stage 1

    private func pickNodes(_ request: String, notes: inout [String]) async throws -> [GraphSpec.NodeSpec] {
        let candidates = workspace.candidateNodeTypes(for: request)
        let ids = candidates.map(\.typeID.rawValue)
        let prompt = """
            Task: \(request)
            Choose the node types needed, in the order they are used. A type can be chosen more than once.
            Node types:
            \(candidates.map(\.rendered).joined(separator: "\n"))
            """
        let content = try await generator.generate(
            stage: .pickNodes, prompt: prompt, schema: try StageSchemas.nodePick(types: ids, maxNodes: maxNodes))
        let chosen = try content.value([String].self)
        var counts: [String: Int] = [:]
        var specs: [GraphSpec.NodeSpec] = []
        for type in chosen.prefix(maxNodes) {
            guard ids.contains(type) else {
                notes.append("Ignored \"\(type)\": not one of the offered node types.")
                continue
            }
            let base = Self.baseAlias(of: type)
            counts[base, default: 0] += 1
            specs.append(.init(alias: "\(base)\(counts[base]!)", type: type))
        }
        if specs.isEmpty { throw GenerationError.noNodes }
        return specs
    }

    // MARK: Stage 2

    private func properties(
        of node: GraphSpec.NodeSpec, request: String, notes: inout [String]
    ) async throws -> [String: JSONValue] {
        let slots = workspace.propertySlots(type: node.type)
        guard !slots.isEmpty else { return [:] }
        let prompt = """
            Task: \(request)
            Set the properties of \(node.alias) (\(node.type)). Leave out any that should stay at their default.
            \(slots.map { "- \($0.id): \($0.title), default \($0.defaultText)" }.joined(separator: "\n"))
            """
        let content = try await generator.generate(
            stage: .setProperties(alias: node.alias), prompt: prompt, schema: try StageSchemas.properties(for: slots))
        do {
            let decoded = try JSONDecoder().decode([String: JSONValue].self, from: Data(content.jsonString.utf8))
            let known = Set(slots.map(\.id))
            return decoded.filter { known.contains($0.key) && $0.value != .null }
        } catch {
            notes.append("Left \(node.alias) at its defaults: its properties could not be read.")
            return [:]
        }
    }

    // MARK: Stage 3 and repair

    private func chooseLinks(
        _ request: String, nodes: [GraphSpec.NodeSpec]
    ) async throws -> (links: [GraphSpec.LinkSpec], repairs: Int, rejected: [GraphSpec.LinkSpec: String]) {
        let candidates = workspace.linkCandidates(among: nodes)
        guard !candidates.isEmpty else { return ([], 0, [:]) }
        let listing = nodes.map { node in
            let settings = node.properties.sorted { $0.key < $1.key }.map { "\($0.key)=\(Self.text(of: $0.value))" }
            return "- \(node.alias) (\(node.type))" + (settings.isEmpty ? "" : " " + settings.joined(separator: ", "))
        }.joined(separator: "\n")
        let base = """
            Task: \(request)
            Nodes:
            \(listing)
            Each input takes at most one link. Link an output to an input with "from -> to".
            """

        var chosen = try await askLinks(
            stage: .wireLinks, prompt: base + "\nAvailable links:\n" + candidates.map(Self.text(of:)).joined(separator: "\n"),
            from: candidates, nodes: nodes)

        var repairs = 0
        var rejected: [GraphSpec.LinkSpec: String] = [:]
        while repairs < maxRepairs {
            let state = partition(chosen, nodes: nodes)
            guard !state.rejected.isEmpty else { break }
            repairs += 1
            for (link, message) in state.rejected { rejected[link] = message }
            let options = candidates.filter { rejected[$0] == nil && !state.kept.contains($0) }
            guard !options.isEmpty else { chosen = state.kept; break }
            let prompt = base + """

                Already chosen and accepted:
                \(state.kept.map(Self.text(of:)).joined(separator: "\n"))
                These were rejected:
                \(state.rejected.map { "\(Self.text(of: $0.link)): \($0.message)" }.joined(separator: "\n"))
                Choose replacements only from:
                \(options.map(Self.text(of:)).joined(separator: "\n"))
                """
            let more = try await askLinks(stage: .repairLinks(round: repairs), prompt: prompt, from: options, nodes: nodes)
            chosen = state.kept + more
        }
        return (chosen, repairs, rejected)
    }

    private func askLinks(
        stage: GenerationStage, prompt: String, from options: [GraphSpec.LinkSpec], nodes: [GraphSpec.NodeSpec]
    ) async throws -> [GraphSpec.LinkSpec] {
        let schema = try StageSchemas.links(from: options.map(Self.text(of:)), maxLinks: max(nodes.count * 2, 2))
        let content = try await generator.generate(stage: stage, prompt: prompt, schema: schema)
        let allowed = Set(options)
        var seen: Set<GraphSpec.LinkSpec> = []
        return try content.value([String].self).compactMap(Self.link(from:)).filter { allowed.contains($0) && seen.insert($0).inserted }
    }

    /// Adds links one at a time and keeps those that compile cleanly with the ones before them,
    /// so the message for a rejected link is about that link.
    private func partition(
        _ links: [GraphSpec.LinkSpec], nodes: [GraphSpec.NodeSpec]
    ) -> (kept: [GraphSpec.LinkSpec], rejected: [(link: GraphSpec.LinkSpec, message: String)]) {
        let compiler = GraphSpecCompiler(
            nodes: workspace.nodes, types: workspace.types, connectionValidator: workspace.connectionValidator)
        // Properties are left out: their problems are not link problems.
        let bare = nodes.map { GraphSpec.NodeSpec(alias: $0.alias, type: $0.type) }
        var kept: [GraphSpec.LinkSpec] = []
        var rejected: [(GraphSpec.LinkSpec, String)] = []
        for link in links {
            let result = compiler.compile(GraphSpec(nodes: bare, links: kept + [link]))
            if let error = result.errors.first {
                rejected.append((link, error.message))
            } else {
                kept.append(link)
            }
        }
        return (kept, rejected)
    }

    // MARK: Text

    static func text(of link: GraphSpec.LinkSpec) -> String { "\(link.from) -> \(link.to)" }

    /// A property value as the JSON a model would write it.
    static func text(of value: JSONValue) -> String {
        (try? JSONEncoder().encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? "?"
    }

    static func link(from text: String) -> GraphSpec.LinkSpec? {
        let parts = text.components(separatedBy: "->").map { $0.trimmingCharacters(in: .whitespaces) }
        return parts.count == 2 ? GraphSpec.LinkSpec(from: parts[0], to: parts[1]) : nil
    }

    /// `math.add` becomes `add`, `util.number` becomes `number`; letters and digits only.
    static func baseAlias(of type: String) -> String {
        let last = type.split(separator: ".").last.map(String.init) ?? type
        let cleaned = last.filter { $0.isLetter || $0.isNumber }
        return cleaned.isEmpty ? "node" : cleaned
    }
}
