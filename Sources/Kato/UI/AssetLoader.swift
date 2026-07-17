import AppKit

/// Resolves mascot artwork in both packaged and dev modes.
/// Lookup order:
///   (a) Bundle.main.resourceURL/Assets/Mascot/<name>.png  (packaged Kato.app)
///   (b) Assets/Mascot/<name>.png relative to the cwd      (`swift run Kato`
///       from the repo root, `kato assets-check`, etc.)
/// Loaded NSImages are cached.
@MainActor
enum AssetLoader {
    private static var imageCache: [String: NSImage?] = [:]

    /// The resolved file URL for an image, or nil when not found anywhere.
    static func url(forImageNamed name: String) -> URL? {
        let relative = "Assets/Mascot/\(name).png"
        if let resources = Bundle.main.resourceURL {
            let bundled = resources.appendingPathComponent(relative)
            if FileManager.default.fileExists(atPath: bundled.path) {
                return bundled
            }
        }
        let dev = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(relative)
        if FileManager.default.fileExists(atPath: dev.path) {
            return dev
        }
        return nil
    }

    /// The image (cached), or nil when the asset can't be found/loaded.
    static func image(named name: String) -> NSImage? {
        if let cached = imageCache[name] {
            return cached
        }
        let image = url(forImageNamed: name).flatMap { NSImage(contentsOf: $0) }
        imageCache[name] = image
        return image
    }
}
