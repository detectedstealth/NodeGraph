import Foundation

/// Multiplies the limits of the timing tests. Shared CI runners have few cores and are slow, so
/// CI sets `NODEGRAPH_TIMING_SCALE` (for example 4); on a developer machine it is 1.
let timingScale: Double = {
    guard let text = ProcessInfo.processInfo.environment["NODEGRAPH_TIMING_SCALE"],
          let value = Double(text), value >= 1 else { return 1 }
    return value
}()
