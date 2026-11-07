#if canImport(UIKit)
import NodeGraphCore
import OSLog
import SwiftUI
import UIKit

private let inputLog = Logger(subsystem: "NodeGraphUI", category: "input")

/// Gives the canvas its touch, pencil and pointer input on iPadOS.
///
/// A transparent view laid over the canvas. One recognizer reads raw touches so it can tell one
/// finger (select, move, link, pan) from two (pan and pinch together) and feed the interaction
/// controller; the rest cover what raw touches do not: a trackpad's scroll and pinch, pointer
/// hover, and a long press or secondary click that opens the context menu.
struct TouchInputOverlay: UIViewRepresentable {
    let controller: GraphInteractionController

    func makeUIView(context: Context) -> TouchInputView {
        let view = TouchInputView()
        view.controller = controller
        return view
    }

    func updateUIView(_ view: TouchInputView, context: Context) {
        view.controller = controller
    }
}

final class TouchInputView: UIView, UIGestureRecognizerDelegate, UIContextMenuInteractionDelegate {
    var controller: GraphInteractionController?

    private let touches = TouchRecognizer()
    private let scroll = UIPanGestureRecognizer()
    private let pinch = UIPinchGestureRecognizer()
    private let hover = UIHoverGestureRecognizer()
    private var lastScrollTranslation = CGPoint.zero
    /// Whether the current trackpad pinch has moved far enough to count as a pinch.
    private var pinchEngaged = false
    /// Where the menu being shown was asked for.
    private var menuAnchor = CGPoint.zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isMultipleTouchEnabled = true

        touches.owner = self
        touches.delegate = self
        addGestureRecognizer(touches)

        // Trackpad and mouse-wheel scrolling arrive as a pan with no touches.
        scroll.allowedTouchTypes = []
        scroll.allowedScrollTypesMask = .all
        scroll.addTarget(self, action: #selector(handleScroll))
        scroll.delegate = self
        addGestureRecognizer(scroll)

        pinch.addTarget(self, action: #selector(handlePinch))
        pinch.delegate = self
        addGestureRecognizer(pinch)

        hover.addTarget(self, action: #selector(handleHover))
        addGestureRecognizer(hover)

        addInteraction(UIContextMenuInteraction(delegate: self))
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    // MARK: Keyboard

    // Keys are handled here rather than through SwiftUI focus. With a hardware keyboard attached
    // the focus system turns on and moves focus around the canvas, which swallowed touches.
    override var canBecomeFirstResponder: Bool { true }

    /// The canvas takes hardware key presses, not typing. An empty input view stops iPadOS from
    /// raising the software keyboard while this view is the first responder, which it did
    /// whenever a context menu opened and then covered half the canvas.
    private let noKeyboard = UIView(frame: .zero)
    override var inputView: UIView? { noKeyboard }
    override var inputAccessoryView: UIView? { nil }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { becomeFirstResponder() }
    }

    /// Shortcuts the system would otherwise claim. Registering them also lists them in the
    /// shortcut overlay that appears when Command is held.
    override var keyCommands: [UIKeyCommand]? {
        func command(
            _ title: String, _ input: String, _ id: String, flags: UIKeyModifierFlags = .command
        ) -> UIKeyCommand {
            let command = UIKeyCommand(
                title: title, action: #selector(handleKeyCommand(_:)), input: input,
                modifierFlags: flags, propertyList: id)
            command.wantsPriorityOverSystemBehavior = true
            return command
        }
        return [
            command("Select All", "a", "selectAll"),
            command("Actual Size", "0", "resetZoom"),
            command("Zoom In", "=", "zoomIn"),
            command("Zoom Out", "-", "zoomOut"),
            command("Leave Subgraph", "[", "leaveSubgraph"),
            command("Duplicate", "d", "duplicate"),
            command("Create Subgraph", "g", "createSubgraph"),
            command("Unpack Subgraph", "g", "unpackSubgraph", flags: [.command, .shift]),
        ]
    }

    // Copy, cut and paste are the standard responder actions, so Command-C and friends, the
    // edit menu, and the system's three-finger pinch and spread gestures all reach them.
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        guard let controller else { return false }
        switch action {
        case #selector(copy(_:)), #selector(cut(_:)): return !controller.model.selection.isEmpty
        case #selector(paste(_:)): return controller.clipboard.mayHaveFragment
        default: return super.canPerformAction(action, withSender: sender)
        }
    }

    override func copy(_ sender: Any?) { controller?.perform(.copy) }
    override func cut(_ sender: Any?) { controller?.perform(.cut) }
    override func paste(_ sender: Any?) { controller?.perform(.paste(at: nil)) }

    @objc private func handleKeyCommand(_ sender: UIKeyCommand) {
        let command: CanvasCommand? = switch sender.propertyList as? String {
        case "selectAll": .selectAll
        case "resetZoom": .resetZoom
        case "zoomIn": .zoomIn
        case "zoomOut": .zoomOut
        case "leaveSubgraph": .leaveSubgraph
        case "duplicate": .duplicate
        case "createSubgraph": .createSubgraph
        case "unpackSubgraph": .unpackSubgraph
        default: nil
        }
        if let command { controller?.perform(command) }
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var unhandled = Set<UIPress>()
        for press in presses {
            guard let key = press.key else {
                unhandled.insert(press)
                continue
            }
            let modifiers = PlatformInput.modifiers(from: key.modifierFlags)
            let canvasKey: CanvasKey?
            switch key.keyCode {
            case .keyboardDeleteOrBackspace, .keyboardDeleteForward: canvasKey = .delete
            case .keyboardEscape: canvasKey = .escape
            case .keyboardReturnOrEnter: canvasKey = .return
            case .keyboardLeftArrow: canvasKey = .left
            case .keyboardRightArrow: canvasKey = .right
            case .keyboardUpArrow: canvasKey = .up
            case .keyboardDownArrow: canvasKey = .down
            default: canvasKey = key.charactersIgnoringModifiers.first.map(CanvasKey.character)
            }
            // Command shortcuts come through `keyCommands`; skip them here so they run once.
            if let canvasKey, !modifiers.contains(.command),
               let command = CanvasKeyMap.command(for: canvasKey, modifiers: modifiers),
               controller?.perform(command) == true {
                continue
            }
            unhandled.insert(press)
        }
        if !unhandled.isEmpty { super.pressesBegan(unhandled, with: event) }
    }

    // MARK: Scroll, pinch, hover

    @objc private func handleScroll(_ recognizer: UIPanGestureRecognizer) {
        guard let controller else { return }
        if recognizer.state == .began { inputLog.debug("scroll began") }
        let translation = recognizer.translation(in: self)
        defer { lastScrollTranslation = recognizer.state == .changed ? translation : .zero }
        guard recognizer.state == .changed else { return }
        let delta = CGSize(width: translation.x - lastScrollTranslation.x, height: translation.y - lastScrollTranslation.y)
        controller.scroll(
            by: delta, at: recognizer.location(in: self),
            modifiers: PlatformInput.modifiers(from: recognizer.modifierFlags), isPrecise: true)
    }

    @objc private func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
        guard let controller, !controller.isMultiTouch else { return }
        switch recognizer.state {
        case .began, .changed:
            // A trackpad that is scrolling or being clicked can report a tiny pinch. Only a
            // deliberate one counts, and never while a button is down or a scroll is running.
            guard !controller.isPointerDown, scroll.state != .began, scroll.state != .changed else { return }
            if !pinchEngaged {
                guard abs(recognizer.scale - 1) >= Self.pinchThreshold else { return }
                pinchEngaged = true
                inputLog.debug("pinch engaged at scale \(recognizer.scale)")
            }
            controller.magnify(totalScale: recognizer.scale, anchor: recognizer.location(in: self))
        default:
            if pinchEngaged { controller.endMagnify() }
            pinchEngaged = false
        }
    }

    /// How far from 1 a trackpad pinch's scale must get before it is acted on.
    private static let pinchThreshold = 0.03

    @objc private func handleHover(_ recognizer: UIHoverGestureRecognizer) {
        switch recognizer.state {
        case .began, .changed: controller?.hover(at: recognizer.location(in: self))
        default: controller?.hover(at: nil)
        }
    }

    // MARK: Context menu

    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let controller else { return nil }
        menuAnchor = location
        // A long press is a finger; a secondary click or a pencil needs the precise targets.
        let kind: PointerKind = touches.lastKind ?? .touch
        let items = controller.contextMenu(at: location, kind: kind)
        let menu = makeMenu(items, controller: controller)
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in menu }
    }

    // The menu points at the preview it is given, and by default that is this whole view, so it
    // would open at the edge of the screen. A preview clipped to a small patch around the press
    // makes the menu open beside the finger or pointer.
    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction, previewForHighlightingMenuWithConfiguration configuration: UIContextMenuConfiguration
    ) -> UITargetedPreview? {
        anchoredPreview()
    }

    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction, previewForDismissingMenuWithConfiguration configuration: UIContextMenuConfiguration
    ) -> UITargetedPreview? {
        anchoredPreview()
    }

    private func anchoredPreview() -> UITargetedPreview {
        let patch = CGRect(x: menuAnchor.x - 20, y: menuAnchor.y - 20, width: 40, height: 40)
        let parameters = UIPreviewParameters()
        parameters.backgroundColor = .clear
        parameters.visiblePath = UIBezierPath(roundedRect: patch.intersection(bounds), cornerRadius: 12)
        return UITargetedPreview(view: self, parameters: parameters)
    }

    /// Turns the menu description into a `UIMenu`. Separators become inline groups.
    private func makeMenu(_ items: [CanvasMenuItem], controller: GraphInteractionController) -> UIMenu {
        var groups: [[UIMenuElement]] = [[]]
        for item in items {
            switch item.kind {
            case .separator:
                groups.append([])
            case .command(let command):
                let action = UIAction(
                    title: item.title, attributes: item.isEnabled ? [] : .disabled,
                    state: item.isChecked ? .on : .off
                ) { [weak controller] _ in controller?.perform(command) }
                groups[groups.count - 1].append(action)
            case .submenu(let children):
                let submenu = makeMenu(children, controller: controller)
                let titled = UIMenu(title: item.title, children: submenu.children)
                groups[groups.count - 1].append(titled)
            }
        }
        let nonEmpty = groups.filter { !$0.isEmpty }
        if nonEmpty.count == 1 { return UIMenu(children: nonEmpty[0]) }
        return UIMenu(children: nonEmpty.map { UIMenu(options: .displayInline, children: $0) })
    }

    // MARK: Delegate

    func gestureRecognizer(
        _ recognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        true
    }

    func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        // A finger pinch is handled by the touch recognizer; the pinch recognizer is only for
        // the trackpad, whose pinches carry no touches.
        recognizer !== pinch || touch.type != .direct
    }
}

/// Reads raw touches. One touch drives the pointer; a second turns it into a two-finger camera
/// gesture until every finger is up.
final class TouchRecognizer: UIGestureRecognizer {
    weak var owner: TouchInputView?
    /// The kind of the most recent first touch, so the context menu knows what pressed.
    private(set) var lastKind: PointerKind?

    private enum Mode {
        case idle
        case single(UITouch)
        case multi(first: UITouch, second: UITouch, startDistance: Double)
        /// Fingers were lifted from a two-finger gesture; wait for all to be up.
        case finished
    }

    private var mode = Mode.idle
    private var active: [UITouch] = []

    private var controller: GraphInteractionController? { owner?.controller }

    private func point(_ touch: UITouch) -> CGPoint { touch.location(in: view) }

    private func kind(of touch: UITouch) -> PointerKind {
        switch touch.type {
        case .pencil: .pencil
        case .direct: .touch
        default: .mouse
        }
    }

    private var modifiers: InputModifiers { PlatformInput.modifiers(from: modifierFlags) }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        active.append(contentsOf: touches)
        switch mode {
        case .idle:
            // Two fingers can land in the same event; that is a pinch from the start, not a
            // single touch.
            let fingers = touches.filter { $0.type == .direct }
            if fingers.count >= 2, let first = fingers.first, let second = fingers.dropFirst().first {
                lastKind = .touch
                mode = .multi(first: first, second: second, startDistance: max(Self.distance(point(first), point(second)), 1))
                state = .began
                inputLog.debug("two fingers down together")
                owner?.becomeFirstResponder()
                controller?.multiTouchBegan(centroid: Self.midpoint(point(first), point(second)))
                return
            }
            guard let first = touches.first else { return }
            lastKind = kind(of: first)
            mode = .single(first)
            state = .began
            inputLog.debug("touch down, type \(first.type.rawValue)")
            owner?.becomeFirstResponder()
            controller?.pointerDown(at: point(first), modifiers: modifiers, kind: kind(of: first))
        case .single(let first):
            // A second finger joins a finger. Anything else (a palm beside a pencil, a click
            // while touching) is ignored.
            guard first.type == .direct, let second = touches.first(where: { $0.type == .direct }) else { return }
            let distance = Self.distance(point(first), point(second))
            mode = .multi(first: first, second: second, startDistance: max(distance, 1))
            controller?.multiTouchBegan(centroid: Self.midpoint(point(first), point(second)))
        case .multi, .finished:
            break
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        switch mode {
        case .single(let first) where touches.contains(first):
            state = .changed
            controller?.pointerMoved(to: point(first), modifiers: modifiers)
        case .multi(let first, let second, let startDistance):
            guard touches.contains(first) || touches.contains(second) else { return }
            state = .changed
            let a = point(first), b = point(second)
            controller?.multiTouchMoved(centroid: Self.midpoint(a, b), scale: Self.distance(a, b) / startDistance)
        default:
            break
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        let wasTracked = touches.contains { touch in active.contains(touch) }
        active.removeAll { touches.contains($0) }
        switch mode {
        case .single(let first) where touches.contains(first):
            controller?.pointerUp(at: point(first))
            mode = .idle
        case .multi(let first, let second, _) where touches.contains(first) || touches.contains(second):
            controller?.multiTouchEnded()
            mode = .finished
        default:
            break
        }
        if wasTracked, active.isEmpty { finish(.ended) }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        active.removeAll { touches.contains($0) }
        switch mode {
        case .single: controller?.cancel()
        case .multi: controller?.multiTouchEnded()
        default: break
        }
        mode = active.isEmpty ? .idle : .finished
        if active.isEmpty { finish(.cancelled) }
    }

    override func reset() {
        mode = .idle
        active.removeAll()
    }

    private func finish(_ final: UIGestureRecognizer.State) {
        mode = .idle
        state = final
    }

    private static func midpoint(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
        CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
    }

    private static func distance(_ a: CGPoint, _ b: CGPoint) -> Double {
        hypot(a.x - b.x, a.y - b.y)
    }
}
#endif
