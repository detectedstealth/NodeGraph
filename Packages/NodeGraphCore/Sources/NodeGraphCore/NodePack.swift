/// A bundle of port types and node definitions (math, robotics, video) that registers itself.
///
/// Packs are plain types with a static `register`, so an app composes the ones it needs:
///
///     var nodes = NodeRegistry()
///     var types = TypeRegistry()
///     MathPack.register(nodes: &nodes, types: &types)
///     RoboticsPack.register(nodes: &nodes, types: &types)
public protocol NodePack {
    /// Adds this pack's port types to `types` and its node definitions and executors to `nodes`.
    /// Registering twice is harmless; later registrations replace earlier ones.
    static func register(nodes: inout NodeRegistry, types: inout TypeRegistry)
}
