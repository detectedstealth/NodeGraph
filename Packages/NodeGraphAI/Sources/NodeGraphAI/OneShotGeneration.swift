#if !os(tvOS) && !os(watchOS)
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

/// A model's answer, as it comes back: new nodes, their settings, links (either end possibly a node
/// already in the graph) and edits of existing nodes.
private struct GraphDraft: Decodable {
    struct Node: Decodable { var alias: Flexible; var type: Flexible }
    struct Setting: Decodable { var node: Flexible; var property: Flexible; var value: Flexible }
    struct Link: Decodable { var from: Flexible; var to: Flexible }
    struct Edit: Decodable {
        var op: Flexible; var node: Flexible?; var property: Flexible?
        var value: Flexible?; var from: Flexible?; var to: Flexible?
    }
    var nodes: [Node]?
    var settings: [Setting]?
    var links: [Link]?
    var edits: [Edit]?
}

/// An answer turned into what the workspace takes.
private struct Change {
    var spec: GraphSpec  // the new nodes, and the links among them
    var connections: [GraphSpec.LinkSpec]  // links with an end on an existing node
    var edits: [EditOperation]
}

/// Why an answer could not be read, in a form to send back to the model.
private struct DraftError: Error { var message: String }

extension GraphGenerator {
    /// Builds the change in one request, for a model with room for the node catalogue and the current
    /// graph (decisions 236 and 237).
    ///
    /// The model sees the task, the graph as it is now with the selection, and the ports and settings
    /// of the node types that fit, and answers with new nodes, settings, links and edits. A link may
    /// join a new node to an existing one (named `n3`, as in the graph text) and an edit may change an
    /// existing node, so "connect a log to the append node" is one proposal. The workspace checks it,
    /// and what it rejects goes back to the model with its own messages, up to ``maxRepairs`` times;
    /// what is still rejected is dropped and listed. Ports of a node taking any number of inputs
    /// (`in_1`, `in_2`, ...) are linked like any other, and the count is worked out from the links.
    func generateInOneShot(_ request: String) async throws -> GenerationOutcome {
        let candidates = workspace.candidateNodeTypes(for: request, limit: 40)
        var ids = candidates.map(\.typeID.rawValue)
        func offer(_ type: String) {
            if !ids.contains(type), workspace.nodes.definition(for: NodeTypeID(type)) != nil { ids.append(type) }
        }
        for example in examples { example.types.forEach(offer) }
        // The model needs the ports of the types already in the graph to link to them.
        Set(workspace.graph.nodes.values.map(\.typeID.rawValue)).sorted().prefix(15).forEach(offer)
        let catalogue = ids.compactMap { workspace.describeNode(type: $0) }.joined(separator: "\n\n")

        let graphText = workspace.currentGraphText(tokenBudget: digestTokenBudget)
        let current = graphText.isEmpty ? "" : """

            The graph now. Its nodes are named n1, n2, ...
            \(graphText)

            Nodes already in the graph can be linked to, and changed only through "edits". Give every new node an alias that does not look like n1, n2, ... If the task says "it", "this" or "the selected node", it means the selected nodes above.

            """
        let base = """
            Make a change to a node graph for this task: \(request)
            \(current)
            Use only these node types. Each lists its ports and settings.

            \(catalogue)

            Rules:
            - Give each new node a short alias you choose, letters and digits only.
            - Each separate value the task mentions needs its own node that makes it, with its value in settings. Two numbers need two number nodes.
            - A link goes from an output to an input, written alias.port. An input takes one link; an output may feed several.
            - To connect a new node to one already in the graph, or two existing nodes to each other, add a link and write the existing node by its name, such as n3.
            - To change an existing node, add an edit: setProperty (node, property, value), setTitle or setMode (node, value), connect or disconnect (from, to), removeNode (node). Leave unused fields empty.
            - Ports named like in_1, in_2, ... belong to a node that takes any number of inputs. Link them in order, starting at in_1.
            - Add only what the task needs. If it needs no new nodes, leave nodes empty.
            """
        let schema = try StageSchemas.graph(types: ids)

        var notes: [String] = []
        var content = try await generator.generate(stage: .draftGraph, prompt: base, schema: schema)
        var change: Change?
        var proposal: PendingChange?
        var readFailure: String?

        func read(_ content: GeneratedContent) {
            notes = []
            do {
                change = try buildChange(from: content, notes: &notes)
                readFailure = nil
            } catch let error as DraftError {
                change = nil
                readFailure = error.message
            } catch {
                change = nil
                readFailure = "\(error.localizedDescription)"
            }
            proposal = change.map {
                workspace.proposeChange(adding: $0.spec, connecting: $0.connections, edits: $0.edits, title: "Generate: " + request)
            }
        }
        read(content)

        var round = 0
        while round < maxRepairs {
            // What is wrong: the answer could not be read at all, or the workspace rejected part of it.
            let problems = readFailure.map { [$0] } ?? proposal?.errors ?? []
            guard !problems.isEmpty else { break }
            round += 1
            let prompt = base + """


                Your last answer:
                \(content.jsonString)

                The checker rejected it:
                \(problems.map { "- " + $0 }.joined(separator: "\n"))
                Answer again with the whole corrected change.
                """
            content = try await generator.generate(stage: .repairGraph(round: round), prompt: prompt, schema: schema)
            read(content)
        }
        guard let change, let proposal else {
            throw ProviderError.badResponse("The answer could not be read: \(readFailure ?? "nothing in it"). The start of the answer was: \(content.jsonString.prefix(200))")
        }
        return GenerationOutcome(spec: change.spec, change: proposal, notes: notes)
    }

    private func buildChange(from content: GeneratedContent, notes: inout [String]) throws -> Change {
        let draft: GraphDraft
        do { draft = try JSONDecoder().decode(GraphDraft.self, from: Data(content.jsonString.utf8)) } catch {
            throw DraftError(message: "It was not an object with a \"nodes\" list of aliases and types, a \"settings\" list, a \"links\" list and an \"edits\" list. \(Self.summary(of: error))")
        }

        // New nodes. An alias that looks like an existing node's name (n3) would be taken for it, so rename it.
        var nodes: [GraphSpec.NodeSpec] = []
        var renamed: [String: String] = [:]
        var seen: Set<String> = []
        for node in (draft.nodes ?? []).prefix(maxNodes * 3) {
            var alias = node.alias.text.filter { $0.isLetter || $0.isNumber }
            guard !alias.isEmpty, seen.insert(alias).inserted else {
                notes.append("Ignored a node with a missing or repeated name \"\(node.alias.text)\".")
                continue
            }
            if alias.first == "n", alias.dropFirst().allSatisfy(\.isNumber), alias.count > 1 {
                let fresh = "new" + alias
                notes.append("Called the new node \(alias) \(fresh), so it is not mistaken for the node already named \(alias).")
                renamed[alias] = fresh
                alias = fresh
            }
            nodes.append(.init(alias: alias, type: node.type.text))
        }
        for setting in draft.settings ?? [] {
            let target = renamed[setting.node.text] ?? setting.node.text
            guard let index = nodes.firstIndex(where: { $0.alias == target }) else {
                notes.append("Ignored a setting for \"\(setting.node.text)\": there is no such new node.")
                continue
            }
            nodes[index].properties[setting.property.text] = ProposeEditTool.Operation.json(from: setting.value.text)
        }

        // Links: among the new nodes, or with an end on an existing node.
        let newAliases = Set(nodes.map(\.alias))
        func isNew(_ end: String) -> Bool { end.split(separator: ".").first.map { newAliases.contains(String($0)) } ?? false }
        let links = (draft.links ?? []).map { GraphSpec.LinkSpec(from: $0.from.text, to: $0.to.text) }
        let inside = links.filter { isNew($0.from) && isNew($0.to) }
        let connections = links.filter { !(isNew($0.from) && isNew($0.to)) }
        for index in nodes.indices { nodes[index].portCounts = dynamicPortCounts(of: nodes[index], links: links) }

        var edits: [EditOperation] = []
        for edit in draft.edits ?? [] {
            guard let kind = EditOperation.Kind(rawValue: edit.op.text) else {
                notes.append("Ignored an edit of kind \"\(edit.op.text)\".")
                continue
            }
            func field(_ value: Flexible?) -> String? { value.map(\.text).flatMap { $0.isEmpty ? nil : $0 } }
            edits.append(EditOperation(
                kind, node: field(edit.node), property: field(edit.property),
                value: field(edit.value).map(ProposeEditTool.Operation.json(from:)), from: field(edit.from), to: field(edit.to)))
        }

        if nodes.isEmpty && connections.isEmpty && edits.isEmpty { throw DraftError(message: "It had no nodes, links or edits.") }
        return Change(spec: GraphSpec(nodes: nodes, links: inside), connections: connections, edits: edits)
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
#endif
