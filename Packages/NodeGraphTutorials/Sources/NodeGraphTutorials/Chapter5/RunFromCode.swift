//# step 1
import Foundation
import NodeGraphCore
import NodeGraphRunKit

/// Runs a saved document with no editor and no window, as `ng-run` does.
///
/// Time is simulated, so the report is the same on every machine and every run.
func runDocument(_ data: Data, passes: Int) async throws -> RunReport {
    let document = try GraphDocument.decode(from: data)
    return try await GraphRun.run(document, ticks: passes, delta: .milliseconds(16))
}
//# step 2

/// The result a node of `type` reported on its last pass, as a number.
func lastNumber(in report: RunReport, nodeType type: String, port: String) -> Double? {
    let node = report.ticks.last?.nodes.first { $0.type == type }
    return node?.outputs[port]?.numberValue
}
