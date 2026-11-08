import NodeGraphCore
import NodeGraphNodes

/// Nodes for robot control and scenario generation: simulated sensors, filters, a PID
/// controller, a state machine, and actuators with limits.
///
/// Every node reads the pass's time step (`ctx.time.deltaSeconds`) rather than the wall clock,
/// so a graph behaves the same in a deterministic fixed-step run as it would at a steady rate.
/// Only the standard types (number, bool, string) are used; the pack adds no port types.
public enum RoboticsPack: NodePack {
    public static func register(nodes: inout NodeRegistry, types: inout TypeRegistry) {
        StandardTypes.register(in: &types)
        registerSensors(in: &nodes)
        registerFilters(in: &nodes)
        registerControl(in: &nodes)
        registerStateMachine(in: &nodes)
        registerActuators(in: &nodes)
    }

    /// The standard packs together with this one, ready to hand to a `GraphEditor` or runner.
    public static func makeRegistries() -> (nodes: NodeRegistry, types: TypeRegistry) {
        var nodes = NodeRegistry()
        var types = TypeRegistry()
        StandardPack.register(nodes: &nodes, types: &types)
        register(nodes: &nodes, types: &types)
        return (nodes, types)
    }

    // MARK: Shared helpers

    static func number(_ id: PortID, _ direction: PortDirection, _ value: Double? = nil) -> PortDefinition {
        PortDefinition(id: id, direction: direction, type: .number, defaultValue: value.map { .double($0) })
    }

    static func double(_ id: PropertyID, _ name: String, _ value: Double, min: Double? = nil) -> PropertyDefinition {
        PropertyDefinition(id: id, displayName: name, kind: .double(min: min), defaultValue: .double(value))
    }

    static func finite(_ value: Double, _ name: String) throws -> Double {
        guard value.isFinite else { throw NodeExecutionError.failed("\(name) is not a finite number") }
        return value
    }

    static func clamp(_ value: Double, _ low: Double, _ high: Double) -> Double {
        min(max(value, low), high)
    }
}
