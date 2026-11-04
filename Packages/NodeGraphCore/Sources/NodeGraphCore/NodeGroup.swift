/// A titled rectangle that visually and logically groups nodes.
///
/// Membership is not stored; it is derived from which nodes the bounds contain.
public struct NodeGroup: Hashable, Sendable, Codable {
    public var id: GroupID
    public var title: String
    public var bounds: GraphRect
    public var color: RGBAColor?

    public init(id: GroupID = GroupID(), title: String, bounds: GraphRect, color: RGBAColor? = nil) {
        self.id = id
        self.title = title
        self.bounds = bounds
        self.color = color
    }
}
