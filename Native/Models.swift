import Foundation

struct Song: Codable, Identifiable {
    var id: String = UUID().uuidString
    var title: String
    var artist = ""
    var album = ""
    var year = ""
    var favorite = false
    var artwork: String? = nil
    var filename: String
    var source: String
    var hash: String
    var size: Int64
    var duration: Double
}
struct Playlist: Codable, Identifiable {
    var id: String = UUID().uuidString
    var name: String
    var songIDs: [String] = []
}
struct DownloadJob: Codable, Identifiable {
    var id: String = UUID().uuidString
    var url: String
    var title: String
    var state: String = "queued"
    var detail = ""
    var progress: Double? = nil
    var authorizedAt = Date().timeIntervalSince1970
    var songID: String? = nil
}
struct Catalog: Codable {
    var version = 1
    var songs: [Song] = []
    var playlists: [Playlist] = []
    var jobs: [DownloadJob] = []
    var shuffled = false
    var repeatMode = "off"
}
struct NativeError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

enum AudioLinks {
    static let youtube = Set(["youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com", "youtu.be", "www.youtu.be"])
    static let extensions = Set(["mp3", "m4a", "aac", "wav", "aiff", "aif", "caf", "flac"])
    static func validated(_ value: String) throws -> URL {
        guard let components = URLComponents(string: value), components.scheme?.lowercased() == "https",
              components.user == nil, components.password == nil, components.host?.isEmpty == false,
              let url = components.url else { throw NativeError("Usa un enlace HTTPS sin usuario ni contraseña.") }
        return url
    }
    static func extract(_ text: String) throws -> [URL] {
        guard text.count <= 100000 else { throw NativeError("El texto supera 100.000 caracteres.") }
        let regex = try NSRegularExpression(pattern: "https?://[^\\s<>\"']+", options: .caseInsensitive)
        let values = regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match -> String? in
            guard let range = Range(match.range, in: text) else { return nil }
            var value = String(text[range])
            if !value.contains("?") { value = value.trimmingCharacters(in: CharacterSet(charactersIn: ".,;!)]}»”’")) }
            return value
        }
        guard !values.isEmpty else { throw NativeError("Pega al menos un enlace HTTPS completo.") }
        guard values.count <= 30 else { throw NativeError("Añade como máximo 30 enlaces por envío.") }
        var seen = Set<String>()
        return try values.map { try validated($0) }.filter { seen.insert($0.absoluteString).inserted }
    }
}
