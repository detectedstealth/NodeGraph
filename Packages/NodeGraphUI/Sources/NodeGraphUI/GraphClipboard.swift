import Foundation
import NodeGraphCore
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Where copied graph pieces go. The system clipboard in the app; a plain variable in tests.
@MainActor
public protocol GraphClipboard: AnyObject {
    /// Replaces the clipboard's contents with `fragment`.
    func write(_ fragment: GraphFragment)
    /// The fragment on the clipboard, or nil if there is none (or the text there is not one).
    func read() -> GraphFragment?
    /// Whether a paste might find something. Cheap and never asks the user for permission, so a
    /// menu can use it to enable Paste; ``read()`` is the real answer.
    var mayHaveFragment: Bool { get }
}

/// A clipboard that lives in memory, for tests and for hosts with no system clipboard.
@MainActor
public final class InMemoryClipboard: GraphClipboard {
    public private(set) var fragment: GraphFragment?

    public init() {}

    public func write(_ fragment: GraphFragment) { self.fragment = fragment }
    public func read() -> GraphFragment? { fragment }
    public var mayHaveFragment: Bool { fragment != nil }
}

/// The system clipboard. A fragment is stored under its own type for pasting between the
/// editor's windows and documents, and also as its JSON text, so it can be pasted into a text
/// editor, kept as a note, or written by a tool.
@MainActor
public final class SystemClipboard: GraphClipboard {
    private static let type = "com.nodegraph.fragment"

    public init() {}

    public func write(_ fragment: GraphFragment) {
        guard let data = try? fragment.encoded() else { return }
        let text = String(decoding: data, as: UTF8.self)
        #if canImport(AppKit)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(data, forType: NSPasteboard.PasteboardType(Self.type))
        pasteboard.setString(text, forType: .string)
        #elseif canImport(UIKit)
        UIPasteboard.general.setItems([[Self.type: data, "public.utf8-plain-text": text]])
        #endif
    }

    public func read() -> GraphFragment? {
        #if canImport(AppKit)
        let pasteboard = NSPasteboard.general
        if let data = pasteboard.data(forType: NSPasteboard.PasteboardType(Self.type)),
           let fragment = try? GraphFragment.decode(from: data) { return fragment }
        return pasteboard.string(forType: .string).flatMap { try? GraphFragment.decode(from: Data($0.utf8)) }
        #elseif canImport(UIKit)
        let pasteboard = UIPasteboard.general
        if let data = pasteboard.data(forPasteboardType: Self.type),
           let fragment = try? GraphFragment.decode(from: data) { return fragment }
        return pasteboard.string.flatMap { try? GraphFragment.decode(from: Data($0.utf8)) }
        #else
        return nil
        #endif
    }

    public var mayHaveFragment: Bool {
        #if canImport(AppKit)
        let types = NSPasteboard.general.types ?? []
        return types.contains(NSPasteboard.PasteboardType(Self.type)) || types.contains(.string)
        #elseif canImport(UIKit)
        UIPasteboard.general.contains(pasteboardTypes: [Self.type]) || UIPasteboard.general.hasStrings
        #else
        false
        #endif
    }
}
