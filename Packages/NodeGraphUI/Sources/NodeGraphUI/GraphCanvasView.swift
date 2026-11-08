import NodeGraphCore
import SwiftUI

/// The node graph editor's canvas: grid, groups, links and nodes drawn with SwiftUI `Canvas`,
/// culled to what is on screen, with drag and pinch input routed to a
/// ``GraphInteractionController``.
public struct GraphCanvasView: View {
    private let model: GraphEditorModel
    @State private var controller: GraphInteractionController
    @State private var isPressing = false
    @State private var viewSize = CGSize.zero
    #if !canImport(UIKit)
    @FocusState private var isFocused: Bool
    #endif
    @Environment(\.undoManager) private var undoManager
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @Environment(\.exposesCanvasElements) private var exposesCanvasElements

    public init(model: GraphEditorModel) {
        self.init(controller: GraphInteractionController(model: model))
    }

    /// Use this form to keep the controller, for example to open the add-node search from a
    /// toolbar button with ``GraphInteractionController/beginAddNode(at:from:)``.
    public init(controller: GraphInteractionController) {
        self.model = controller.model
        _controller = State(initialValue: controller)
    }

    public var body: some View {
        Canvas(opaque: true, rendersAsynchronously: false) { context, size in
            var context = context
            MainActor.assumeIsolated {
                GraphCanvasRenderer(model: model, controller: controller).draw(&context, size: size)
            }
        }
        .onGeometryChange(for: CGSize.self, of: \.size) { size in
            viewSize = size
            model.viewSizeChanged(to: size)
        }
        #if canImport(AppKit)
        .background(MacInputMonitor(controller: controller))
        #endif
        #if !canImport(UIKit)
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onKeyPress(phases: [.down, .repeat]) { press in handle(press) }
        #if os(macOS)
        // On a Mac the Delete key reaches a view as the delete command (the responder chain's
        // deleteBackward:), not always as a key press, so Delete is also handled here. This is
        // what Edit > Delete runs, too.
        .onDeleteCommand { controller.perform(.deleteSelection) }
        #endif
        .onContinuousHover { phase in
            switch phase {
            case .active(let location): controller.hover(at: location)
            case .ended: controller.hover(at: nil)
            }
        }
        #endif
        .onAppear {
            model.undoManager = undoManager
            model.textScale = GraphEditorModel.textScale(for: dynamicTypeSize)
        }
        .onChange(of: dynamicTypeSize) { _, newValue in model.textScale = GraphEditorModel.textScale(for: newValue) }
        .onChange(of: undoManager) { _, newValue in model.undoManager = newValue }
        #if canImport(UIKit)
        .overlay { TouchInputOverlay(controller: controller) }
        #else
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if !isPressing {
                        isPressing = true
                        isFocused = true
                        controller.pointerDown(at: value.startLocation, modifiers: PlatformInput.modifiers)
                    }
                    controller.pointerMoved(to: value.location, modifiers: PlatformInput.modifiers)
                }
                .onEnded { value in
                    controller.pointerUp(at: value.location)
                    isPressing = false
                }
        )
        .simultaneousGesture(
            MagnifyGesture()
                .onChanged { value in
                    controller.magnify(
                        totalScale: value.magnification,
                        anchor: CGPoint(x: value.startAnchor.x * viewSize.width, y: value.startAnchor.y * viewSize.height))
                }
                .onEnded { _ in controller.endMagnify() }
        )
        #endif
        .accessibilityLabel("Node graph")
        .accessibilityChildren {
            // The canvas is one drawn view; these stand in for its nodes, links and groups. Only
            // built while VoiceOver runs (or UI tests ask), since they are rebuilt whenever the
            // graph or view moves.
            if voiceOverEnabled || exposesCanvasElements {
                AccessibilityElementsView(controller: controller)
            }
        }
        // Last, so the editor sits above the touch layer and the drag gesture.
        .overlay { WidgetEditorOverlay(controller: controller) }
        .overlay { PortLabelEditorOverlay(controller: controller) }
        .overlay { AddNodeOverlay(controller: controller) }
        .overlay { CreateSubgraphOverlay(model: model) }
        .overlay { ConnectionChooserOverlay(model: model) }
    }

    #if !canImport(UIKit)
    /// Maps a key press to a canvas command and runs it. Keys the canvas does not use are
    /// ignored so the rest of the app still sees them.
    private func handle(_ press: KeyPress) -> KeyPress.Result {
        let key: CanvasKey
        switch press.key {
        case .delete, .deleteForward: key = .delete
        case .escape: key = .escape
        case .return: key = .return
        case .leftArrow: key = .left
        case .rightArrow: key = .right
        case .upArrow: key = .up
        case .downArrow: key = .down
        default:
            guard let character = press.characters.first else { return .ignored }
            key = .character(character)
        }
        var modifiers: InputModifiers = []
        if press.modifiers.contains(.shift) { modifiers.insert(.shift) }
        if press.modifiers.contains(.command) { modifiers.insert(.command) }
        if press.modifiers.contains(.option) { modifiers.insert(.option) }
        if press.modifiers.contains(.control) { modifiers.insert(.control) }
        guard let command = CanvasKeyMap.command(for: key, modifiers: modifiers) else { return .ignored }
        return controller.perform(command) ? .handled : .ignored
    }
    #endif
}
