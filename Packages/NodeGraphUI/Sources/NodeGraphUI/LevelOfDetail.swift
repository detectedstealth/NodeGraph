#if !os(tvOS) && !os(watchOS)
/// How much to draw at a zoom level. Zoomed far out, text is unreadable and ports are specks,
/// so the canvas skips them: that is what keeps thousands of nodes fast.
public struct LevelOfDetail: Hashable, Sendable {
    public enum Tier: Int, Hashable, Sendable, Comparable {
        /// Flat boxes and straight links only.
        case minimal
        /// Node titles and ports, no port labels.
        case reduced
        /// Everything.
        case full

        public static func < (lhs: Tier, rhs: Tier) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// Zoom at or above which each tier applies.
    public static let reducedFrom = 0.3
    public static let fullFrom = 0.6
    /// Below this zoom the grid's minor lines are too dense to be useful.
    public static let minorGridFrom = 0.35

    public var tier: Tier

    public init(zoom: Double) {
        tier = zoom >= Self.fullFrom ? .full : zoom >= Self.reducedFrom ? .reduced : .minimal
    }

    public var drawsTitles: Bool { tier >= .reduced }
    public var drawsPorts: Bool { tier >= .reduced }
    public var drawsPortLabels: Bool { tier == .full }
    public var drawsRoundedCorners: Bool { tier >= .reduced }
    /// Whether links are curves; otherwise a single straight line each.
    public var drawsLinkCurves: Bool { tier >= .reduced }
}
#endif
