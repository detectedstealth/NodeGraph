#if !os(tvOS) && !os(watchOS)
import Foundation
import NodeGraphCore

/// Using subgraph libraries from the editor: publishing a subgraph to one, importing from one, and
/// updating a document's copy.
///
/// The model holds the libraries the host gives it (``setLibraries(_:)``) and reports each change
/// through ``onLibraryChange``; storing them is the host's job. Changes to the document go through
/// commands, so a publish, an import and an update are each one undo step. Undoing one does not
/// change a library.
extension GraphEditorModel {
    /// Replaces the loaded libraries, as when the host reads them from a store.
    public func setLibraries(_ libraries: [SubgraphLibrary]) {
        self.libraries = libraries
    }

    public func library(_ id: LibraryID) -> SubgraphLibrary? {
        libraries.first { $0.id == id }
    }

    // MARK: Libraries

    /// Adds an empty library with a name that no other has, and reports it. Returns its id.
    @discardableResult
    public func createLibrary(named base: String = "Library") -> LibraryID {
        let taken = Set(libraries.map(\.name))
        var name = base, number = 2
        while taken.contains(name) {
            name = "\(base) \(number)"
            number += 1
        }
        let library = SubgraphLibrary(name: name)
        libraries.append(library)
        onLibraryChange?(library)
        return library.id
    }

    /// Renames a library. A blank name is refused.
    @discardableResult
    public func renameLibrary(_ id: LibraryID, to name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = libraries.firstIndex(where: { $0.id == id }) else { return false }
        guard libraries[index].name != trimmed else { return true }
        libraries[index].name = trimmed
        onLibraryChange?(libraries[index])
        return true
    }

    // MARK: Status

    /// How the document's copy of a subgraph compares with the library it came from. A subgraph
    /// with no origin, or whose library is not loaded, reads as ``SubgraphLibraryStatus/notFromLibrary``.
    public func libraryStatus(of id: SubgraphID) -> SubgraphLibraryStatus {
        guard let origin = editor.subgraphs[id]?.origin, let library = library(origin.library) else {
            return .notFromLibrary
        }
        return editor.libraryStatus(of: id, in: library)
    }

    /// The subgraph's library, if it came from one that is loaded.
    public func originLibrary(of id: SubgraphID) -> SubgraphLibrary? {
        editor.subgraphs[id]?.origin.flatMap { library($0.library) }
    }

    // MARK: Publishing, importing, updating

    /// Publishes a subgraph, with everything it contains instances of, to a library. Unchanged
    /// definitions keep their revision, changed ones get the next. The document's copies record
    /// their origin, so their status reads up to date.
    ///
    /// Nothing changes if the library refuses (see ``LibraryError``) or the canvas is read-only.
    @discardableResult
    public func publishSubgraph(_ id: SubgraphID, to libraryID: LibraryID, summary: String = "") -> Bool {
        guard isEditable, let index = libraries.firstIndex(where: { $0.id == libraryID }),
              let definitions = try? editor.publishable([id]) else { return false }
        var library = libraries[index]
        let summaries = summary.isEmpty ? [:] : [id: summary]
        guard let origins = try? library.publish(definitions, summaries: summaries) else { return false }
        let adopt = editor.adoptOriginsCommand(origins)
        if case .batch(let commands) = adopt, !commands.isEmpty {
            guard (try? perform(adopt, name: "Publish Subgraph", isScoped: true)) != nil else { return false }
        }
        libraries[index] = library
        onLibraryChange?(library)
        return true
    }

    /// Copies library subgraphs, and what they contain instances of, into the document. They show up
    /// in the add-node palette. Ones the document already has are left alone.
    @discardableResult
    public func importSubgraphs(_ ids: [SubgraphID], from libraryID: LibraryID) -> Bool {
        guard let library = library(libraryID), let command = try? editor.importCommand(ids, from: library),
              case .batch(let commands) = command, !commands.isEmpty else { return false }
        return (try? perform(command, name: "Import Subgraph", isScoped: true)) != nil
    }

    /// Replaces the document's copy of a subgraph with its library's current version. Edits made to
    /// the copy are lost (undo brings them back); read ``libraryStatus(of:)`` first to warn.
    @discardableResult
    public func updateSubgraphFromLibrary(_ id: SubgraphID) -> Bool {
        guard let library = originLibrary(of: id), library.entry(for: id) != nil,
              let command = try? editor.updateCommand(id, from: library) else { return false }
        return (try? perform(command, name: "Update Subgraph", isScoped: true)) != nil
    }
}

extension SubgraphLibraryStatus {
    /// A short phrase for the inspector.
    public var title: String {
        switch self {
        case .notFromLibrary: "Not from a library"
        case .missingFromLibrary: "No longer in its library"
        case .upToDate: "Up to date"
        case .updateAvailable(let revision): "Update available (revision \(revision))"
        case .locallyModified: "Edited since it was taken"
        case .modifiedAndUpdateAvailable(let revision): "Edited, and revision \(revision) is available"
        }
    }

    /// Whether the library has a newer version than the document's copy.
    public var hasUpdate: Bool {
        switch self {
        case .updateAvailable, .modifiedAndUpdateAvailable: true
        default: false
        }
    }
}
#endif
