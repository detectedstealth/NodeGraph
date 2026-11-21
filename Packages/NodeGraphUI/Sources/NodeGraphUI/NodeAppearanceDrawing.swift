#if !os(tvOS) && !os(watchOS)
import CoreGraphics
import NodeGraphCore
import SwiftUI

/// The radius of each corner of a node's outline. Pure, so shapes are tested without drawing.
struct NodeCorners: Equatable {
    var topLeading: Double
    var bottomLeading: Double
    var bottomTrailing: Double
    var topTrailing: Double

    static func radii(for shape: NodeShape, radius: Double) -> NodeCorners {
        switch shape {
        case .box: NodeCorners(topLeading: 0, bottomLeading: 0, bottomTrailing: 0, topTrailing: 0)
        case .round: NodeCorners(topLeading: radius, bottomLeading: radius, bottomTrailing: radius, topTrailing: radius)
        case .card: NodeCorners(topLeading: radius, bottomLeading: 0, bottomTrailing: radius, topTrailing: 0)
        }
    }

    var shape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: topLeading, bottomLeadingRadius: bottomLeading,
            bottomTrailingRadius: bottomTrailing, topTrailingRadius: topTrailing)
    }

    /// The corners of a title bar sitting at the top of the node: the node's top corners, and
    /// its bottom ones too when the node is only a bar (collapsed).
    func header(isCollapsed: Bool) -> NodeCorners {
        NodeCorners(
            topLeading: topLeading, bottomLeading: isCollapsed ? bottomLeading : 0,
            bottomTrailing: isCollapsed ? bottomTrailing : 0, topTrailing: topTrailing)
    }
}

/// What of the title bar is drawn right now.
struct TitleStyle: Equatable {
    var drawsBar: Bool
    var drawsTitle: Bool

    /// `isActive` is whether the pointer is over the node or it is selected, which reveals an
    /// autohiding title.
    init(_ mode: NodeTitleMode, isActive: Bool) {
        switch mode {
        case .normal: self.init(drawsBar: true, drawsTitle: true)
        case .hidden: self.init(drawsBar: false, drawsTitle: false)
        case .transparent: self.init(drawsBar: false, drawsTitle: true)
        case .autohide: self = isActive ? Self(.normal, isActive: true) : Self(.hidden, isActive: false)
        }
    }

    private init(drawsBar: Bool, drawsTitle: Bool) {
        self.drawsBar = drawsBar
        self.drawsTitle = drawsTitle
    }
}

extension PortShape {
    /// The mark for a port centered at `center` with nominal radius `r`.
    func path(center: CGPoint, radius r: Double) -> Path {
        var path = Path()
        switch self {
        case .circle:
            path.addEllipse(in: CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r))
        case .square:
            path.addRect(CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r))
        case .diamond:
            path.move(to: CGPoint(x: center.x, y: center.y - r * 1.3))
            path.addLine(to: CGPoint(x: center.x + r * 1.3, y: center.y))
            path.addLine(to: CGPoint(x: center.x, y: center.y + r * 1.3))
            path.addLine(to: CGPoint(x: center.x - r * 1.3, y: center.y))
            path.closeSubpath()
        case .arrow:
            path.move(to: CGPoint(x: center.x - r, y: center.y - r * 1.1))
            path.addLine(to: CGPoint(x: center.x + r * 1.2, y: center.y))
            path.addLine(to: CGPoint(x: center.x - r, y: center.y + r * 1.1))
            path.closeSubpath()
        case .grid:
            // Four squares with a gap, so a hollow (unconnected) grid still reads as a grid.
            let side = r * 0.9, gap = r * 0.15
            for x in [center.x - gap - side, center.x + gap] {
                for y in [center.y - gap - side, center.y + gap] {
                    path.addRect(CGRect(x: x, y: y, width: side, height: side))
                }
            }
        }
        return path
    }
}

extension GraphEditorModel {
    /// The mark a port is drawn with: its own, else a diamond for triggers, else its type's, else a circle.
    public func portShape(of port: PortDefinition) -> PortShape {
        port.shape ?? (port.kind == .trigger ? .diamond : editor.types.info(for: port.type)?.shape ?? .circle)
    }
}
#endif
