import Testing
@testable import NodeGraphTutorials

// Chapter tests live next to this file, one per tutorial (docs/TUTORIALS.md).
@Test func packageBuilds() {
    _ = NodeGraphTutorials.self
}
