import Testing
@testable import NodeGraphCore

private struct Builder {
    var graph = Graph()
    var registry = NodeRegistry()

    init() {
        registry.register(NodeDefinition(typeID: "n", displayName: "N"))
        registry.register(NodeDefinition(typeID: "delay", displayName: "Delay", isFeedback: true))
    }

    mutating func node(_ type: NodeTypeID = "n") -> NodeID {
        let node = Node(typeID: type)
        graph.insert(node)
        return node.id
    }

    @discardableResult
    mutating func link(_ a: NodeID, _ b: NodeID) -> LinkID {
        let link = Link(sourceNode: a, sourcePort: "o", targetNode: b, targetPort: "i")
        graph.insert(link)
        return link.id
    }

    func plan() throws -> ExecutionPlan { try ExecutionPlan.compile(graph, nodes: registry) }
}

@Test func emptyGraphCompilesToAnEmptyPlan() throws {
    let plan = try Builder().plan()
    #expect(plan.order.isEmpty && plan.levels.isEmpty && plan.feedbackLinks.isEmpty)
}

@Test func chainRunsInDependencyOrderEvenWhenStoredBackwards() throws {
    var b = Builder()
    let c = b.node(), bb = b.node(), a = b.node()   // stored c, b, a
    b.link(a, bb)
    b.link(bb, c)
    let plan = try b.plan()
    #expect(plan.order == [a, bb, c])
    #expect(plan.levels == [[a], [bb], [c]])
}

@Test func independentNodesKeepStorageOrder() throws {
    var b = Builder()
    let ids = (0..<5).map { _ in b.node() }
    let plan = try b.plan()
    #expect(plan.order == ids)
    #expect(plan.levels == [ids])
}

@Test func diamondLevelsFollowTheLongestPath() throws {
    var b = Builder()
    let top = b.node(), left = b.node(), right = b.node(), bottom = b.node()
    let shortcut = b.node()
    b.link(top, left); b.link(top, right)
    b.link(left, bottom); b.link(right, bottom)
    b.link(top, shortcut); b.link(bottom, shortcut)
    let plan = try b.plan()
    #expect(plan.levels == [[top], [left, right], [bottom], [shortcut]])
    #expect(plan.order == [top, left, right, bottom, shortcut])
}

@Test func tiesAreBrokenByStoragePositionNotLinkOrder() throws {
    var b = Builder()
    let a = b.node(), c = b.node(), d = b.node()
    b.link(a, d)
    let plan = try b.plan()
    #expect(plan.order == [a, c, d])
}

@Test func compilingTwiceGivesTheSamePlan() throws {
    var b = Builder()
    let ids = (0..<30).map { _ in b.node() }
    for i in stride(from: 0, to: 28, by: 2) { b.link(ids[i], ids[i + 2]); b.link(ids[i + 1], ids[i + 2]) }
    #expect(try b.plan() == b.plan())
}

@Test func multipleLinksBetweenTheSameNodesAreFine() throws {
    var b = Builder()
    let a = b.node(), c = b.node()
    b.link(a, c); b.link(a, c)
    #expect(try b.plan().order == [a, c])
}

@Test func linksToMissingNodesAreIgnored() throws {
    var b = Builder()
    let a = b.node()
    b.link(a, NodeID())
    b.link(NodeID(), a)
    #expect(try b.plan().order == [a])
}

@Test func unregisteredTypesCompileAsOrdinaryNodes() throws {
    var b = Builder()
    let ghost = b.node("ghost"), c = b.node()
    b.link(ghost, c)
    #expect(try b.plan().order == [ghost, c])
}

// MARK: Cycles

@Test func cycleIsReportedWithItsMembers() throws {
    var b = Builder()
    let a = b.node(), bb = b.node(), c = b.node(), outside = b.node()
    b.link(a, bb); b.link(bb, c); b.link(c, a)
    b.link(outside, a)
    do {
        _ = try b.plan()
        Issue.record("Expected a cycle error")
    } catch let error as ExecutionPlanError {
        #expect(error == .cycle(components: [[a, bb, c]]))
        #expect(error.diagnostics.count == 3)
        #expect(error.diagnostics.allSatisfy { $0.code == .executionCycle && $0.node != nil })
    }
}

@Test func nodesDownstreamOfACycleAreNotBlamed() throws {
    var b = Builder()
    let a = b.node(), bb = b.node(), after = b.node()
    b.link(a, bb); b.link(bb, a); b.link(bb, after)
    #expect(throws: ExecutionPlanError.cycle(components: [[a, bb]])) { try b.plan() }
}

@Test func separateCyclesAreReportedSeparately() throws {
    var b = Builder()
    let a = b.node(), bb = b.node(), c = b.node(), d = b.node()
    b.link(a, bb); b.link(bb, a)
    b.link(c, d); b.link(d, c)
    #expect(throws: ExecutionPlanError.cycle(components: [[a, bb], [c, d]])) { try b.plan() }
}

@Test func aSelfLinkIsACycle() throws {
    var b = Builder()
    let a = b.node()
    b.link(a, a)
    #expect(throws: ExecutionPlanError.cycle(components: [[a]])) { try b.plan() }
}

@Test func twoCyclesSharingANodeFormOneComponent() throws {
    var b = Builder()
    let a = b.node(), bb = b.node(), c = b.node()
    b.link(a, bb); b.link(bb, a); b.link(bb, c); b.link(c, bb)
    #expect(throws: ExecutionPlanError.cycle(components: [[a, bb, c]])) { try b.plan() }
}

// MARK: Feedback

@Test func aFeedbackNodeBreaksTheLoop() throws {
    var b = Builder()
    let source = b.node(), sum = b.node(), memory = b.node("delay")
    b.link(source, sum)
    b.link(sum, memory)               // sum feeds the delay
    let back = b.link(memory, sum)    // delay's previous output feeds sum
    let plan = try b.plan()
    #expect(plan.feedbackLinks == [back])
    // The delay runs after what feeds it; sum runs without waiting for it.
    #expect(plan.order.firstIndex(of: sum)! < plan.order.firstIndex(of: memory)!)
    #expect(plan.order.firstIndex(of: source)! < plan.order.firstIndex(of: sum)!)
}

@Test func aFeedbackNodeMayFeedItself() throws {
    var b = Builder()
    let memory = b.node("delay")
    let loop = b.link(memory, memory)
    let plan = try b.plan()
    #expect(plan.order == [memory] && plan.feedbackLinks == [loop])
}

@Test func aLoopWithoutAFeedbackNodeStillFailsWhenOneExistsElsewhere() throws {
    var b = Builder()
    let a = b.node(), bb = b.node(), memory = b.node("delay"), c = b.node()
    b.link(a, bb); b.link(bb, a)
    b.link(memory, c)
    #expect(throws: ExecutionPlanError.cycle(components: [[a, bb]])) { try b.plan() }
}

// MARK: Scale

@Test func tenThousandNodeChainCompilesWithoutDeepRecursion() throws {
    var b = Builder()
    let ids = (0..<10_000).map { _ in b.node() }
    for i in 1..<ids.count { b.link(ids[i - 1], ids[i]) }
    let plan = try b.plan()
    #expect(plan.order == ids && plan.levels.count == 10_000)
}

@Test func tenThousandNodeCycleIsDetectedWithoutDeepRecursion() throws {
    var b = Builder()
    let ids = (0..<10_000).map { _ in b.node() }
    for i in 0..<ids.count { b.link(ids[i], ids[(i + 1) % ids.count]) }
    #expect(throws: ExecutionPlanError.cycle(components: [ids])) { try b.plan() }
}
