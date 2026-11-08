/// A named, typed value a graph exposes to its nodes, such as a gain, a duration or a file name.
///
/// Variables are declared on the root graph with commands, so edits are undoable and part of the
/// change log. Nodes read them by name through ``NodeContext/variable(_:)``. A run can replace a
/// value without editing the graph: see ``GraphRunner/setVariable(_:to:)``. Nothing in a graph
/// writes a variable during a run.
public struct GraphVariable: Hashable, Sendable, Codable {
    /// The name nodes use. Unique within the graph, and not empty.
    public var name: String
    /// What kind of value it holds, for the editor to offer the right control and for packs to
    /// check. Core attaches no meaning to it.
    public var type: PortType
    /// The value a run uses unless it is overridden.
    public var value: GraphValue
    /// Free text for people: what the variable is for.
    public var summary: String

    public init(name: String, type: PortType = .any, value: GraphValue, summary: String = "") {
        self.name = name
        self.type = type
        self.value = value
        self.summary = summary
    }

    /// Whether `name` may be used: it has something other than whitespace in it.
    public static func isValidName(_ name: String) -> Bool {
        !name.allSatisfy(\.isWhitespace)
    }
}
