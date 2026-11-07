import CoreGraphics
import Testing
import NodeGraphCore
@testable import NodeGraphUI

@Suite struct NodeCatalogTests {
    private func catalog() -> NodeCatalog {
        var nodes = NodeRegistry()
        var types = TypeRegistry()
        types.register(PortTypeInfo(type: "number", displayName: "Number", color: RGBAColor(red: 0, green: 0, blue: 1)))
        types.register(PortTypeInfo(type: "int", displayName: "Int", color: RGBAColor(red: 0, green: 1, blue: 1), acceptsFrom: []))
        types.register(PortTypeInfo(type: "string", displayName: "String", color: RGBAColor(red: 0, green: 1, blue: 0)))
        types.registerConversion(from: "number", to: "string")
        func add(_ id: String, _ name: String, _ category: String, inputs: [(String, PortType)] = [], outputs: [(String, PortType)] = []) {
            nodes.register(NodeDefinition(
                typeID: NodeTypeID(id), displayName: name, category: category,
                ports: inputs.map { PortDefinition(id: PortID($0.0), direction: .input, type: $0.1) }
                    + outputs.map { PortDefinition(id: PortID($0.0), direction: .output, type: $0.1) }))
        }
        add("math.add", "Add", "Math", inputs: [("a", "number"), ("b", "number")], outputs: [("result", "number")])
        add("math.sine", "Sine", "Math", inputs: [("value", "number")], outputs: [("result", "number")])
        add("string.upper", "Upper Case", "String", inputs: [("text", "string")], outputs: [("result", "string")])
        add("util.number", "Number", "Utility", outputs: [("value", "number")])
        add("util.note", "Note", "", inputs: [])
        nodes.register(NodeDefinition(typeID: "ghost", displayName: "Missing: ghost", category: "Missing"))
        return NodeCatalog(nodes: nodes, types: types)
    }

    @Test func listsEveryNodeByCategoryAndHidesPlaceholders() {
        let catalog = catalog()
        #expect(catalog.entries.map(\.displayName) == ["Add", "Sine", "Note", "Upper Case", "Number"])
        #expect(catalog.categories.map(\.name) == ["Math", "Other", "String", "Utility"])
        #expect(!catalog.entries.contains { $0.id == "ghost" })
    }

    @Test func emptyQueryReturnsEverythingInBrowseOrder() {
        let catalog = catalog()
        #expect(catalog.search("").map(\.id) == catalog.entries.map(\.id))
    }

    @Test func prefixBeatsWordStartBeatsSubstring() {
        let catalog = catalog()
        #expect(catalog.search("add").first?.entry.displayName == "Add")
        #expect(catalog.search("case").first?.entry.displayName == "Upper Case")  // a word start
        #expect(catalog.search("ine").map(\.entry.displayName) == ["Sine"])  // a substring
    }

    @Test func everyWordMustMatchAndCategoryAndTypeCountToo() {
        let catalog = catalog()
        #expect(catalog.search("math sine").map(\.entry.displayName) == ["Sine"])
        #expect(catalog.search("math zzz").isEmpty)
        #expect(catalog.search("util.").map(\.entry.displayName) == ["Note", "Number"])
    }

    @Test func lettersInOrderStillMatchWeakly() {
        let catalog = catalog()
        let names = catalog.search("sn").map(\.entry.displayName)
        #expect(names == ["Sine"])
        #expect(catalog.search("xyz").isEmpty)
    }

    @Test func draggingFromAnOutputOffersNodesWithAnInputItCanFeed() {
        let catalog = catalog()
        let filter = PortFilter(direction: .output, type: "number", kind: .data)
        let found = catalog.search("", connecting: filter)
        // Add and Sine take a number; Upper Case takes a string that a number converts to.
        #expect(Set(found.map(\.entry.displayName)) == ["Add", "Sine", "Upper Case"])
        #expect(found.first { $0.entry.displayName == "Add" }?.port?.id == "a")
        #expect(found.first { $0.entry.displayName == "Upper Case" }?.port?.id == "text")
        // The wrong kind of link finds nothing.
        #expect(catalog.search("", connecting: PortFilter(direction: .output, type: "number", kind: .trigger)).isEmpty)
    }

    @Test func draggingFromAnInputOffersNodesWithAnOutputThatCanFeedIt() {
        let catalog = catalog()
        let filter = PortFilter(direction: .input, type: "number", kind: .data)
        let names = Set(catalog.search("", connecting: filter).map(\.entry.displayName))
        #expect(names == ["Add", "Sine", "Number"])
    }

    @Test func linkSearchStillRanksByQuery() {
        let catalog = catalog()
        let filter = PortFilter(direction: .output, type: "number", kind: .data)
        #expect(catalog.search("si", connecting: filter).first?.entry.displayName == "Sine")
    }

    @Test func anIdenticalTypeIsPreferredOverAConversion() {
        var nodes = NodeRegistry()
        var types = TypeRegistry()
        types.register(PortTypeInfo(type: "number", displayName: "Number", color: RGBAColor(red: 0, green: 0, blue: 1)))
        types.register(PortTypeInfo(type: "string", displayName: "String", color: RGBAColor(red: 0, green: 1, blue: 0)))
        types.registerConversion(from: "number", to: "string")
        nodes.register(NodeDefinition(
            typeID: "mixed", displayName: "Mixed",
            ports: [
                PortDefinition(id: "text", direction: .input, type: "string"),
                PortDefinition(id: "n", direction: .input, type: "number"),
            ]))
        let found = NodeCatalog(nodes: nodes, types: types)
            .search("", connecting: PortFilter(direction: .output, type: "number", kind: .data))
        #expect(found.first?.port?.id == "n")
    }
}

@MainActor
@Suite struct AddNodeInteractionTests {
    let model = TestKit.makeModel()
    let controller: GraphInteractionController
    var clock = ContinuousClock.Instant.now

    init() {
        controller = GraphInteractionController(model: model)
    }

    private func match(_ type: NodeTypeID, port: PortID? = nil) throws -> NodeCatalogMatch {
        let catalog = model.makeNodeCatalog()
        let entry = try #require(catalog.entries.first { $0.id == type })
        let definition = entry.definition.resolved(for: Node(typeID: type))
        return NodeCatalogMatch(entry: entry, score: 0, port: port.flatMap { id in definition.ports.first { $0.id == id } })
    }

    @Test func theCatalogListsTheRegisteredTypes() {
        let names = model.makeNodeCatalog().entries.map(\.displayName)
        #expect(names.contains("Source") && names.contains("Sink") && names.contains("Widgets"))
    }

    @Test func aDoubleClickOnEmptyCanvasOpensTheSearchThere() {
        var time = ContinuousClock.Instant.now
        controller.now = { time }
        controller.pointerDown(at: CGPoint(x: 500, y: 500), kind: .mouse)
        controller.pointerUp(at: CGPoint(x: 500, y: 500))
        #expect(controller.addNodeRequest == nil)
        time += .milliseconds(200)
        controller.pointerDown(at: CGPoint(x: 504, y: 502), kind: .mouse)
        controller.pointerUp(at: CGPoint(x: 504, y: 502))
        #expect(controller.addNodeRequest?.screenPoint == CGPoint(x: 504, y: 502))
        #expect(controller.addNodeRequest?.anchor == nil)
    }

    @Test func slowOrDistantClicksAreNotADoubleClick() {
        var time = ContinuousClock.Instant.now
        controller.now = { time }
        controller.pointerDown(at: CGPoint(x: 500, y: 500), kind: .mouse)
        controller.pointerUp(at: CGPoint(x: 500, y: 500))
        time += .seconds(1)
        controller.pointerDown(at: CGPoint(x: 500, y: 500), kind: .mouse)
        controller.pointerUp(at: CGPoint(x: 500, y: 500))
        #expect(controller.addNodeRequest == nil)
        time += .milliseconds(100)
        controller.pointerDown(at: CGPoint(x: 700, y: 500), kind: .mouse)
        controller.pointerUp(at: CGPoint(x: 700, y: 500))
        #expect(controller.addNodeRequest == nil)
    }

    @Test func aPressElsewhereClosesTheSearch() {
        controller.beginAddNode(at: CGPoint(x: 100, y: 100))
        #expect(controller.addNodeRequest != nil)
        controller.pointerDown(at: CGPoint(x: 600, y: 600), kind: .mouse)
        #expect(controller.addNodeRequest == nil)
    }

    @Test func escapeClosesTheSearch() {
        controller.beginAddNode(at: CGPoint(x: 100, y: 100))
        #expect(controller.perform(.escape))
        #expect(controller.addNodeRequest == nil)
    }

    @Test func theCommandOpensItAtThePointerOrTheCenter() {
        model.viewSize = CGSize(width: 800, height: 600)
        controller.perform(.addNode(at: nil))
        #expect(controller.addNodeRequest?.screenPoint == CGPoint(x: 400, y: 300))
        controller.cancelAddNode()
        controller.hover(at: CGPoint(x: 120, y: 90))
        controller.perform(.addNode(at: nil))
        #expect(controller.addNodeRequest?.screenPoint == CGPoint(x: 120, y: 90))
        controller.cancelAddNode()
        controller.perform(.addNode(at: GraphPoint(x: 10, y: 20)))
        #expect(controller.addNodeRequest?.graphPoint == GraphPoint(x: 10, y: 20))
    }

    @Test func shiftAIsBoundToIt() {
        #expect(CanvasKeyMap.command(for: .character("A"), modifiers: .shift) == .addNode(at: nil))
        #expect(CanvasKeyMap.command(for: .character("a"), modifiers: .command) == .selectAll)
    }

    @Test func addingCentersTheNodeOnThePointAndSelectsItAsOneStep() throws {
        controller.beginAddNode(at: CGPoint(x: 400, y: 300))
        let before = model.history.undoStack.count
        let id = try #require(controller.addNode(try match(TestKit.source)))
        let node = try #require(model.graph.nodes[id])
        let layout = try #require(model.layout(of: id))
        #expect(abs(layout.frame.midX - 400) < 1e-9)
        #expect(node.position.y == 300 - model.metrics.headerHeight / 2)
        #expect(model.selection.nodes == [id])
        #expect(controller.addNodeRequest == nil)
        #expect(model.history.undoStack.count == before + 1)
        try model.undo()
        #expect(model.graph.nodes.isEmpty)
    }

    @Test func addingWithSnapPutsTheNodeOnTheGrid() throws {
        model.snapsToGrid = true
        controller.beginAddNode(at: CGPoint(x: 413, y: 307))
        let id = try #require(controller.addNode(try match(TestKit.source)))
        let position = try #require(model.graph.nodes[id]).position
        let spacing = model.theme.gridSpacing
        #expect(position.x.truncatingRemainder(dividingBy: spacing) == 0)
        #expect(position.y.truncatingRemainder(dividingBy: spacing) == 0)
    }

    @Test func addingFromADraggedOutputLinksAndAlignsThePort() throws {
        let source = Node(typeID: TestKit.source, position: .zero)
        try model.perform(.addNode(node: source))
        let out = try #require(model.layout(of: source.id)?.outputs.first)
        controller.pointerDown(at: CGPoint(out.position), kind: .mouse)
        controller.pointerMoved(to: CGPoint(x: 500, y: 400))
        controller.pointerUp(at: CGPoint(x: 500, y: 400))
        let request = try #require(controller.addNodeRequest)
        let filter = try #require(request.filter)
        let catalog = model.makeNodeCatalog()
        let found = try #require(catalog.search("sink", connecting: filter).first)
        #expect(found.port?.id == "a")

        let before = model.history.undoStack.count
        let id = try #require(controller.addNode(found))
        let link = try #require(model.graph.links.values.first)
        #expect(link.source.node == source.id && link.target.node == id && link.target.port == "a")
        // The connected input sits exactly where the link was released.
        let input = try #require(model.layout(of: id)?.port(link.target))
        #expect(abs(input.position.x - 500) < 1e-9 && abs(input.position.y - 400) < 1e-9)
        #expect(model.history.undoStack.count == before + 1)
        try model.undo()
        #expect(model.graph.nodes.count == 1 && model.graph.links.isEmpty)
    }

    @Test func addingFromADraggedInputPutsTheOutputAtThePoint() throws {
        let sink = Node(typeID: TestKit.sink, position: GraphPoint(x: 600, y: 100))
        try model.perform(.addNode(node: sink))
        let input = try #require(model.layout(of: sink.id)?.inputs.first)
        controller.pointerDown(at: CGPoint(input.position), kind: .mouse)
        controller.pointerMoved(to: CGPoint(x: 300, y: 400))
        controller.pointerUp(at: CGPoint(x: 300, y: 400))
        let filter = try #require(controller.addNodeRequest?.filter)
        let found = try #require(model.makeNodeCatalog().search("source", connecting: filter).first)
        let id = try #require(controller.addNode(found))
        let link = try #require(model.graph.links.values.first)
        #expect(link.source.node == id && link.target.node == sink.id)
        let output = try #require(model.layout(of: id)?.port(link.source))
        #expect(abs(output.position.x - 300) < 1e-9 && abs(output.position.y - 400) < 1e-9)
    }

    @Test func addingWithoutARequestDoesNothing() throws {
        #expect(controller.addNode(try match(TestKit.source)) == nil)
        #expect(model.graph.nodes.isEmpty)
    }
}
