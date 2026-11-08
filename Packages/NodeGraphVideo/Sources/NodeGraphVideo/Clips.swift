import NodeGraphCore

extension VideoPack {
    static func registerClips(in nodes: inout NodeRegistry) {
        // The asset is a handle. Its length comes from the `AssetLibrary` service, so a clip
        // cannot name an asset the host does not have.
        nodes.register(NodeDefinition(
            typeID: "video.clip", displayName: "Clip", category: "Video",
            ports: [PortDefinition(id: "clip", direction: .output, type: .clip)],
            properties: [PropertyDefinition(
                id: "asset", displayName: "Asset", kind: .custom("video.asset"), defaultValue: .null)],
            isPure: true,
            help: "A whole media asset, from its start to its end. Pick the asset from the library.")
        ) { ctx in
            guard case .handle(let handle) = try ctx.property("asset") else {
                throw NodeExecutionError.failed("No asset chosen")
            }
            guard let info = ctx.services[AssetLibrary.self]?[handle] else {
                throw NodeExecutionError.failed("The asset is not in the library")
            }
            let clip = VideoClip(asset: handle, sourceStart: 0, sourceEnd: info.duration, sourceDuration: info.duration)
            return ["clip": clip.value]
        }

        // Keeps part of a clip. Times are seconds of the clip's asset. An end of 0 or less means
        // "to the end of the clip".
        nodes.register(NodeDefinition(
            typeID: "video.trim", displayName: "Trim", category: "Video",
            ports: [
                PortDefinition(id: "clip", direction: .input, type: .clip),
                PortDefinition(id: "result", direction: .output, type: .clip),
            ],
            properties: [number("start", "Start (s)", 0), number("end", "End (s, 0 = to the end)", 0)],
            isPure: true,
            help: "Keeps the part of a clip between Start and End, in seconds of the asset. End 0 keeps everything after Start.")
        ) { ctx in
            let clip = try clip(try ctx.input("clip"), port: "clip")
            let start = try ctx.property("start").numberValue ?? 0
            let requestedEnd = try ctx.property("end").numberValue ?? 0
            let end = requestedEnd > 0 ? requestedEnd : clip.sourceEnd
            guard start >= clip.sourceStart, end <= clip.sourceEnd, start < end else {
                throw NodeExecutionError.failed(
                    "Trim \(start)–\(end) s is outside the clip's \(clip.sourceStart)–\(clip.sourceEnd) s")
            }
            var trimmed = clip
            trimmed.sourceStart = start
            trimmed.sourceEnd = end
            return ["result": trimmed.value]
        }
    }
}
