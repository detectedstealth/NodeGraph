import NodeGraphCore

/// How the editor looks. Plain data with platform-neutral colors, so it can be stored, edited
/// and shared; the canvas turns colors into SwiftUI colors when it draws.
public struct GraphTheme: Hashable, Sendable {
    public var background: RGBAColor
    public var gridMinor: RGBAColor
    public var gridMajor: RGBAColor
    /// Graph units between minor grid lines.
    public var gridSpacing: Double
    /// Every this many minor lines there is a major one.
    public var gridMajorEvery: Int

    public var nodeBody: RGBAColor
    public var nodeHeader: RGBAColor
    public var nodeBorder: RGBAColor
    public var nodeTitle: RGBAColor
    public var portLabel: RGBAColor
    public var selection: RGBAColor
    /// Used for a port whose type has no registered color.
    public var unknownPortColor: RGBAColor
    public var triggerPortColor: RGBAColor

    public var link: RGBAColor
    public var linkSelected: RGBAColor
    public var linkTrigger: RGBAColor

    public var groupFill: RGBAColor
    public var groupBorder: RGBAColor
    public var groupTitle: RGBAColor

    public var running: RGBAColor
    public var failed: RGBAColor
    /// Opacity of muted and never-run nodes.
    public var inactiveOpacity: Double

    public var cornerRadius: Double
    public var borderWidth: Double
    public var linkWidth: Double
    public var titleFontSize: Double
    public var portFontSize: Double

    public init(
        background: RGBAColor,
        gridMinor: RGBAColor,
        gridMajor: RGBAColor,
        gridSpacing: Double = 20,
        gridMajorEvery: Int = 5,
        nodeBody: RGBAColor,
        nodeHeader: RGBAColor,
        nodeBorder: RGBAColor,
        nodeTitle: RGBAColor,
        portLabel: RGBAColor,
        selection: RGBAColor,
        unknownPortColor: RGBAColor,
        triggerPortColor: RGBAColor,
        link: RGBAColor,
        linkSelected: RGBAColor,
        linkTrigger: RGBAColor,
        groupFill: RGBAColor,
        groupBorder: RGBAColor,
        groupTitle: RGBAColor,
        running: RGBAColor,
        failed: RGBAColor,
        inactiveOpacity: Double = 0.45,
        cornerRadius: Double = 6,
        borderWidth: Double = 1,
        linkWidth: Double = 2,
        titleFontSize: Double = 13,
        portFontSize: Double = 11
    ) {
        self.background = background
        self.gridMinor = gridMinor
        self.gridMajor = gridMajor
        self.gridSpacing = gridSpacing
        self.gridMajorEvery = gridMajorEvery
        self.nodeBody = nodeBody
        self.nodeHeader = nodeHeader
        self.nodeBorder = nodeBorder
        self.nodeTitle = nodeTitle
        self.portLabel = portLabel
        self.selection = selection
        self.unknownPortColor = unknownPortColor
        self.triggerPortColor = triggerPortColor
        self.link = link
        self.linkSelected = linkSelected
        self.linkTrigger = linkTrigger
        self.groupFill = groupFill
        self.groupBorder = groupBorder
        self.groupTitle = groupTitle
        self.running = running
        self.failed = failed
        self.inactiveOpacity = inactiveOpacity
        self.cornerRadius = cornerRadius
        self.borderWidth = borderWidth
        self.linkWidth = linkWidth
        self.titleFontSize = titleFontSize
        self.portFontSize = portFontSize
    }

    /// The color for a port: its type's registered color, the trigger color for trigger ports,
    /// or the fallback for a type nobody registered.
    public func color(for port: PortDefinition, in types: TypeRegistry) -> RGBAColor {
        if port.kind == .trigger { return triggerPortColor }
        return types.info(for: port.type)?.color ?? unknownPortColor
    }

    public static let dark = GraphTheme(
        background: .gray(0.11),
        gridMinor: .gray(1, alpha: 0.04),
        gridMajor: .gray(1, alpha: 0.09),
        nodeBody: .gray(0.20),
        nodeHeader: .gray(0.28),
        nodeBorder: .gray(0.36),
        nodeTitle: .gray(0.94),
        portLabel: .gray(0.75),
        selection: RGBAColor(red: 0.30, green: 0.60, blue: 1),
        unknownPortColor: .gray(0.60),
        triggerPortColor: RGBAColor(red: 0.95, green: 0.75, blue: 0.25),
        link: .gray(0.65),
        linkSelected: RGBAColor(red: 0.30, green: 0.60, blue: 1),
        linkTrigger: RGBAColor(red: 0.95, green: 0.75, blue: 0.25),
        groupFill: RGBAColor(red: 0.30, green: 0.60, blue: 1, alpha: 0.10),
        groupBorder: RGBAColor(red: 0.30, green: 0.60, blue: 1, alpha: 0.45),
        groupTitle: .gray(0.85),
        running: RGBAColor(red: 0.30, green: 0.80, blue: 0.45),
        failed: RGBAColor(red: 0.95, green: 0.30, blue: 0.30))

    public static let light = GraphTheme(
        background: .gray(0.95),
        gridMinor: .gray(0, alpha: 0.05),
        gridMajor: .gray(0, alpha: 0.11),
        nodeBody: .gray(1),
        nodeHeader: .gray(0.88),
        nodeBorder: .gray(0.70),
        nodeTitle: .gray(0.10),
        portLabel: .gray(0.30),
        selection: RGBAColor(red: 0.05, green: 0.40, blue: 0.95),
        unknownPortColor: .gray(0.45),
        triggerPortColor: RGBAColor(red: 0.85, green: 0.55, blue: 0.05),
        link: .gray(0.40),
        linkSelected: RGBAColor(red: 0.05, green: 0.40, blue: 0.95),
        linkTrigger: RGBAColor(red: 0.85, green: 0.55, blue: 0.05),
        groupFill: RGBAColor(red: 0.05, green: 0.40, blue: 0.95, alpha: 0.08),
        groupBorder: RGBAColor(red: 0.05, green: 0.40, blue: 0.95, alpha: 0.40),
        groupTitle: .gray(0.20),
        running: RGBAColor(red: 0.10, green: 0.60, blue: 0.30),
        failed: RGBAColor(red: 0.85, green: 0.15, blue: 0.15))
}

extension RGBAColor {
    /// A gray with equal red, green and blue.
    static func gray(_ level: Double, alpha: Double = 1) -> RGBAColor {
        RGBAColor(red: level, green: level, blue: level, alpha: alpha)
    }
}
