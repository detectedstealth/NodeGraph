import XCTest

/// Core editing flows against the demo graph, on macOS and iPad. The canvas is one drawn view,
/// so the app is launched with `-ExposeCanvasElements`, which makes each node, link and group
/// an accessibility element the tests can find, tap and drag. Keys go through `typeKey`, which
/// is the hardware keyboard on iPad.
@MainActor
final class NodeGraphAppUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["-ExposeCanvasElements"]
        app.launch()
        XCTAssertTrue(node("A").waitForExistence(timeout: 10), "The demo graph did not appear")
    }

    // MARK: Helpers

    /// All elements labelled exactly `title` (a node, or a link, since links are labelled "Link from ...").
    private func nodes(_ title: String) -> XCUIElementQuery {
        app.buttons.matching(NSPredicate(format: "label == %@", title))
    }

    private func node(_ title: String) -> XCUIElement {
        nodes(title).firstMatch
    }

    /// A point on the node's title bar, clear of ports and widgets.
    private func titleBar(of element: XCUIElement) -> XCUICoordinate {
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.06))
    }

    /// A pointer click on macOS. A tap does not reach the canvas there, a click does.
    private func activate(_ coordinate: XCUICoordinate) {
        #if os(macOS)
        coordinate.click()
        #else
        coordinate.tap()
        #endif
    }

    private func activate(_ element: XCUIElement) {
        #if os(macOS)
        element.click()
        #else
        element.tap()
        #endif
    }

    private func select(_ title: String, file: StaticString = #filePath, line: UInt = #line) {
        let element = node(title)
        XCTAssertTrue(element.exists, "No node named \(title)", file: file, line: line)
        activate(titleBar(of: element))
        // The accessibility tree catches up with the model a moment after the click.
        let selected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isSelected == true"), object: element)
        XCTAssertEqual(
            XCTWaiter().wait(for: [selected], timeout: 3), .completed,
            "\(title) did not become selected", file: file, line: line)
    }

    private func press(_ key: String, _ flags: XCUIElement.KeyModifierFlags = []) {
        app.typeKey(key, modifierFlags: flags)
    }

    /// Runs an item from the selected node's context menu: a right-click on macOS, a long press on iPad.
    private func chooseFromMenu(of title: String, _ item: String) {
        let bar = titleBar(of: node(title))
        #if os(macOS)
        bar.rightClick()
        #else
        bar.press(forDuration: 1)
        #endif
        let entry = app.buttons[item].firstMatch
        if !entry.waitForExistence(timeout: 3) {
            XCTFail("The \(title) menu has no \(item) item")
            return
        }
        activate(entry)
    }

    /// Deletes the selected node with the Delete key on macOS. On iPad the menu is used instead:
    /// the iPad simulator does not deliver `typeKey` for Delete, Escape or Return to the app, though
    /// Command shortcuts arrive, so those keys are not tested there.
    private func deleteSelectedNode(titled title: String) {
        #if os(macOS)
        app.typeKey(XCUIKeyboardKey.delete.rawValue, modifierFlags: [])
        #else
        chooseFromMenu(of: title, "Delete")
        #endif
    }

    private func tapUndo() { activate(app.buttons["Undo"]) }
    private func tapRedo() { activate(app.buttons["Redo"]) }

    // MARK: Tests


    func testDemoGraphShowsItsNodesLinksAndGroup() {
        for title in ["A", "B", "Scale", "Compare", "Sine", "Arithmetic"] {
            XCTAssertTrue(node(title).exists, "\(title) is missing")
        }
        let links = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Link from"))
        XCTAssertGreaterThan(links.count, 0)
    }

    func testTapSelectsANodeAndTappingAnotherMovesTheSelection() {
        select("A")
        select("B")
        XCTAssertFalse(node("A").isSelected)
    }

    func testDraggingANodeMovesIt() {
        let scale = node("Scale")
        let before = scale.frame
        // Slow, with a hold at the end, so the canvas sees moves between the press and release.
        let start = titleBar(of: scale)
        let end = start.withOffset(CGVector(dx: 0, dy: 120))
        #if os(macOS)
        start.click(forDuration: 0.2, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.3)
        #else
        start.press(forDuration: 0.2, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.3)
        #endif
        // The accessibility tree catches up with the model a moment after the drop.
        let deadline = Date().addingTimeInterval(3)
        while node("Scale").frame.minY <= before.minY + 80, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        let after = node("Scale").frame
        XCTAssertEqual(after.minX, before.minX, accuracy: 4)
        XCTAssertGreaterThan(after.minY, before.minY + 80)
    }

    func testDeleteThenUndoAndRedo() {
        XCTAssertEqual(nodes("Sine").count, 1)
        select("Sine")
        deleteSelectedNode(titled: "Sine")
        XCTAssertTrue(waitForCount(of: "Sine", toBe: 0), "Delete did not remove the node")
        tapUndo()
        XCTAssertTrue(waitForCount(of: "Sine", toBe: 1), "Undo did not restore the node")
        tapRedo()
        XCTAssertTrue(waitForCount(of: "Sine", toBe: 0), "Redo did not delete the node again")
    }

    func testAddNodeFromTheToolbarSearch() {
        XCTAssertEqual(nodes("Sine").count, 1)
        activate(app.buttons["Add Node"])
        let search = app.textFields["Add node"]
        XCTAssertTrue(search.waitForExistence(timeout: 3), "The add-node search did not open")
        // The field is focused in code, but UI automation needs it focused by the pointer too.
        activate(search)
        search.typeText("Sine\n")
        XCTAssertTrue(waitForCount(of: "Sine", toBe: 2), "The new node was not added")
        tapUndo()
        XCTAssertTrue(waitForCount(of: "Sine", toBe: 1), "Undo did not remove the added node")
    }

    func testEscapeClosesTheAddNodeSearchWithoutAdding() throws {
        #if !os(macOS)
        throw XCTSkip("The iPad simulator does not deliver the Escape key to the app through typeKey")
        #endif
        activate(app.buttons["Add Node"])
        let search = app.textFields["Add node"]
        XCTAssertTrue(search.waitForExistence(timeout: 3))
        activate(search)
        press(XCUIKeyboardKey.escape.rawValue)
        XCTAssertTrue(waitForDisappearance(of: search))
        XCTAssertEqual(nodes("Sine").count, 1)
    }

    func testCopyAndPasteAddsACopy() {
        select("Sine")
        press("c", .command)
        press("v", .command)
        XCTAssertTrue(waitForCount(of: "Sine", toBe: 2), "Paste did not add a node")
    }

    func testDuplicateAddsACopyAndUndoRemovesIt() {
        select("Sine")
        press("d", .command)
        XCTAssertTrue(waitForCount(of: "Sine", toBe: 2), "Duplicate did not add a node")
        tapUndo()
        XCTAssertTrue(waitForCount(of: "Sine", toBe: 1), "Undo did not remove the duplicate")
    }

    func testEnterAndLeaveASubgraph() {
        select("Sum Times Scale")
        #if os(macOS)
        press("\r")
        #else
        chooseFromMenu(of: "Sum Times Scale", "Open Subgraph")
        #endif
        XCTAssertTrue(
            app.buttons["Editing Sum Times Scale"].waitForExistence(timeout: 3), "The breadcrumb did not open the subgraph")
        XCTAssertTrue(app.buttons["Go to Graph"].exists, "The breadcrumb has no way back to the root")
        XCTAssertFalse(node("Scale").exists, "Root nodes are still showing inside the subgraph")
        press("[", .command)
        XCTAssertTrue(node("Scale").waitForExistence(timeout: 3), "Command-[ did not return to the root")
    }

    // MARK: Waiting

    private func waitForCount(of title: String, toBe count: Int, timeout: TimeInterval = 3) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if nodes(title).count == count { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return nodes(title).count == count
    }

    private func waitForDisappearance(of element: XCUIElement, timeout: TimeInterval = 3) -> Bool {
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        return XCTWaiter().wait(for: [gone], timeout: timeout) == .completed
    }
}
