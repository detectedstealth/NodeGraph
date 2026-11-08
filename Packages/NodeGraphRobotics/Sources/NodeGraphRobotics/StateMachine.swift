import Foundation
import NodeGraphCore

extension RoboticsPack {
    /// One line of a state machine's table: `from event -> to`. `from` may be `*` for any state.
    struct Transition: Equatable {
        var from: String
        var event: String
        var to: String
    }

    /// Reads the table: one transition per line, `#` starts a comment, blank lines are skipped.
    static func parseTransitions(_ text: String) throws -> [Transition] {
        var result: [Transition] = []
        for (index, raw) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
                .trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            let sides = line.components(separatedBy: "->")
            let left = sides[0].split(whereSeparator: \.isWhitespace).map(String.init)
            let right = sides.count == 2 ? sides[1].split(whereSeparator: \.isWhitespace).map(String.init) : []
            guard left.count == 2, right.count == 1 else {
                throw NodeExecutionError.failed("Line \(index + 1): expected \"from event -> to\"")
            }
            result.append(Transition(from: left[0], event: left[1], to: right[0]))
        }
        return result
    }

    static func registerStateMachine(in nodes: inout NodeRegistry) {
        // Turns a trigger into a named event for a state machine; empty when it did not fire.
        nodes.register(NodeDefinition(
            typeID: "robotics.event", displayName: "Event", category: "Robotics",
            ports: [
                PortDefinition(id: "trigger", direction: .input, kind: .trigger),
                PortDefinition(id: "event", direction: .output, type: .string),
            ],
            properties: [PropertyDefinition(
                id: "name", displayName: "Name", kind: .string(), defaultValue: .string("go"))],
            isPure: true,
            help: "Names an event. Its output is the name in a pass where the trigger fired, and empty otherwise.")
        ) { ctx in
            ["event": ctx.didTrigger("trigger") ? try ctx.property("name") : .string("")]
        }

        // State is `.object(["state": name, "since": seconds])`.
        nodes.register(NodeDefinition(
            typeID: "robotics.stateMachine", displayName: "State Machine", category: "Robotics",
            ports: [
                PortDefinition(id: "event", direction: .input, type: .string, defaultValue: "", allowsMultipleLinks: true),
                PortDefinition(id: "reset", direction: .input, kind: .trigger),
                PortDefinition(id: "state", direction: .output, type: .string),
                PortDefinition(id: "seconds", displayName: "Seconds in state", direction: .output, type: .number),
                PortDefinition(id: "changed", direction: .output, kind: .trigger),
            ],
            properties: [
                PropertyDefinition(id: "initial", displayName: "Initial state", kind: .string(), defaultValue: .string("idle")),
                PropertyDefinition(
                    id: "transitions", displayName: "Transitions", kind: .string(multiline: true),
                    defaultValue: .string("idle start -> running\nrunning stop -> idle")),
            ],
            help: "Holds one named state and moves on events. One line per transition: \"from event -> to\". Use * for any state. The first matching line wins.")
        ) { ctx in
            let initial = try ctx.property("initial").stringValue ?? ""
            guard !initial.isEmpty, !initial.contains(where: \.isWhitespace) else {
                throw NodeExecutionError.failed("The initial state needs a name without spaces")
            }
            let table = try parseTransitions(try ctx.property("transitions").stringValue ?? "")
            let now = ctx.time.elapsedSeconds

            var current = initial, since = now, changed = false
            if case .object(let saved)? = ctx.state, let name = saved["state"]?.stringValue, let start = saved["since"]?.numberValue {
                current = name
                since = start
            }
            func move(to next: String) {
                changed = changed || next != current
                if next != current { since = now }
                current = next
            }
            if ctx.didTrigger("reset") { move(to: initial) }

            // The event input holds one name, or an array of them when several nodes are linked.
            var events: [String] = []
            switch try ctx.input("event") {
            case .string(let name): events = [name]
            case .array(let values): events = values.compactMap(\.stringValue)
            default: break
            }
            // One move per pass: the first named event with a matching line.
            if let event = events.first(where: { name in
                !name.isEmpty && table.contains { $0.event == name && ($0.from == current || $0.from == "*") }
            }), let line = table.first(where: { $0.event == event && ($0.from == current || $0.from == "*") }) {
                move(to: line.to)
            }
            return NodeOutputs(
                ["state": .string(current), "seconds": .double(now - since)],
                triggers: changed ? ["changed"] : [],
                state: .object(["state": .string(current), "since": .double(since)]))
        }
    }
}
