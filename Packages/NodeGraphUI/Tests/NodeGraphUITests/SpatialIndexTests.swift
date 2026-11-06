import Testing
import NodeGraphCore
@testable import NodeGraphUI

@Suite struct SpatialIndexTests {
    @Test func findsItemsByRegionAndPoint() {
        var index = SpatialIndex<Int>()
        index.insert(1, rect: GraphRect(x: 0, y: 0, width: 100, height: 100), order: 0)
        index.insert(2, rect: GraphRect(x: 1000, y: 1000, width: 50, height: 50), order: 1)
        #expect(index.ids(in: GraphRect(x: 50, y: 50, width: 10, height: 10)) == [1])
        #expect(index.ids(at: GraphPoint(x: 1010, y: 1010)) == [2])
        #expect(index.ids(at: GraphPoint(x: 500, y: 500)).isEmpty)
    }

    @Test func radiusGrowsThePoint() {
        var index = SpatialIndex<Int>()
        index.insert(1, rect: GraphRect(x: 0, y: 0, width: 10, height: 10), order: 0)
        #expect(index.ids(at: GraphPoint(x: 15, y: 5)).isEmpty)
        #expect(index.ids(at: GraphPoint(x: 15, y: 5), radius: 6) == [1])
    }

    @Test func resultsFollowOrderNotInsertionSequence() {
        var index = SpatialIndex<String>()
        let rect = GraphRect(x: 0, y: 0, width: 10, height: 10)
        index.insert("top", rect: rect, order: 5)
        index.insert("bottom", rect: rect, order: 1)
        #expect(index.ids(at: GraphPoint(x: 5, y: 5)) == ["bottom", "top"])
    }

    @Test func itemSpanningCellsIsReportedOnce() {
        var index = SpatialIndex<Int>(cellSize: 10)
        index.insert(1, rect: GraphRect(x: 0, y: 0, width: 55, height: 55), order: 0)
        #expect(index.ids(in: GraphRect(x: -5, y: -5, width: 100, height: 100)) == [1])
    }

    @Test func movingAndRemovingForgetOldPlace() {
        var index = SpatialIndex<Int>()
        index.insert(1, rect: GraphRect(x: 0, y: 0, width: 10, height: 10), order: 0)
        index.insert(1, rect: GraphRect(x: 900, y: 900, width: 10, height: 10), order: 0)
        #expect(index.ids(at: GraphPoint(x: 5, y: 5)).isEmpty)
        #expect(index.ids(at: GraphPoint(x: 905, y: 905)) == [1])
        index.remove(1)
        #expect(index.count == 0)
        #expect(index.ids(at: GraphPoint(x: 905, y: 905)).isEmpty)
    }

    @Test func hugeItemsAreStillFound() {
        var index = SpatialIndex<Int>(cellSize: 10)
        index.insert(1, rect: GraphRect(x: -5000, y: -5000, width: 10000, height: 10000), order: 0)
        index.insert(2, rect: GraphRect(x: 0, y: 0, width: 5, height: 5), order: 1)
        #expect(index.ids(at: GraphPoint(x: 3, y: 3)) == [1, 2])
        #expect(index.ids(at: GraphPoint(x: 4000, y: 4000)) == [1])
        index.remove(1)
        #expect(index.ids(at: GraphPoint(x: 4000, y: 4000)).isEmpty)
    }

    @Test func nonFiniteRectsDoNotCrash() {
        var index = SpatialIndex<Int>()
        index.insert(1, rect: GraphRect(x: .nan, y: 0, width: 10, height: 10), order: 0)
        index.insert(2, rect: GraphRect(x: 0, y: 0, width: .infinity, height: 10), order: 1)
        _ = index.ids(in: GraphRect(x: 0, y: 0, width: 1, height: 1))
        index.remove(1)
        index.remove(2)
        #expect(index.count == 0)
    }

    @Test func matchesBruteForceOnRandomRects() {
        var generator = SeededGenerator(seed: 42)
        var index = SpatialIndex<Int>(cellSize: 64)
        var rects: [Int: GraphRect] = [:]
        for id in 0..<400 {
            let rect = GraphRect(
                x: Double.random(in: -1000...1000, using: &generator),
                y: Double.random(in: -1000...1000, using: &generator),
                width: Double.random(in: 1...300, using: &generator),
                height: Double.random(in: 1...300, using: &generator))
            rects[id] = rect
            index.insert(id, rect: rect, order: id)
        }
        for _ in 0..<100 {
            let query = GraphRect(
                x: Double.random(in: -1200...1200, using: &generator),
                y: Double.random(in: -1200...1200, using: &generator),
                width: Double.random(in: 0...500, using: &generator),
                height: Double.random(in: 0...500, using: &generator))
            let expected = rects.filter { $0.value.intersects(query) }.keys.sorted()
            #expect(index.ids(in: query) == expected)
        }
    }
}

/// Deterministic generator so the random test is repeatable.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
