import Foundation
import NodeGraphCore
import NodeGraphSync
import Testing
@testable import NodeGraphTutorials

// The finished code of each Chapter 1 tutorial, run. A tutorial step that stops working fails here.

@Test func createAGraphBuildsTwoNumbersAndAnAdd() throws {
    let editor = try makeAdditionGraph()
    #expect(editor.graph.nodes.count == 3)
    #expect(editor.graph.links.count == 2)
}

@Test func runAGraphAddsTheNumbers() async throws {
    let editor = try makeAdditionGraph()
    let tick = try #require(try await runOnce(editor))
    #expect(tick.succeeded)
    #expect(additionResult(in: tick, of: editor) == 6)
}

@Test func runAGraphReportsFailures() async throws {
    #expect(try await divisionFailures(by: 0) == ["Division by zero"])
    #expect(try await divisionFailures(by: 2).isEmpty)
}

@Test func undoAndRedoWalkTheEdit() throws {
    #expect(try numberAcrossUndoAndRedo() == [4, 10, 4, 10])
}

@Test func aGroupIsOneUndoStep() throws {
    let history = try makeHistory()
    try resetNumbers(in: history)
    #expect(history.undoStack.count == 1)
    try history.undo()
    #expect(secondNumber(in: history) == 4)
}

@Test func saveAndLoadRoundTrips() throws {
    let editor = try makeAdditionGraph()
    let reopened = try openFromData(try saveToData(editor))
    #expect(reopened.graph == editor.graph)
}

@Test func theStoreNumbersSavesAndRefusesStaleOnes() async throws {
    let editor = try makeAdditionGraph()
    let store = InMemoryGraphStore()
    let id = GraphID()
    let first = try await saveToStore(editor, store: store, id: id)
    #expect(first.rawValue == 1)
    #expect(try await saveIfUnchanged(editor, store: store, id: id, since: first))
    #expect(try await saveIfUnchanged(editor, store: store, id: id, since: first) == false)
}
