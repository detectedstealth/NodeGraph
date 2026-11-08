import CoreGraphics
import Testing
import NodeGraphCore
@testable import NodeGraphUI

@Suite struct NodeAppearanceDrawingTests {
    @Test func shapesSetTheCornersTheyRound() {
        #expect(NodeCorners.radii(for: .box, radius: 6) == NodeCorners(topLeading: 0, bottomLeading: 0, bottomTrailing: 0, topTrailing: 0))
        #expect(NodeCorners.radii(for: .round, radius: 6) == NodeCorners(topLeading: 6, bottomLeading: 6, bottomTrailing: 6, topTrailing: 6))
        #expect(NodeCorners.radii(for: .card, radius: 6) == NodeCorners(topLeading: 6, bottomLeading: 0, bottomTrailing: 6, topTrailing: 0))
    }

    @Test func aTitleBarTakesTheTopCornersAndTheBottomOnesWhenCollapsed() {
        let round = NodeCorners.radii(for: .round, radius: 6)
        #expect(round.header(isCollapsed: false) == NodeCorners(topLeading: 6, bottomLeading: 0, bottomTrailing: 0, topTrailing: 6))
        #expect(round.header(isCollapsed: true) == round)
        let card = NodeCorners.radii(for: .card, radius: 6)
        #expect(card.header(isCollapsed: false) == NodeCorners(topLeading: 6, bottomLeading: 0, bottomTrailing: 0, topTrailing: 0))
        #expect(card.header(isCollapsed: true) == card)
    }

    @Test func titleModesDecideWhatIsDrawn() {
        #expect(TitleStyle(.normal, isActive: false) == TitleStyle(.normal, isActive: true))
        #expect(TitleStyle(.normal, isActive: false).drawsBar && TitleStyle(.normal, isActive: false).drawsTitle)
        let hidden = TitleStyle(.hidden, isActive: true)
        #expect(!hidden.drawsBar && !hidden.drawsTitle)
        let transparent = TitleStyle(.transparent, isActive: false)
        #expect(!transparent.drawsBar && transparent.drawsTitle)
        #expect(TitleStyle(.autohide, isActive: false) == TitleStyle(.hidden, isActive: false))
        #expect(TitleStyle(.autohide, isActive: true) == TitleStyle(.normal, isActive: true))
    }

    @Test(arguments: PortShape.allCases)
    func everyPortShapeDrawsInsideAboutItsRadius(shape: PortShape) {
        let center = CGPoint(x: 50, y: 20)
        let bounds = shape.path(center: center, radius: 5).boundingRect
        #expect(!bounds.isEmpty)
        #expect(bounds.width <= 14 && bounds.height <= 14, "\(shape) \(bounds)")
        #expect(bounds.contains(center) || shape == .grid, "\(shape) surrounds its center")
        #expect(abs(bounds.midY - center.y) < 0.01, "\(shape) is centered vertically")
    }

    @Test func theShapesLookDifferent() {
        let paths = PortShape.allCases.map { $0.path(center: .zero, radius: 5) }
        for (i, a) in paths.enumerated() {
            for b in paths[(i + 1)...] { #expect(a != b) }
        }
    }
}

@MainActor
@Suite struct NodeAppearanceModelTests {
    private func rig() throws -> (model: GraphEditorModel, a: Node, b: Node) {
        let model = TestKit.makeModel()
        let a = Node(typeID: TestKit.source, position: GraphPoint(x: 0, y: 0))
        let b = Node(typeID: TestKit.sink, position: GraphPoint(x: 300, y: 0))
        try model.perform(.addNode(node: a))
        try model.perform(.addNode(node: b))
        return (model, a, b)
    }

    @Test func aPortUsesItsOwnShapeThenTriggerThenItsTypeThenACircle() {
        let model = TestKit.makeModel()
        model.editor.types.register(PortTypeInfo(
            type: "grid", displayName: "Grid", color: RGBAColor(red: 0, green: 0, blue: 0), shape: .grid))
        func shape(_ port: PortDefinition) -> PortShape { model.portShape(of: port) }
        #expect(shape(PortDefinition(id: "a", direction: .input, type: "number")) == .circle)
        #expect(shape(PortDefinition(id: "a", direction: .input, type: "grid")) == .grid)
        #expect(shape(PortDefinition(id: "a", direction: .input, kind: .trigger)) == .diamond)
        #expect(shape(PortDefinition(id: "a", direction: .input, type: "grid", shape: .arrow)) == .arrow)
        #expect(shape(PortDefinition(id: "a", direction: .input, kind: .trigger, shape: .square)) == .square)
        #expect(shape(PortDefinition(id: "a", direction: .input, type: "unregistered")) == .circle)
    }

    @Test func theInspectorSetsShapeAndTitleBarForSeveralNodesAsOneStep() throws {
        let (model, a, b) = try rig()
        #expect(model.setShape(.card, of: [a.id, b.id]))
        #expect(model.setTitleMode(.autohide, of: [a.id, b.id]))
        #expect(model.graph.nodes[a.id]?.shape == .card && model.graph.nodes[b.id]?.titleMode == .autohide)
        #expect(!model.setShape(.card, of: [a.id, b.id]), "nothing to change")
        try model.undo()
        #expect(model.graph.nodes[a.id]?.titleMode == nil && model.graph.nodes[a.id]?.shape == .card)
        try model.undo()
        #expect(model.graph.nodes[b.id]?.shape == nil)
        #expect(model.setShape(.box, of: [a.id]) && model.setShape(nil, of: [a.id]))
        #expect(model.graph.nodes[a.id]?.shape == nil, "Default clears the override")
    }

    @Test func inspectionReportsTheNodesOwnChoices() throws {
        let (model, a, _) = try rig()
        model.setShape(.box, of: [a.id])
        model.select(node: a.id)
        guard case .node(let info) = model.inspection() else { Issue.record("expected a node"); return }
        #expect(info.shape == .box && info.titleMode == nil)
    }

    @Test func commandsAndMenuApplyToTheSelectionAndCheckTheSharedChoice() throws {
        let (model, a, b) = try rig()
        let controller = GraphInteractionController(model: model)
        model.selection = GraphSelection(nodes: [a.id, b.id])
        #expect(controller.perform(.setShape(.card)))
        #expect(controller.perform(.setTitleMode(.transparent)))
        #expect([a.id, b.id].allSatisfy { model.graph.nodes[$0]?.shape == .card && model.graph.nodes[$0]?.titleMode == .transparent })

        let frame = try #require(model.layout(of: a.id)).frame
        let menu = controller.contextMenu(at: CGPoint(x: frame.minX + 20, y: frame.minY + 8))
        func checked(_ submenu: String) -> [String] {
            guard case .submenu(let items)? = menu.first(where: { $0.title == submenu })?.kind else { return [] }
            return items.filter(\.isChecked).map(\.title)
        }
        #expect(checked("Shape") == ["Card"])
        #expect(checked("Title Bar") == ["Transparent"])
        // Mixed choices check nothing.
        model.setShape(.box, of: [a.id])
        model.selection = GraphSelection(nodes: [a.id, b.id])
        let mixed = controller.contextMenu(at: CGPoint(x: frame.minX + 20, y: frame.minY + 8))
        guard case .submenu(let items)? = mixed.first(where: { $0.title == "Shape" })?.kind else { Issue.record("no submenu"); return }
        #expect(items.allSatisfy { !$0.isChecked })
    }

    @Test func aTypesOwnShapeIsWhatTheMenuChecksUntilTheNodeChoosesOne() throws {
        let model = TestKit.makeModel()
        var nodes = model.editor.nodes
        nodes.register(NodeDefinition(typeID: "test.styled", displayName: "Styled", shape: .box)) { _ in .empty }
        let styled = GraphEditorModel(editor: GraphEditor(nodes: nodes, types: model.editor.types))
        let node = Node(typeID: "test.styled")
        try styled.perform(.addNode(node: node))
        let controller = GraphInteractionController(model: styled)
        let frame = try #require(styled.layout(of: node.id)).frame
        let menu = controller.contextMenu(at: CGPoint(x: frame.minX + 20, y: frame.minY + 8))
        guard case .submenu(let items)? = menu.first(where: { $0.title == "Shape" })?.kind else { Issue.record("no submenu"); return }
        #expect(items.filter(\.isChecked).map(\.title) == ["Box"])
    }

    @Test func aReadOnlyCanvasRefusesAndDisablesThem() throws {
        let (model, a, _) = try rig()
        let controller = GraphInteractionController(model: model)
        model.select(node: a.id)
        let frame = try #require(model.layout(of: a.id)).frame
        let menu = controller.contextMenu(at: CGPoint(x: frame.minX + 20, y: frame.minY + 8))
        model.isEditable = false
        #expect(!controller.perform(.setShape(.box)) && !controller.perform(.setTitleMode(.hidden)))
        #expect(CanvasCommand.setShape(.box).isEdit && CanvasCommand.setTitleMode(.hidden).isEdit)
        let readOnly = controller.contextMenu(at: CGPoint(x: frame.minX + 20, y: frame.minY + 8))
        #expect(readOnly.first { $0.title == "Shape" }?.isEnabled == false)
        #expect(readOnly.first { $0.title == "Title Bar" }?.isEnabled == false)
        #expect(menu.first { $0.title == "Shape" }?.isEnabled == true)
    }
}
