extension GraphEditor {
    /// The connections that would keep a flow going across `node` if it were deleted: whatever
    /// feeds its first linked input is connected to whatever its first output of the same kind
    /// feeds. Several sources or targets give every pairing.
    ///
    /// Only proposes; the proposals are checked against the connection rules when connected, so
    /// connect them after removing the node, and expect some to be refused (a type mismatch,
    /// say). Empty when the node is not linked on both sides, or does not exist.
    public func bridgeProposals(deleting node: NodeID, in scope: SubgraphID? = nil) -> [ConnectionProposal] {
        guard let graph = editedGraph(in: scope), let found = graph.nodes[node],
              let definition = nodes.definition(for: found) else { return [] }
        let attached = graph.links(attachedTo: node)
        for input in definition.inputs {
            let feeders = attached.filter { $0.target.node == node && $0.target.port == input.id }
            guard !feeders.isEmpty else { continue }
            for output in definition.outputs where output.kind == input.kind {
                let targets = attached.filter { $0.source.node == node && $0.source.port == output.id }
                guard !targets.isEmpty else { continue }
                return feeders.flatMap { feeder in
                    targets.compactMap { target in
                        // A link from the node to itself has nothing outside to join.
                        feeder.source.node == node || target.target.node == node ? nil
                            : ConnectionProposal(source: feeder.source, target: target.target)
                    }
                }
            }
            // The first linked input has no matching output with links: nothing to bridge.
            return []
        }
        return []
    }
}
