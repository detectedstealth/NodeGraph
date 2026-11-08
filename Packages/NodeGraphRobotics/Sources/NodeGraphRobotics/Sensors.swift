import Foundation
import NodeGraphCore

extension RoboticsPack {
    static func registerSensors(in nodes: inout NodeRegistry) {
        // A simulated sensor: a waveform of the run's time plus seeded noise. Reads the clock, so
        // it is not pure. The noise depends only on the seed and the pass number, so a run repeats.
        nodes.register(NodeDefinition(
            typeID: "robotics.signal", displayName: "Signal Source", category: "Robotics",
            ports: [number("value", .output)],
            properties: [
                PropertyDefinition(
                    id: "waveform", displayName: "Waveform",
                    kind: .choice(Waveform.allCases.map { PropertyChoice(value: $0.rawValue, label: $0.rawValue) }),
                    defaultValue: .string(Waveform.sine.rawValue)),
                double("amplitude", "Amplitude", 1),
                double("frequency", "Frequency (Hz)", 1, min: 0),
                double("phase", "Phase (cycles)", 0),
                double("offset", "Offset", 0),
                double("noise", "Noise amplitude", 0, min: 0),
                PropertyDefinition(id: "seed", displayName: "Noise seed", kind: .int(), defaultValue: .int(0)),
            ],
            help: "A simulated sensor reading: a waveform of the run's time, plus noise that repeats for the same seed.")
        ) { ctx in
            let name = try ctx.property("waveform").stringValue ?? ""
            guard let waveform = Waveform(rawValue: name) else {
                throw NodeExecutionError.failed("Unknown waveform \(name)")
            }
            let cycles = try ctx.property("frequency").numberValue.map { $0 * ctx.time.elapsedSeconds } ?? 0
            let phase = cycles + (try ctx.property("phase").numberValue ?? 0)
            var value = waveform.sample(atCycle: phase) * (try ctx.property("amplitude").numberValue ?? 1)
            value += try ctx.property("offset").numberValue ?? 0
            let noise = try ctx.property("noise").numberValue ?? 0
            if noise != 0 {
                let seed = try ctx.property("seed").intValue ?? 0
                value += noise * unitNoise(seed: seed, tick: ctx.time.tick)
            }
            return ["value": .double(try finite(value, "Signal"))]
        }
    }

    enum Waveform: String, CaseIterable {
        case sine, square, triangle, sawtooth, constant

        /// The waveform from -1 to 1 at `cycle` (whole numbers are periods). Sine and triangle
        /// start at 0 and rise; square starts high; sawtooth starts at -1.
        func sample(atCycle cycle: Double) -> Double {
            let fraction = cycle - cycle.rounded(.down)
            switch self {
            case .sine: return sin(2 * .pi * cycle)
            case .square: return fraction < 0.5 ? 1 : -1
            case .triangle:
                let shifted = (cycle - 0.25) - (cycle - 0.25).rounded(.down)
                return 2 * abs(2 * shifted - 1) - 1
            case .sawtooth: return 2 * fraction - 1
            case .constant: return 1
            }
        }
    }

    /// A repeatable value from -1 up to 1 for a seed and pass (SplitMix64).
    static func unitNoise(seed: Int64, tick: Int) -> Double {
        var z = UInt64(bitPattern: seed) &+ UInt64(truncatingIfNeeded: tick) &* 0x9E37_79B9_7F4A_7C15
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return Double(z >> 11) / Double(1 << 53) * 2 - 1
    }
}
