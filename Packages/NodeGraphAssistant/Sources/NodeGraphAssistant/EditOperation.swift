import NodeGraphCore

/// One small edit to existing nodes, written with aliases so a model can ask for it.
///
/// Flat on purpose (one `op` and the fields it needs), because that is easy to describe to a
/// model as a schema. ``AssistantWorkspace/proposeEdit(_:title:)`` turns a list of these into a
/// ``PendingChange``. Aliases always mean the nodes of the document as it is now, even after an
/// earlier operation in the same list removed a node.
public struct EditOperation: Hashable, Sendable, Codable {
    public enum Kind: String, Hashable, Sendable, Codable, CaseIterable {
        /// `node`, `property`, and `value` (null or absent goes back to the default).
        case setProperty
        /// `node` and `value`, a string (null or empty goes back to the type's name).
        case setTitle
        /// `node` and `value`, one of always, never, muted, bypassed, onTrigger.
        case setMode
        /// `from` (an output, like `n1.out`) and `to` (an input, like `n2.a`). Replaces a link
        /// already into `to`.
        case connect
        /// `from` and `to`, naming an existing link.
        case disconnect
        /// `node`. Its links go with it.
        case removeNode
    }

    public var op: Kind
    public var node: String?
    public var property: String?
    public var value: JSONValue?
    public var from: String?
    public var to: String?

    public init(
        _ op: Kind, node: String? = nil, property: String? = nil, value: JSONValue? = nil,
        from: String? = nil, to: String? = nil
    ) {
        self.op = op
        self.node = node
        self.property = property
        self.value = value
        self.from = from
        self.to = to
    }

    public static func setProperty(_ node: String, _ property: String, _ value: JSONValue?) -> EditOperation {
        EditOperation(.setProperty, node: node, property: property, value: value)
    }
    public static func setTitle(_ node: String, _ title: String?) -> EditOperation {
        EditOperation(.setTitle, node: node, value: title.map(JSONValue.string))
    }
    public static func setMode(_ node: String, _ mode: NodeMode) -> EditOperation {
        EditOperation(.setMode, node: node, value: .string(mode.rawValue))
    }
    public static func connect(_ from: String, _ to: String) -> EditOperation {
        EditOperation(.connect, from: from, to: to)
    }
    public static func disconnect(_ from: String, _ to: String) -> EditOperation {
        EditOperation(.disconnect, from: from, to: to)
    }
    public static func removeNode(_ node: String) -> EditOperation {
        EditOperation(.removeNode, node: node)
    }
}
