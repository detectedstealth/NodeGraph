import Foundation
import FoundationModels
import NodeGraphAssistant
import NodeGraphCore

/// Text read leniently. A hosted model is asked for strings but is not always held to it: a setting's
/// value may arrive as the number 2, or an alias as 1, and that is still an answer.
private struct Flexible: Decodable {
    var text: String

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            text = string
        } else if let value = try? container.decode(JSONValue.self) {
            if case .null = value { text = "" } else {
                text = (try? JSONEncoder().encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? ""
            }
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected text.")
        }
    }
}

/// A model's answer for the whole graph, as it comes back.
private struct GraphDraft: Decodable {
    struct Node: Decodable { var alias: Flexible; var type: Flexible }
    struct Setting: Decodable { var node: Flexible; var property: Flexible; var value: Flexible }
    struct Link: Decodable { var from: Flexible; var to: Flexible }
    var nodes: [Node]
    var settings: [Setting]?
    var links: [Link]?
}

/// Why an answer could not be read, in a form to send back to the model.
private struct DraftError: Error { var message: String }

extension GraphGenerator {
    /// Builds the whole graph in one request, for a model with room for the node catalogue (decision 236).
    ///
    /// The model sees the task and the ports and settings of the node types that fit it, and answers
    /// with nodes, settings and links. The real compiler then checks the answer, and what it rejects
    /// goes back to the model with the compiler's own messages, up to ``maxRepairs`` times; what is
    /// still rejected is dropped and listed. Ports that belong to a node taking any number of inputs
    /// (`in_1`, `in_2`, ...) are linked like any other, and the count is worked out from the links.
    func generateInOneShot(_ request: String) async throws -> GenerationOutcome {
        let candidates = workspace.candidateNodeTypes(for: request, limit: 40)
        var ids = candidates.map(\.typeID.rawValue)
        for example in examples { for type in example.types where !ids.contains(type) && workspace.nodes.definition(for: NodeTypeID(type)) != nil { ids.append(type) } }
        let catalogue = ids.compactMap { workspace.describeNode(type: $0) }.joined(separator: "\n\n")
        let base = """
            Build a node graph for this task: \(request)

            Use only these node types. Each lists its ports and settings.

            \(catalogue)

            Rules:
            - Give each node a short alias you choose, letters and digits only.
            - Each separate value the task mentions needs its own node that makes it, with its value in settings. Two numbers need two number nodes.
            - A link goes from an output to an input, written alias.port. An input takes one link; an output may feed several.
            - Ports named like in_1, in_2, ... belong to a node that takes any number of inputs. Link them in order, starting at in_1.
            - Add only the nodes the task needs.
            """
        let schema = try StageSchemas.graph(types: ids)
        let compiler = GraphSpecCompiler(nodes: workspace.nodes, types: workspace.types, connectionValidator: workspace.connectionValidator)

        var notes: [String] = []
        var content = try await generator.generate(stage: .draftGraph, prompt: base, schema: schema)
        var spec: GraphSpec?
        var readFailure: String?
        func read(_ content: GeneratedContent) throws {
            notes = []
            do {
                spec = try buildSpec(from: content, notes: &notes)
                readFailure = nil
            } catch let error as DraftError {
                spec = nil
                readFailure = error.message
            }
        }
        try read(content)

        var round = 0
        while round < maxRepairs {
            // What is wrong: the answer could not be read at all, or the compiler rejected part of it.
            let problems = readFailure.map { [$0] } ?? (spec.map { compiler.compile($0).errors.map(\.message) } ?? [])
            guard !problems.isEmpty else { break }
            round += 1
            let prompt = base + """


                Your last answer:
                \(content.jsonString)

                The checker rejected it:
                \(problems.map { "- " + $0 }.joined(separator: "\n"))
                Answer again with the whole corrected graph.
                """
            content = try await generator.generate(stage: .repairGraph(round: round), prompt: prompt, schema: schema)
            try read(content)
        }
        guard let spec else {
            throw ProviderError.badResponse("The graph could not be read: \(readFailure ?? "no nodes"). The start of the answer was: \(content.jsonString.prefix(200))")
        }
        let change = workspace.proposeGeneration(spec, title: "Generate: " + request)
        return GenerationOutcome(spec: spec, change: change, notes: notes)
    }

    private func buildSpec(from content: GeneratedContent, notes: inout [String]) throws -> GraphSpec {
        let draft: GraphDraft
        do { draft = try JSONDecoder().decode(GraphDraft.self, from: Data(content.jsonString.utf8)) } catch {
            throw DraftError(message: "It was not an object with a \"nodes\" list of aliases and types, an optional \"settings\" list and an optional \"links\" list. \(Self.summary(of: error))")
        }
        var nodes: [GraphSpec.NodeSpec] = []
        var seen: Set<String> = []
        for node in draft.nodes.prefix(maxNodes * 3) {
            let alias = node.alias.text.filter { $0.isLetter || $0.isNumber }
            guard !alias.isEmpty, seen.insert(alias).inserted else {
                notes.append("Ignored a node with a missing or repeated name \"\(node.alias.text)\".")
                continue
            }
            nodes.append(.init(alias: alias, type: node.type.text))
        }
        if nodes.isEmpty { throw DraftError(message: "It had no nodes.") }
        for setting in draft.settings ?? [] {
            guard let index = nodes.firstIndex(where: { $0.alias == setting.node.text }) else {
                notes.append("Ignored a setting for \"\(setting.node.text)\": there is no such node.")
                continue
            }
            nodes[index].properties[setting.property.text] = ProposeEditTool.Operation.json(from: setting.value.text)
        }
        let links = (draft.links ?? []).map { GraphSpec.LinkSpec(from: $0.from.text, to: $0.to.text) }
        for index in nodes.indices { nodes[index].portCounts = dynamicPortCounts(of: nodes[index], links: links) }
        return GraphSpec(nodes: nodes, links: links)
    }

    /// The part of a decoding error that says where and why, kept short.
    private static func summary(of error: any Error) -> String {
        guard let decoding = error as? DecodingError else { return "\(error.localizedDescription)" }
        switch decoding {
        case .keyNotFound(let key, _): return "The field \"\(key.stringValue)\" is missing."
        case .typeMismatch(_, let context), .valueNotFound(_, let context), .dataCorrupted(let context):
            let path = context.codingPath.map(\.stringValue).joined(separator: ".")
            return "At \(path.isEmpty ? "the top" : path): \(context.debugDescription)"
        @unknown default: return "\(decoding)"
        }
    }

    /// How many ports each of the node's dynamic groups needs for the links that name them (`in_4`
    /// needs four), never fewer than the group starts with and never more than it allows.
    private func dynamicPortCounts(of node: GraphSpec.NodeSpec, links: [GraphSpec.LinkSpec]) -> [String: Int] {
        guard let definition = workspace.nodes.definition(for: NodeTypeID(node.type)) else { return [:] }
        var counts: [String: Int] = [:]
        for group in definition.dynamicPorts {
            var highest = 0
            for reference in links.map(\.from) + links.map(\.to) {
                let parts = reference.split(separator: ".", maxSplits: 1).map(String.init)
                guard parts.count == 2, parts[0] == node.alias, parts[1].hasPrefix(group.id + "_"),
                      let number = Int(parts[1].dropFirst(group.id.count + 1)) else { continue }
                highest = max(highest, number)
            }
            guard highest > 0 else { continue }
            let wanted = max(group.initialCount, highest)
            counts[group.id] = group.maximum.map { min(wanted, $0) } ?? wanted
        }
        return counts
    }
}
