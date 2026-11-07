import NodeGraphCore
import SwiftUI

/// The node graph editor's canvas: grid, groups, links and nodes drawn with SwiftUI `Canvas`,
/// culled to what is on screen, with drag and pinch input routed to a
/// ``GraphInteractionController``.
public struct GraphCanvasView: View {
    private let model: GraphEditorModel
    @State private var controller: GraphInteractionController
    @State private var hasFramed = false
    @State private var isPressing = false
    @State private var viewSize = CGSize.zero
    #if !canImport(UIKit)
    @FocusState private var isFocused: Bool
    #endif
    @Environment(\.undoManager) private var undoManager

    public init(model: GraphEditorModel) {
        self.model = model
        _controller = State(initialValue: GraphInteractionController(model: model))
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
            model.viewSize = size
            // Show the whole graph the first time the view has a real size.
            if !hasFramed, size.width > 0, size.height > 0 {
                hasFramed = true
                model.zoomToFit()
            }
        }
        #if canImport(AppKit)
        .background(MacInputMonitor(controller: controller))
        #endif
        #if !canImport(UIKit)
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onKeyPress(phases: [.down, .repeat]) { press in handle(press) }
        .onContinuousHover { phase in
            switch phase {
            case .active(let location): controller.hover(at: location)
            case .ended: controller.hover(at: nil)
            }
        }
        #endif
        .onAppear { model.undoManager = undoManager }
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
    }

    #if !canImport(UIKit)
    /// Maps a key press to a canvas command and runs it. Keys the canvas does not use are
    /// ignored so the rest of the app still sees them.
    private func handle(_ press: KeyPress) -> KeyPress.Result {
        let key: CanvasKey
        switch press.key {
        case .delete, .deleteForward: key = .delete
        case .escape: key = .escape
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
