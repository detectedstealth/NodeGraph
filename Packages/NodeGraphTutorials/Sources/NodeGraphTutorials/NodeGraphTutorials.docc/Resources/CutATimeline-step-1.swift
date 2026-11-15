import NodeGraphCore
import NodeGraphVideo

/// Two pieces of footage, described rather than decoded: a name and a length in seconds.
struct Footage {
    var library = AssetLibrary()
    let interview: HandleID
    let cutaway: HandleID

    init() {
        interview = library.add(AssetInfo(name: "interview.mov", duration: 10))
        cutaway = library.add(AssetInfo(name: "cutaway.mov", duration: 10))
    }
}
