import NodeGraphCore
import NodeGraphVideo
import Testing
@testable import NodeGraphTutorials

// Chapter 4: the finished code of the robotics and video tutorials, run.

@Test func theControlLoopSettlesOnItsSetpoint() async throws {
    let editor = makeRoboticsEditor()
    let plant = try addControlLoop(to: editor, setpoint: 1)
    let readings = try await simulate(editor, plant: plant, seconds: 15)
    #expect(readings.count == 1500)
    let result = overshootAndFinalError(of: readings, target: 1)
    #expect(result.finalError < 0.01)
    #expect(result.overshoot < 0.5)
}

@Test func aSimulationGivesTheSameNumbersEveryTime() async throws {
    var runs: [[Double]] = []
    for _ in 0..<2 {
        let editor = makeRoboticsEditor()
        // Node ids differ between runs; the numbers must not.
        let plant = try addControlLoop(to: editor, setpoint: 1)
        runs.append(try await simulate(editor, plant: plant, seconds: 3))
    }
    #expect(runs[0] == runs[1])
}

@Test func aStrongerIntegralGainOvershootsMore() async throws {
    var overshoots: [Double] = []
    for ki in [0.0, 20.0] {
        let editor = makeRoboticsEditor()
        let plant = try addControlLoop(to: editor, setpoint: 1, ki: ki)
        let readings = try await simulate(editor, plant: plant, seconds: 15)
        overshoots.append(overshootAndFinalError(of: readings, target: 1).overshoot)
    }
    #expect(overshoots[1] > overshoots[0])
}

@Test func theTimelineCrossfadesAndAnyFrameCanBeAskedForInAnyOrder() async throws {
    let footage = Footage()
    let renderer = try makeRenderer(for: try makeTimeline(using: footage), using: footage)

    let before = describe(try await renderer.frame(at: 2), using: footage)
    #expect(before == ["interview.mov at 2.0 s, opacity 1.0"])
    let during = describe(try await renderer.frame(at: 3.5), using: footage)
    #expect(during == ["interview.mov at 3.5 s, opacity 0.5", "cutaway.mov at 0.5 s, opacity 0.5"])
    let after = describe(try await renderer.frame(at: 5), using: footage)
    #expect(after == ["cutaway.mov at 2.0 s, opacity 1.0"])

    // Scrubbing back gives the same frame as the first time.
    #expect(describe(try await renderer.frame(at: 2), using: footage) == before)
}
