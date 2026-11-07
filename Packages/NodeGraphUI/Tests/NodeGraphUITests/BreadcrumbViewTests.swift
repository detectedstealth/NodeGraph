#if canImport(AppKit)
import AppKit
import SwiftUI
import Testing
import NodeGraphCore
@testable import NodeGraphUI

/// Hosts the breadcrumb and goes in and out of a subgraph, so that a level that disappears while
/// SwiftUI is still updating the old one cannot crash it.
@MainActor
@Suite struct BreadcrumbViewTests {
    @Test func leavingASubgraphWhileTheBreadcrumbIsShownDoesNotCrash() async throws {
        let model = TestKit.makeModel()
        let controller = GraphInteractionController(model: model)
        let node = Node(typeID: TestKit.sink)
        try model.perform(.addNode(node: node))
        let conversion = try model.editor.convertToSubgraphCommand(nodes: [node.id], name: "Inner")
        try model.perform(conversion.command)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: GraphBreadcrumbView(controller: controller))
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 400, height: 100)

        for _ in 0..<5 {
            controller.enterSubgraph(of: conversion.instance)
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
            controller.navigate(toDepth: 0)
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(model.scopePath.isEmpty)
    }
}
#endif
