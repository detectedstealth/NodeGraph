import CoreGraphics
import Testing
import NodeGraphCore
@testable import NodeGraphUI

@Suite struct WidgetKindTests {
    private func spec(_ kind: PropertyKind, default value: GraphValue) -> NodeWidgetSpec {
        NodeWidgetSpec(PropertyDefinition(id: "p", displayName: "P", kind: kind, defaultValue: value))
    }

    @Test func propertyKindsChooseTheirWidget() {
        #expect(spec(.bool, default: .bool(false)).kind == .toggle)
        #expect(spec(.double(min: 0, max: 1, step: nil), default: .double(0)).kind == .slider(min: 0, max: 1, step: nil, isInteger: false))
        #expect(spec(.int(min: 0, max: 10, step: 2), default: .int(0)).kind == .slider(min: 0, max: 10, step: 2, isInteger: true))
        #expect(spec(.double(min: 0, max: nil, step: nil), default: .double(0)).kind == .number(min: 0, max: nil, step: nil, isInteger: false))
        #expect(spec(.int(), default: .int(0)).kind == .number(min: nil, max: nil, step: nil, isInteger: true))
        #expect(spec(.string(), default: .string("")).kind == .text)
        #expect(spec(.string(multiline: true), default: .string("")).kind == .multilineText)
        #expect(spec(.color, default: .color(RGBAColor(red: 0, green: 0, blue: 0))).kind == .color)
        #expect(spec(.vector(dimension: 3), default: .vector([0, 0, 0])).kind == .readOnly)
        #expect(spec(.custom("curve"), default: .null).kind == .custom("curve"))
    }

    @Test func multilineTakesThreeRowsAndOthersOne() {
        #expect(WidgetKind.multilineText.rowCount == 3)
        #expect(WidgetKind.toggle.rowCount == 1)
        #expect(WidgetKind.button(action: "go").rowCount == 1)
    }

    @Test func sliderMapsFractionsToValuesAndBack() throws {
        let kind = WidgetKind.slider(min: 10, max: 20, step: nil, isInteger: false)
        #expect(kind.sliderValue(atFraction: 0.5) == .double(15))
        #expect(kind.sliderValue(atFraction: -3) == .double(10))
        #expect(kind.sliderValue(atFraction: 9) == .double(20))
        #expect(kind.fraction(of: .double(12.5)) == 0.25)
        #expect(kind.fraction(of: .string("x")) == nil)
    }

    @Test func sliderSnapsToItsStepAndRoundsIntegers() {
        let stepped = WidgetKind.slider(min: 0, max: 1, step: 0.25, isInteger: false)
        #expect(stepped.sliderValue(atFraction: 0.4) == .double(0.5))
        let integer = WidgetKind.slider(min: 0, max: 10, step: nil, isInteger: true)
        #expect(integer.sliderValue(atFraction: 0.36) == .int(4))
    }

    @Test func scrubbingMovesAboutOneStepPerEightPointsWithinLimits() {
        let ints = WidgetKind.number(min: 0, max: 10, step: nil, isInteger: true)
        #expect(ints.scrubbed(from: .int(5), by: 16) == .int(7))
        #expect(ints.scrubbed(from: .int(5), by: -400) == .int(0))
        let stepped = WidgetKind.number(min: nil, max: nil, step: 0.5, isInteger: false)
        #expect(stepped.scrubbed(from: .double(1), by: 8) == .double(1.5))
        let free = WidgetKind.number(min: nil, max: nil, step: nil, isInteger: false)
        let moved = free.scrubbed(from: .double(1), by: 80)?.numberValue
        #expect(abs((moved ?? 0) - 1.1) < 1e-9)
        #expect(WidgetKind.toggle.scrubbed(from: .bool(true), by: 10) == nil)
    }

    @Test func typedTextParsesAndIsLimited() {
        let ints = WidgetKind.number(min: 0, max: 10, step: nil, isInteger: true)
        #expect(ints.value(fromText: " 7 ") == .int(7))
        #expect(ints.value(fromText: "99") == .int(10))
        #expect(ints.value(fromText: "2.5") == nil)
        #expect(ints.value(fromText: "abc") == nil)
        #expect(ints.value(fromText: "nan") == nil)
        let doubles = WidgetKind.number(min: nil, max: nil, step: nil, isInteger: false)
        #expect(doubles.value(fromText: "2.5") == .double(2.5))
        #expect(WidgetKind.text.value(fromText: "hello") == .string("hello"))
        #expect(WidgetKind.toggle.value(fromText: "1") == nil)
    }

    @Test func valuesDisplayReadably() {
        #expect(WidgetKind.toggle.display(.bool(true)) == "On")
        #expect(WidgetKind.toggle.display(.bool(false)) == "Off")
        let number = WidgetKind.number(min: nil, max: nil, step: nil, isInteger: false)
        #expect(number.display(.double(3)) == "3")
        #expect(number.display(.double(0.12345)) == "0.123")
        #expect(number.display(.double(2.5)) == "2.5")
        #expect(number.display(.int(-4)) == "-4")
        let combo = WidgetKind.combo([PropertyChoice(value: "a", label: "Alpha")])
        #expect(combo.display(.string("a")) == "Alpha")
        #expect(combo.display(.string("zzz")) == "zzz")
        #expect(WidgetKind.color.display(.color(RGBAColor(red: 1, green: 0.5, blue: 0))) == "#FF8000")
        #expect(WidgetKind.readOnly.display(.vector([1, 2.5])) == "(1, 2.5)")
        #expect(WidgetKind.text.display(nil) == "")
    }
}

@MainActor
@Suite struct WidgetLayoutTests {
    @Test func widgetRowsSitBelowThePortsAndGrowTheNode() throws {
        let model = TestKit.makeModel()
        let node = Node(typeID: TestKit.widgets, position: GraphPoint(x: 100, y: 50), size: GraphSize(width: 220, height: 20))
        try model.perform(.addNode(node: node))
        let layout = try #require(model.layout(of: node.id))
        #expect(layout.widgets.map(\.spec.id) == ["flag", "gain", "count", "label", "mode", "tint", "notes"])
        // Rows are stacked in order, inside the node, clear of the header.
        for (above, below) in zip(layout.widgets, layout.widgets.dropFirst()) {
            #expect(above.frame.maxY <= below.frame.minY)
        }
        #expect(layout.widgets.allSatisfy { layout.frame.contains($0.frame) })
        #expect(layout.widgets[0].frame.minY >= layout.header.maxY)
        #expect(layout.widgets[6].frame.size.height == 3 * model.metrics.widgetRowHeight)
        // The requested 20-unit height cannot hold the widgets, so the node grew.
        #expect(layout.frame.size.height == layout.minimumSize.height)
    }

    @Test func nodesWithoutPropertiesAreUnchanged() throws {
        let model = TestKit.makeModel()
        let node = Node(typeID: TestKit.sink)
        try model.perform(.addNode(node: node))
        let layout = try #require(model.layout(of: node.id))
        #expect(layout.widgets.isEmpty)
        #expect(layout.frame.size.height == model.metrics.headerHeight + 2 * model.metrics.portInset + 2 * model.metrics.portRowHeight + 0)
    }

    @Test func collapsedNodesHaveNoWidgetRows() throws {
        let model = TestKit.makeModel()
        let node = Node(typeID: TestKit.widgets, isCollapsed: true)
        try model.perform(.addNode(node: node))
        #expect(try #require(model.layout(of: node.id)).widgets.isEmpty)
    }

    @Test func widgetLookupByPoint() throws {
        let model = TestKit.makeModel()
        let node = Node(typeID: TestKit.widgets)
        try model.perform(.addNode(node: node))
        let layout = try #require(model.layout(of: node.id))
        let gain = try #require(layout.widgets.first { $0.spec.id == "gain" })
        #expect(layout.widget(at: GraphPoint(x: gain.frame.midX, y: gain.frame.midY))?.spec.id == "gain")
        #expect(layout.widget(at: GraphPoint(x: 1, y: 1)) == nil)
    }

    private struct ButtonProvider: NodeWidgetProvider {
        func widgets(for node: Node, definition: NodeDefinition) -> [NodeWidgetSpec] {
            definition.typeID == TestKit.source ? [.button("Reset", action: "reset")] : []
        }
    }

    @Test func aProviderAddsButtonsAfterTheProperties() throws {
        let model = TestKit.makeModel()
        model.widgetProvider = ButtonProvider()
        let source = Node(typeID: TestKit.source)
        let other = Node(typeID: TestKit.sink)
        try model.perform(.addNode(node: source))
        try model.perform(.addNode(node: other))
        #expect(try #require(model.layout(of: source.id)).widgets.map(\.spec.id) == ["button.reset"])
        #expect(try #require(model.layout(of: other.id)).widgets.isEmpty)
    }
}

/// Drives the controller at zoom 1 with the camera at the origin, so screen equals graph.
@MainActor
@Suite struct WidgetInteractionTests {
    let model = TestKit.makeModel()
    let controller: GraphInteractionController
    let node: Node

    init() throws {
        controller = GraphInteractionController(model: model)
        node = Node(typeID: TestKit.widgets, position: GraphPoint(x: 100, y: 100))
        try model.perform(.addNode(node: node))
    }

    private func widget(_ id: String) throws -> WidgetLayout {
        try #require(model.layout(of: node.id)?.widgets.first { $0.spec.id == id })
    }

    private func center(_ id: String) throws -> CGPoint {
        let frame = try widget(id).frame
        return CGPoint(x: frame.midX, y: frame.midY)
    }

    private func value(_ id: String) -> GraphValue? {
        model.graph.nodes[node.id]?.properties[PropertyID(id)]
    }

    private func click(_ point: CGPoint) {
        controller.pointerDown(at: point, kind: .mouse)
        controller.pointerUp(at: point)
    }

    @Test func clickingAToggleFlipsItAsOneUndoStep() throws {
        let before = model.history.undoStack.count
        click(try center("flag"))
        #expect(value("flag") == .bool(true))
        #expect(model.history.undoStack.count == before + 1)
        click(try center("flag"))
        #expect(value("flag") == .bool(false))
        try model.undo()
        #expect(value("flag") == .bool(true))
    }

    @Test func pressingAWidgetSelectsItsNodeButDoesNotMoveIt() throws {
        let start = try center("flag")
        controller.pointerDown(at: start, kind: .mouse)
        controller.pointerMoved(to: CGPoint(x: start.x + 80, y: start.y + 80))
        controller.pointerUp(at: CGPoint(x: start.x + 80, y: start.y + 80))
        #expect(model.selection.nodes == [node.id])
        #expect(model.graph.nodes[node.id]?.position == GraphPoint(x: 100, y: 100))
    }

    @Test func aSliderFollowsThePointerAsOneUndoStep() throws {
        let frame = try widget("gain").frame
        let y = frame.midY
        let before = model.history.undoStack.count
        controller.pointerDown(at: CGPoint(x: frame.minX + frame.size.width * 0.2, y: y), kind: .mouse)
        controller.pointerMoved(to: CGPoint(x: frame.minX + frame.size.width * 0.5, y: y))
        controller.pointerMoved(to: CGPoint(x: frame.minX + frame.size.width * 0.9, y: y))
        controller.pointerUp(at: CGPoint(x: frame.minX + frame.size.width * 0.9, y: y))
        #expect(value("gain") == .double(0.9))
        #expect(model.history.undoStack.count == before + 1)
        try model.undo()
        #expect(value("gain") == nil)  // back to the default of 0.5
    }

    @Test func aSliderJumpsToWhereItIsPressed() throws {
        let frame = try widget("gain").frame
        click(CGPoint(x: frame.minX + frame.size.width * 0.3, y: frame.midY))
        #expect(value("gain") == .double(0.3))
    }

    @Test func draggingBeyondTheEndsStaysWithinTheRange() throws {
        let frame = try widget("gain").frame
        controller.pointerDown(at: CGPoint(x: frame.midX, y: frame.midY), kind: .mouse)
        controller.pointerMoved(to: CGPoint(x: frame.maxX + 500, y: frame.midY))
        controller.pointerUp(at: CGPoint(x: frame.maxX + 500, y: frame.midY))
        #expect(value("gain") == .double(1))
    }

    @Test func cancellingASliderDragRestoresTheValue() throws {
        let frame = try widget("gain").frame
        controller.pointerDown(at: CGPoint(x: frame.minX + frame.size.width * 0.8, y: frame.midY), kind: .mouse)
        #expect(value("gain") == .double(0.8))
        controller.cancel()
        #expect(value("gain") == nil)
    }

    @Test func draggingANumberScrubsItAndClampsToItsMinimum() throws {
        let start = try center("count")
        controller.pointerDown(at: start, kind: .mouse)
        controller.pointerMoved(to: CGPoint(x: start.x + 16, y: start.y))
        controller.pointerUp(at: CGPoint(x: start.x + 16, y: start.y))
        #expect(value("count") == .int(5))
        controller.pointerDown(at: start, kind: .mouse)
        controller.pointerMoved(to: CGPoint(x: start.x - 400, y: start.y))
        controller.pointerUp(at: CGPoint(x: start.x - 400, y: start.y))
        #expect(value("count") == .int(0))
    }

    @Test func clickingANumberOpensATextEditorWithItsValue() throws {
        click(try center("count"))
        #expect(controller.editor?.spec.id == "count")
        #expect(controller.editor?.draftText == "3")
        #expect(controller.editorFrame == (try widget("count")).frame)
        controller.updateDraft("12")
        controller.closeEditor(commit: true)
        #expect(controller.editor == nil)
        #expect(value("count") == .int(12))
    }

    @Test func aNumberThatDoesNotParseIsDropped() throws {
        click(try center("count"))
        controller.updateDraft("twelve")
        controller.closeEditor(commit: true)
        #expect(value("count") == nil)
    }

    @Test func escapeAbandonsTheEdit() throws {
        click(try center("label"))
        controller.updateDraft("changed")
        #expect(controller.perform(.escape))
        #expect(controller.editor == nil)
        #expect(value("label") == nil)
    }

    @Test func pressingElsewhereCommitsTheEdit() throws {
        click(try center("label"))
        controller.updateDraft("changed")
        controller.pointerDown(at: CGPoint(x: 900, y: 900), kind: .mouse)
        #expect(controller.editor == nil)
        #expect(value("label") == .string("changed"))
    }

    @Test func clickingAChoiceOpensItsListAndCommitting() throws {
        click(try center("mode"))
        #expect(controller.editor?.spec.id == "mode")
        controller.commitEditor(.string("b"))
        #expect(value("mode") == .string("b"))
        #expect(controller.editor == nil)
    }

    @Test func aChoiceOutsideTheListIsRefused() throws {
        click(try center("mode"))
        controller.commitEditor(.string("zzz"))
        #expect(value("mode") == nil)
    }

    @Test func colorChangesApplyLiveAsOneStep() throws {
        click(try center("tint"))
        let before = model.history.undoStack.count
        controller.applyLive(.color(RGBAColor(red: 0, green: 1, blue: 0)))
        controller.applyLive(.color(RGBAColor(red: 0, green: 0, blue: 1)))
        #expect(controller.editor != nil)
        controller.closeEditor(commit: false)
        #expect(value("tint") == .color(RGBAColor(red: 0, green: 0, blue: 1)))
        #expect(model.history.undoStack.count == before + 1)
    }

    @Test func multilineTextEditsThroughTheEditor() throws {
        click(try center("notes"))
        #expect(controller.editor?.spec.kind == .multilineText)
        controller.updateDraft("line one\nline two")
        controller.closeEditor(commit: true)
        #expect(value("notes") == .string("line one\nline two"))
    }

    @Test func aButtonCallsTheActionHandler() throws {
        struct Provider: NodeWidgetProvider {
            func widgets(for node: Node, definition: NodeDefinition) -> [NodeWidgetSpec] { [.button("Go", action: "go")] }
        }
        model.widgetProvider = Provider()
        var received: (NodeID, String)?
        model.onWidgetAction = { received = ($0, $1) }
        click(try center("button.go"))
        #expect(received?.0 == node.id && received?.1 == "go")
    }

    @Test func widgetsAreNotHitWhenZoomedFarOut() throws {
        let frame = try widget("flag").frame
        model.camera = GraphCamera(origin: .zero, zoom: 0.4)
        let screen = model.camera.screenPoint(for: GraphPoint(x: frame.midX, y: frame.midY))
        click(screen)
        #expect(value("flag") == nil)
        #expect(model.selection.nodes == [node.id])
    }

    @Test func aRefusedValueChangesNothing() throws {
        // Typing a number below the minimum is limited to it rather than refused.
        click(try center("count"))
        controller.updateDraft("-5")
        controller.closeEditor(commit: true)
        #expect(value("count") == .int(0))
    }
}
