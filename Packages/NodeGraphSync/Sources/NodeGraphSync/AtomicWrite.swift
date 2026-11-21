import Foundation

extension Data {
    /// Writes the data so a reader never sees a half-written file. WASI has no temporary files,
    /// so there it writes in place.
    func writeAtomically(to url: URL) throws {
        #if os(WASI)
        try write(to: url)
        #else
        try write(to: url, options: .atomic)
        #endif
    }
}
