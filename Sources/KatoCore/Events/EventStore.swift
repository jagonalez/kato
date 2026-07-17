import Foundation

/// JSON persistence for events.
/// Default location: ~/Library/Application Support/Kato/events.json
public actor EventStore {
    public static var defaultDirectory: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Kato", isDirectory: true)
    }

    private let fileURL: URL

    public init(directory: URL? = nil) {
        let dir = directory ?? EventStore.defaultDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.fileURL = dir.appendingPathComponent("events.json")
    }

    public func load() -> [KatoEvent] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([KatoEvent].self, from: data)) ?? []
    }

    public func save(_ events: [KatoEvent]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(events) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
