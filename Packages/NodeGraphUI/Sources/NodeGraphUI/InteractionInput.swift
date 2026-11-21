#if !os(tvOS) && !os(watchOS)
import CoreGraphics
import NodeGraphCore

/// Keys held while a pointer is pressed. A platform layer fills this in; the interaction logic
/// never reads the keyboard itself.
public struct InputModifiers: OptionSet, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let shift = InputModifiers(rawValue: 1 << 0)
    /// Command on macOS and iPadOS keyboards, Control elsewhere.
    public static let command = InputModifiers(rawValue: 1 << 1)
    public static let option = InputModifiers(rawValue: 1 << 2)
    public static let control = InputModifiers(rawValue: 1 << 3)

    /// Whether a click adds to the selection instead of replacing it.
    public var extendsSelection: Bool { contains(.shift) || contains(.command) }
}

/// What is pressing. Decides what a drag on empty canvas means.
public enum PointerKind: Hashable, Sendable {
    case mouse
    case touch
    case pencil

    /// The kind a platform's primary pointer is until the input layer says otherwise.
    public static var platformDefault: PointerKind {
        #if os(macOS)
        .mouse
        #else
        .touch
        #endif
    }
}

/// A link being dragged out of a port, or moved to a new one, as the canvas should show it.
public struct ConnectionDraft: Hashable, Sendable {
    /// The port the drag started from. Fixed for the whole drag.
    public var anchor: PortAddress
    public var anchorPosition: GraphPoint
    /// Where the pointer is, in graph space.
    public var pointer: GraphPoint
    /// The port under the pointer if dropping there would connect.
    public var candidate: PortAddress?
    /// The port under the pointer if dropping there would be refused.
    public var rejected: PortAddress?
}
#endif
