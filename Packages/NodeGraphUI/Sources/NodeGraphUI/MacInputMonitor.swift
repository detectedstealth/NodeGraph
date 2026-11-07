#if canImport(AppKit)
import AppKit
import SwiftUI

/// Gives the canvas the mouse input SwiftUI has no view-level API for: scroll wheels and
/// trackpad scrolling, and right-clicks (which pop up a native menu).
///
/// It adds no view on top of the canvas, so clicks and drags still reach SwiftUI. Instead it
/// watches the window's events and acts on those inside this view's bounds.
struct MacInputMonitor: NSViewRepresentable {
    let controller: GraphInteractionController

    func makeNSView(context: Context) -> NSView {
        let view = PassthroughView()
        context.coordinator.attach(to: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.controller = controller
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.detach()
    }

    func makeCoordinator() -> Coordinator { Coordinator(controller: controller) }

    /// Invisible to hit testing, so it never takes a click from the canvas below.
    private final class PassthroughView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    @MainActor
    final class Coordinator: NSObject {
        var controller: GraphInteractionController
        private weak var view: NSView?
        private var monitor: Any?

        init(controller: GraphInteractionController) {
            self.controller = controller
        }

        func attach(to view: NSView) {
            self.view = view
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .rightMouseDown]) { [weak self] event in
                // Local monitors run on the main thread.
                let swallowed = MainActor.assumeIsolated { self?.handle(event) ?? false }
                return swallowed ? nil : event
            }
        }

        func detach() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        /// Returns whether the event was used and should not go any further.
        private func handle(_ event: NSEvent) -> Bool {
            guard let view, event.window === view.window else { return false }
            let local = view.convert(event.locationInWindow, from: nil)
            guard view.bounds.contains(local) else { return false }
            // A panel over the canvas (the add-node list, a choice list) scrolls itself; the
            // canvas must not take its scrolling, or right-click, away.
            if event.type == .scrollWheel, Self.isOverScrollView(in: view.window, at: event.locationInWindow) { return false }
            if event.type == .rightMouseDown, controller.addNodeRequest != nil || controller.editor != nil { return false }
            // The canvas draws with a top-left origin; AppKit's views are bottom-left.
            let point = CGPoint(x: local.x, y: view.isFlipped ? local.y : view.bounds.height - local.y)

            switch event.type {
            case .scrollWheel:
                controller.scroll(
                    by: CGSize(width: event.scrollingDeltaX, height: event.scrollingDeltaY),
                    at: point, modifiers: PlatformInput.modifiers(from: event.modifierFlags),
                    isPrecise: event.hasPreciseScrollingDeltas)
                return true
            case .rightMouseDown:
                showMenu(at: point, event: event, in: view)
                return true
            default:
                return false
            }
        }

        /// Whether the topmost view at `location` (window coordinates) is inside a scroll view.
        /// SwiftUI's `ScrollView` is an `NSScrollView` on macOS, so this finds a list under the
        /// pointer without knowing which panel it belongs to.
        static func isOverScrollView(in window: NSWindow?, at location: NSPoint) -> Bool {
            var current = window?.contentView?.hitTest(location)
            while let candidate = current {
                if candidate is NSScrollView { return true }
                current = candidate.superview
            }
            return false
        }

        private func showMenu(at point: CGPoint, event: NSEvent, in view: NSView) {
            let items = controller.contextMenu(at: point)
            let menu = NSMenu()
            menu.autoenablesItems = false
            populate(menu, with: items)
            NSMenu.popUpContextMenu(menu, with: event, for: view)
        }

        private func populate(_ menu: NSMenu, with items: [CanvasMenuItem]) {
            for item in items {
                switch item.kind {
                case .separator:
                    menu.addItem(.separator())
                case .command(let command):
                    let entry = ActionMenuItem(title: item.title) { [weak self] in self?.controller.perform(command) }
                    entry.isEnabled = item.isEnabled
                    entry.state = item.isChecked ? .on : .off
                    menu.addItem(entry)
                case .submenu(let children):
                    let entry = NSMenuItem(title: item.title, action: nil, keyEquivalent: "")
                    let submenu = NSMenu(title: item.title)
                    submenu.autoenablesItems = false
                    populate(submenu, with: children)
                    entry.submenu = submenu
                    entry.isEnabled = item.isEnabled
                    menu.addItem(entry)
                }
            }
        }
    }

    /// A menu item that runs a closure.
    private final class ActionMenuItem: NSMenuItem {
        private let handler: () -> Void

        init(title: String, handler: @escaping () -> Void) {
            self.handler = handler
            super.init(title: title, action: #selector(run), keyEquivalent: "")
            target = self
        }

        @available(*, unavailable) required init(coder: NSCoder) { fatalError() }

        @objc private func run() { handler() }
    }
}
#endif
