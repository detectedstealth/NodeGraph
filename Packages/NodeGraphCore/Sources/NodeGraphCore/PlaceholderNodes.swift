extension NodeRegistry {
    /// A copy that also defines a placeholder for every node type in `graph` that is not
    /// already registered, so a document saved with a missing pack can still be shown and edited.
    ///
    /// A placeholder has the ports its existing links use (type `any`; an input takes several links
    /// only if some node of that type already has several) and accepts any
    /// property value. Nothing is lost on save: nodes keep their type id, properties and links.
    public func addingPlaceholders(for graph: Graph) -> NodeRegistry {
        var copy = self
        var inputs: [NodeTypeID: [PortID]] = [:]
        var outputs: [NodeTypeID: [PortID]] = [:]
        var properties: [NodeTypeID: [PropertyID]] = [:]
        var multiInputs: [NodeTypeID: Set<PortID>] = [:]
        var linkCounts: [PortAddress: Int] = [:]
        var missing: [NodeTypeID] = []

        for node in graph.nodes.values where definition(for: node.typeID) == nil {
            if properties[node.typeID] == nil { missing.append(node.typeID) }
            var seen = properties[node.typeID] ?? []
            for id in node.properties.keys.sorted() where !seen.contains(id) { seen.append(id) }
            properties[node.typeID] = seen
        }
        for link in graph.links.values {
            linkCounts[link.target, default: 0] += 1
            if let type = graph.nodes[link.source.node]?.typeID, properties[type] != nil,
               !(outputs[type] ?? []).contains(link.source.port) {
                outputs[type, default: []].append(link.source.port)
            }
            if let type = graph.nodes[link.target.node]?.typeID, properties[type] != nil,
               !(inputs[type] ?? []).contains(link.target.port) {
                inputs[type, default: []].append(link.target.port)
            }
            if let type = graph.nodes[link.target.node]?.typeID, linkCounts[link.target, default: 0] > 1 {
                multiInputs[type, default: []].insert(link.target.port)
            }
        }
        for type in missing {
            let ports = (inputs[type] ?? []).map {
                PortDefinition(id: $0, direction: .input, allowsMultipleLinks: multiInputs[type]?.contains($0) == true)
            } + (outputs[type] ?? []).map {
                PortDefinition(id: $0, direction: .output, allowsMultipleLinks: true)
            }
            copy.register(NodeDefinition(
                typeID: type,
                displayName: "Missing: \(type)",
                category: "Missing",
                ports: ports,
                properties: (properties[type] ?? []).map {
                    PropertyDefinition(id: $0, displayName: $0.rawValue, kind: .custom("unknown"), defaultValue: .null)
                }))
        }
        return copy
    }
}
