import Collections

/// Why a graph could not be compiled into an ``ExecutionPlan``.
public enum ExecutionPlanError: Error, Hashable, Sendable {
    /// Groups of nodes that depend on each other in a loop. Each group is in storage order.
    case cycle(components: [[NodeID]])

    /// The error as diagnostics, one per node in each cycle.
    public var diagnostics: [GraphDiagnostic] {
        switch self {
        case .cycle(let components):
            components.flatMap { component in
                component.map {
                    GraphDiagnostic(
                        code: .executionCycle,
                        message: "Node is part of a cycle of \(component.count) node(s); mark one as a feedback node to allow it.",
                        node: $0)
                }
            }
        }
    }
}

/// A compiled evaluation order for a graph.
///
/// Nodes run in dependency order: a node comes after every node that feeds it. Ties are broken
/// by the node's position in the graph's storage, so the same graph always produces the same
/// plan. Links leaving a feedback node (``NodeDefinition/isFeedback``) are ignored for ordering
/// and listed in ``feedbackLinks``; they carry the previous evaluation's value.
public struct ExecutionPlan: Hashable, Sendable {
    /// Every node, in a valid execution order.
    public let order: [NodeID]
    /// Nodes grouped by depth. Everything in one level depends only on earlier levels, so a
    /// level can run concurrently. Concatenated, the levels hold the same nodes as ``order``.
    public let levels: [[NodeID]]
    /// Links whose value comes from the previous evaluation rather than this one.
    public let feedbackLinks: [LinkID]

    public init(order: [NodeID], levels: [[NodeID]], feedbackLinks: [LinkID]) {
        self.order = order
        self.levels = levels
        self.feedbackLinks = feedbackLinks
    }

    /// Compiles `graph`.
    ///
    /// Node types missing from `nodes` are treated as ordinary nodes; running them is the
    /// runner's concern. Links to nodes that do not exist are ignored.
    ///
    /// - Throws: ``ExecutionPlanError/cycle(components:)`` if nodes depend on each other in a loop
    ///   that no feedback node breaks.
    public static func compile(_ graph: Graph, nodes registry: NodeRegistry) throws -> ExecutionPlan {
        let ids = Array(graph.nodes.keys)
        var position: [NodeID: Int] = [:]
        position.reserveCapacity(ids.count)
        for (index, id) in ids.enumerated() { position[id] = index }

        // Ordering edges between node positions; feedback links are set aside.
        var successors = [[Int]](repeating: [], count: ids.count)
        var remainingInputs = [Int](repeating: 0, count: ids.count)
        var feedbackLinks: [LinkID] = []
        for link in graph.links.values {
            guard let from = position[link.source.node], let to = position[link.target.node] else { continue }
            let sourceNode = graph.nodes[link.source.node]!
            if registry.definition(for: sourceNode.typeID)?.isFeedback == true {
                feedbackLinks.append(link.id)
                continue
            }
            successors[from].append(to)
            remainingInputs[to] += 1
        }

        // Kahn's algorithm. Always taking the lowest storage position keeps the order deterministic.
        var ready = Heap<Int>((0..<ids.count).filter { remainingInputs[$0] == 0 })
        var level = [Int](repeating: 0, count: ids.count)
        var order: [Int] = []
        order.reserveCapacity(ids.count)
        while let next = ready.popMin() {
            order.append(next)
            for successor in successors[next] {
                level[successor] = max(level[successor], level[next] + 1)
                remainingInputs[successor] -= 1
                if remainingInputs[successor] == 0 { ready.insert(successor) }
            }
        }

        guard order.count == ids.count else {
            let stuck = Set((0..<ids.count).filter { remainingInputs[$0] > 0 })
            let components = cycles(among: stuck, successors: successors)
            throw ExecutionPlanError.cycle(components: components.map { $0.map { ids[$0] } })
        }

        var levels: [[NodeID]] = []
        for index in order {
            if level[index] == levels.count { levels.append([]) }
            levels[level[index]].append(ids[index])
        }
        return ExecutionPlan(order: order.map { ids[$0] }, levels: levels, feedbackLinks: feedbackLinks)
    }

    /// Strongly connected components of `nodes` that are real cycles (more than one node, or a
    /// node linked to itself), via an iterative Tarjan so deep graphs cannot overflow the stack.
    /// Components and their members are sorted by storage position.
    private static func cycles(among nodes: Set<Int>, successors: [[Int]]) -> [[Int]] {
        var index = 0
        var indices: [Int: Int] = [:]
        var lowLink: [Int: Int] = [:]
        var onStack = Set<Int>()
        var stack: [Int] = []
        var components: [[Int]] = []

        for root in nodes.sorted() where indices[root] == nil {
            // Each frame is a node and how many of its successors have been visited.
            var work: [(node: Int, next: Int)] = [(root, 0)]
            indices[root] = index; lowLink[root] = index; index += 1
            stack.append(root); onStack.insert(root)

            while let (node, next) = work.last {
                let edges = successors[node]
                if next < edges.count {
                    work[work.count - 1].next += 1
                    let successor = edges[next]
                    guard nodes.contains(successor) else { continue }
                    if indices[successor] == nil {
                        indices[successor] = index; lowLink[successor] = index; index += 1
                        stack.append(successor); onStack.insert(successor)
                        work.append((successor, 0))
                    } else if onStack.contains(successor) {
                        lowLink[node] = min(lowLink[node]!, indices[successor]!)
                    }
                } else {
                    work.removeLast()
                    if let parent = work.last?.node {
                        lowLink[parent] = min(lowLink[parent]!, lowLink[node]!)
                    }
                    if lowLink[node] == indices[node] {
                        var component: [Int] = []
                        while let member = stack.popLast() {
                            onStack.remove(member)
                            component.append(member)
                            if member == node { break }
                        }
                        if component.count > 1 || successors[node].contains(node) {
                            components.append(component.sorted())
                        }
                    }
                }
            }
        }
        return components.sorted { $0[0] < $1[0] }
    }
}
