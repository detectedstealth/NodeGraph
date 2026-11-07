import Testing
import NodeGraphCore
@testable import NodeGraphUI

@Suite struct LinkPathTests {
    let a = GraphPoint(x: 0, y: 0)
    let b = GraphPoint(x: 300, y: 100)

    @Test(arguments: LinkStyle.allCases)
    func everyStyleStartsAndEndsAtThePorts(style: LinkStyle) {
        let path = LinkPath(from: a, to: b, style: style)
        #expect(path.start == a)
        #expect(path.end == b)
        #expect(path.polyline().first == a)
        #expect(path.polyline().last == b)
    }

    @Test(arguments: LinkStyle.allCases)
    func waypointsAreOnThePath(style: LinkStyle) {
        let waypoint = GraphPoint(x: 150, y: -80)
        let path = LinkPath(from: a, to: b, waypoints: [waypoint], style: style)
        #expect(path.polyline().contains(waypoint))
        #expect(path.end == b)
    }

    @Test func splineLeavesAndEntersHorizontally() throws {
        let path = LinkPath(from: a, to: b, style: .spline)
        guard case .cubic(let c1, let c2, _) = try #require(path.segments.first) else {
            Issue.record("expected a curve")
            return
        }
        #expect(c1.y == a.y && c1.x > a.x)
        #expect(c2.y == b.y && c2.x < b.x)
    }

    @Test func splineWithWaypointsIsOneCurvePerHop() {
        let path = LinkPath(from: a, to: b, waypoints: [GraphPoint(x: 100, y: 50), GraphPoint(x: 200, y: 50)], style: .spline)
        #expect(path.segments.count == 3)
    }

    @Test func linearHasPortStubs() {
        let polyline = LinkPath(from: a, to: b, style: .linear).polyline()
        #expect(polyline[1] == GraphPoint(x: LinkPath.stubLength, y: 0))
        #expect(polyline[polyline.count - 2] == GraphPoint(x: 300 - LinkPath.stubLength, y: 100))
    }

    @Test func orthogonalSegmentsAreAxisAligned() {
        let points = LinkPath(from: a, to: b, waypoints: [GraphPoint(x: 120, y: 200)], style: .orthogonal).polyline()
        for (p, q) in zip(points, points.dropFirst()) {
            #expect(p.x == q.x || p.y == q.y)
        }
    }

    @Test func distanceIsZeroOnThePathAndGrowsAway() {
        let path = LinkPath(from: a, to: b, style: .linear)
        #expect(path.distance(to: a) < 1e-9)
        #expect(path.distance(to: GraphPoint(x: 8, y: 0)) < 1e-9)  // on the first stub
        #expect(abs(path.distance(to: GraphPoint(x: 8, y: 10)) - 10) < 1e-9)
    }

    @Test func distanceToACurveIsSmallNearItsMiddle() {
        let path = LinkPath(from: a, to: b, style: .spline)
        let middle = path.polyline(curveSteps: 32)[16]
        #expect(path.distance(to: middle) < 1e-6)
        #expect(path.distance(to: GraphPoint(x: middle.x, y: middle.y + 50)) > 20)
    }

    @Test func boundsContainEveryPolylinePoint() {
        let path = LinkPath(from: a, to: b, waypoints: [GraphPoint(x: 150, y: -80)], style: .spline)
        let bounds = path.bounds()
        #expect(path.polyline().allSatisfy { bounds.contains($0) })
    }

    @Test func zeroLengthLinkDoesNotBreak() {
        let path = LinkPath(from: a, to: a, style: .spline)
        #expect(path.distance(to: a) < 1e-9)
        #expect(path.bounds().size.width >= 0)
    }
}

@Suite struct LevelOfDetailTests {
    @Test func tiersFollowZoom() {
        #expect(LevelOfDetail(zoom: 1).tier == .full)
        #expect(LevelOfDetail(zoom: 0.6).tier == .full)
        #expect(LevelOfDetail(zoom: 0.5).tier == .reduced)
        #expect(LevelOfDetail(zoom: 0.3).tier == .reduced)
        #expect(LevelOfDetail(zoom: 0.1).tier == .minimal)
    }

    @Test func farOutDrawsLessAndNearDrawsMore() {
        let far = LevelOfDetail(zoom: 0.1), mid = LevelOfDetail(zoom: 0.4), near = LevelOfDetail(zoom: 2)
        #expect(!far.drawsTitles && !far.drawsPorts && !far.drawsLinkCurves)
        #expect(mid.drawsTitles && mid.drawsPorts && !mid.drawsPortLabels)
        #expect(near.drawsPortLabels && near.drawsLinkCurves)
    }
}
