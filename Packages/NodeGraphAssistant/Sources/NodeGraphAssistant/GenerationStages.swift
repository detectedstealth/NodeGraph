import NodeGraphCore

/// One setting of a node type that a model may fill in, described without any model framework.
///
/// A model layer turns these into constrained output schemas. Kinds a model cannot sensibly write
/// as plain JSON (colors, vectors, variable names, pack-defined kinds) have no slot and keep their
/// defaults.
public struct PropertySlot: Hashable, Sendable {
    public enum Shape: Hashable, Sendable {
        case bool
        case int(min: Int?, max: Int?)
        case double(min: Double?, max: Double?)
        case text
        case choice([String])
    }

    public var id: String
    /// What the person sees as the property's name.
    public var title: String
    public var shape: Shape
    /// The default, as text, for the prompt.
    public var defaultText: String
}

/// The pieces of staged generation that need no model (docs/ASSISTANT.md, "Generation strategy
/// for small models"): which node types to offer, which properties a type has, and which links
/// between chosen nodes are possible at all. A model layer asks for a choice among these instead
/// of free text, so most mistakes cannot be written.
extension AssistantWorkspace {
    /// The node types to offer for `request`: the best keyword matches, a few types that introduce a
    /// value, and then the first types in the registry up to `limit`.
    ///
    /// Matching words alone misses the plainest needs: "add four and eight" matches `math.add` but
    /// nothing that makes a four. So a few value sources (no inputs, an output, something to set,
    /// like a number or a text constant) are always offered. This is a structural rule; it knows
    /// nothing about any domain. It is also still a keyword search, so a request in words the
    /// registry does not use may miss the right type, which the model-driven `searchNodes` tool
    /// can cover.
    public func candidateNodeTypes(for request: String, limit: Int = 12) -> [NodeSummary] {
        let everything = searchNodes("", limit: .max)
        let isSource: (NodeSummary) -> Bool = { summary in
            guard let definition = nodes.definition(for: summary.typeID) else { return false }
            return definition.inputs.isEmpty && !definition.dynamicPorts.contains { $0.direction == .input }
                && !definition.outputs.isEmpty && !definition.properties.isEmpty
        }
        let reserved = min(4, limit / 3)
        var chosen = Array(searchNodes(request, limit: max(limit - reserved, 0)))
        func add(_ candidates: [NodeSummary], upTo count: Int) {
            for candidate in candidates where chosen.count < count && !chosen.contains(where: { $0.typeID == candidate.typeID }) {
                chosen.append(candidate)
            }
        }
        add(everything.filter(isSource), upTo: chosen.count + reserved)
        add(everything, upTo: limit)
        return chosen
    }

    /// The settings of a node type a model can fill in. Empty for an unknown type.
    public func propertySlots(type: String) -> [PropertySlot] {
        guard let definition = nodes.definition(for: NodeTypeID(type)) else { return [] }
        return definition.properties.compactMap { property in
            let shape: PropertySlot.Shape
            switch property.kind {
            case .bool: shape = .bool
            case .int(let low, let high, _): shape = .int(min: low.map(Int.init), max: high.map(Int.init))
            case .double(let low, let high, _): shape = .double(min: low, max: high)
            case .string: shape = .text
            case .choice(let choices): shape = .choice(choices.map(\.value))
            case .variable, .color, .vector, .custom: return nil
            }
            return PropertySlot(
                id: property.id.rawValue, title: property.displayName, shape: shape,
                defaultText: GraphDigest.format(property.defaultValue, limit: 30))
        }
    }

    /// Every link between two of `nodes` that the editor would accept, written `alias.out -> alias.in`.
    ///
    /// Each pair is tried on its own through the same compiler that checks a finished spec, so
    /// direction and type rules are the real ones. Whether several chosen links fit together (two
    /// into one input, a cycle) is not known here; the compiler reports that afterwards.
    /// Dynamic ports are not offered.
    public func linkCandidates(among specs: [GraphSpec.NodeSpec], limit: Int = 80) -> [GraphSpec.LinkSpec] {
        let compiler = GraphSpecCompiler(nodes: nodes, types: types, connectionValidator: connectionValidator)
        var found: [GraphSpec.LinkSpec] = []
        for source in specs {
            guard let from = nodes.definition(for: NodeTypeID(source.type)) else { continue }
            for target in specs where target.alias != source.alias {
                guard let to = nodes.definition(for: NodeTypeID(target.type)) else { continue }
                for output in from.outputs where output.group == nil {
                    for input in to.inputs where input.group == nil {
                        let link = GraphSpec.LinkSpec(
                            from: "\(source.alias).\(output.id.rawValue)", to: "\(target.alias).\(input.id.rawValue)")
                        let pair = GraphSpec(
                            nodes: [.init(alias: source.alias, type: source.type), .init(alias: target.alias, type: target.type)],
                            links: [link])
                        if compiler.compile(pair).isClean {
                            found.append(link)
                            if found.count >= limit { return found }
                        }
                    }
                }
            }
        }
        return found
    }
}
