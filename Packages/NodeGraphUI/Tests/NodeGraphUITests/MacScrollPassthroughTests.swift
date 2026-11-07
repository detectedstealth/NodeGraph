#if canImport(AppKit)
import AppKit
import SwiftUI
import Testing
@testable import NodeGraphUI

/// The canvas hands scrolling to any scroll view above it, such as the add-node list. That relies
/// on SwiftUI's `ScrollView` being an `NSScrollView` at the point under the pointer.
@MainActor
@Suite struct MacScrollPassthroughTests {
    private func window(showing content: some View) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: content)
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 300, height: 200)
        host.layoutSubtreeIfNeeded()
        return window
    }

    @Test func aPointOverASwiftUIScrollViewIsOverAScrollView() {
        let window = window(showing: HStack(spacing: 0) {
            Color.blue.frame(width: 100, height: 200)
            ScrollView {
                VStack { ForEach(0..<50) { Text("Row \($0)").frame(height: 30) } }
            }
            .frame(width: 200, height: 200)
        })
        // Window coordinates have their origin at the bottom left.
        #expect(MacInputMonitor.Coordinator.isOverScrollView(in: window, at: NSPoint(x: 200, y: 100)))
        #expect(!MacInputMonitor.Coordinator.isOverScrollView(in: window, at: NSPoint(x: 40, y: 100)))
    }

    @Test func noWindowMeansNotOverAScrollView() {
        #expect(!MacInputMonitor.Coordinator.isOverScrollView(in: nil, at: .zero))
    }
}
#endif
