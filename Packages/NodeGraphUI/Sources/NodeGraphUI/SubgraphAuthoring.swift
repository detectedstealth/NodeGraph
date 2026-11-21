#if !os(tvOS) && !os(watchOS)
import Foundation
import NodeGraphCore

/// An inner property the user may expose on a new subgraph.
public struct PromotableProperty: Hashable, Sendable, Identifiable {
    public var id: String { "\(target.node).\(target.property)" }
    public var target: PropertyTarget
    /// The node's title (or its type's name), for telling same-named properties apart.
    public var nodeTitle: String
    public var title: String
    /// The property's value now, which becomes the exposed property's default.
    public var valueText: String
}

/// The "Create Subgraph" form: what is being wrapped, what could be exposed, and what went wrong
/// on the last try.
public struct CreateSubgraphRequest: Hashable, Sendable {
    public var nodes: [NodeID]
    public var suggestedName: String
    public var candidates: [PromotableProperty]
    /// Why the last attempt was refused, in words for the form to show.
    public var error: String?
}

extension GraphEditError {
    /// What to tell a person about a refused subgraph edit.
    var userMessage: String {
        switch self {
        case .invalidSubgraph(let problems): problems.joined(separator: "\n")
        case .nodeNotFound, .groupNotFound: "Something selected no longer exists."
        case .recursiveSubgraph: "That would make a subgraph contain itself."
        case .subgraphNotFound: "That subgraph no longer exists."
        default: "The subgraph could not be created."
        }
    }
}

extension GraphEditorModel {
    /// Opens the Create Subgraph form for the selected nodes. Returns false if none are selected.
    @discardableResult
    public func beginCreateSubgraph() -> Bool {
        guard isEditable else { return false }
        let nodes = graph.nodes.values.filter { selection.nodes.contains($0.id) }
        guard !nodes.isEmpty else { return false }
        var candidates: [PromotableProperty] = []
        for node in nodes {
            guard let definition = definition(of: node) else { continue }
            let nodeTitle = node.title ?? definition.displayName
            for property in definition.properties {
                let value = node.properties[property.id] ?? property.defaultValue
                candidates.append(PromotableProperty(
                    target: PropertyTarget(node: node.id, property: property.id), nodeTitle: nodeTitle,
                    title: property.displayName, valueText: NodeWidgetSpec(property).kind.display(value)))
            }
        }
        createSubgraphRequest = CreateSubgraphRequest(
            nodes: nodes.map(\.id), suggestedName: uniqueSubgraphName("Subgraph"), candidates: candidates)
        return true
    }

    public func cancelCreateSubgraph() {
        if createSubgraphRequest != nil { createSubgraphRequest = nil }
    }

    /// Wraps the form's nodes in a new subgraph named `name`, exposing the chosen properties, as
    /// one undoable step, and selects the instance that replaces them. With `open`, goes inside it.
    /// If the rules refuse, the form stays open with the reason in its `error`.
    @discardableResult
    public func createSubgraph(name: String, promoting: [PropertyTarget] = [], open: Bool = false) -> Bool {
        guard var request = createSubgraphRequest else { return false }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            request.error = "Give the subgraph a name."
            createSubgraphRequest = request
            return false
        }
        do {
            let conversion = try editor.convertToSubgraphCommand(
                nodes: request.nodes, name: trimmed, promoting: promoting, in: currentScope)
            try perform(conversion.command, name: "Create Subgraph", isScoped: true)
            createSubgraphRequest = nil
            selection = GraphSelection(nodes: [conversion.instance])
            if open { enterSubgraph(of: conversion.instance) }
            return true
        } catch let error as GraphEditError {
            request.error = error.userMessage
        } catch {
            request.error = "The subgraph could not be created."
        }
        createSubgraphRequest = request
        return false
    }

    /// Replaces an instance of a subgraph with the nodes inside it, keeping their layout, their
    /// links to the outside, and the property values the instance had. One undo step. The
    /// definition stays, for any other instances. Returns whether it unpacked.
    @discardableResult
    public func unpackSubgraph(instance: NodeID) -> Bool {
        guard subgraph(of: instance) != nil,
              let unpacking = try? editor.unpackCommand(instance: instance, in: currentScope),
              (try? perform(unpacking.command, name: "Unpack Subgraph", isScoped: true)) != nil else { return false }
        selection = GraphSelection(nodes: Set(unpacking.nodes.values))
        return true
    }

    /// `base`, or `base 2`, `base 3`, ... so that no subgraph shares its name.
    func uniqueSubgraphName(_ base: String) -> String {
        let taken = Set(editor.subgraphs.values.map(\.interface.name))
        guard taken.contains(base) else { return base }
        var number = 2
        while taken.contains("\(base) \(number)") { number += 1 }
        return "\(base) \(number)"
    }
}
#endif
