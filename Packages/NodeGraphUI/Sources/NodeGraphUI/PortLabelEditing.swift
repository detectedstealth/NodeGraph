import Foundation
import NodeGraphCore

/// Giving a node's ports names that make sense where it is used. Only the shown name changes; the
/// port keeps its id, so links and execution are unaffected. Every edit is an undoable command.
extension GraphEditorModel {
    /// Shows `label` for the port instead of the node type's name, or the type's name again when
    /// `label` is nil or blank. Returns false, changing nothing, if the port does not exist, the
    /// label is what it already is, or the canvas cannot be edited.
    @discardableResult
    public func setPortLabel(_ address: PortAddress, to label: String?, coalescing: Bool = false) -> Bool {
        guard let node = graph.nodes[address.node] else { return false }
        var unlabeled = node
        unlabeled.portLabels = [:]
        guard let declared = editor.nodes.definition(for: unlabeled)?.port(address.port, direction: address.direction),
              editor.nodes.definition(for: node)?.port(address.port, direction: address.direction) != nil
        else { return false }
        // Blank, or the type's own name, means no label of the node's own.
        let cleaned = label?.trimmingCharacters(in: .whitespacesAndNewlines)
        let new = cleaned?.isEmpty == false && cleaned != declared.displayName ? cleaned : nil
        guard node.portLabels[Node.portLabelKey(address.port, direction: address.direction)] != new else { return false }
        let command = GraphCommand.setPortLabel(
            node: address.node, port: address.port, direction: address.direction, label: new)
        return (try? perform(command, name: "Rename Port", coalescing: coalescing)) != nil
    }
}
