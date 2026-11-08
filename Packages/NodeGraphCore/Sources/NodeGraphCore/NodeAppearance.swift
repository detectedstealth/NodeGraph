/// The outline of a node.
public enum NodeShape: String, Hashable, Sendable, Codable, CaseIterable {
    /// Square corners.
    case box
    /// Rounded corners. The default look.
    case round
    /// Rounded at the top leading and bottom trailing corners only, like a card with a dog-ear.
    case card
}

/// How a node's title bar is shown.
public enum NodeTitleMode: String, Hashable, Sendable, Codable, CaseIterable {
    /// A filled bar with the title.
    case normal
    /// No bar and no title. The space is kept, so ports sit where they would anyway.
    case hidden
    /// The title, with no fill behind it.
    case transparent
    /// Shown as `normal` while the pointer is over the node or it is selected, as `hidden` otherwise.
    case autohide
}

/// The mark drawn for a port.
public enum PortShape: String, Hashable, Sendable, Codable, CaseIterable {
    case circle
    case square
    case diamond
    /// A triangle pointing in the direction of flow (right).
    case arrow
    /// A small grid of squares, for collections of values.
    case grid
}
