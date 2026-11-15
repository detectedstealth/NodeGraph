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
