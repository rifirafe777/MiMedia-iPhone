import AVFoundation
import CryptoKit
import Foundation
import UIKit

private final class TransferProgress: NSObject, URLSessionDownloadDelegate {
    let update: (Double?) -> Void
    private let lock = NSLock()
    private var exceeded = false
    var tooLarge: Bool { lock.lock(); defer { lock.unlock() }; return exceeded }
    init(update: @escaping (Double?) -> Void) { self.update = update }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if max(totalBytesWritten, totalBytesExpectedToWrite) > 150 * 1024 * 1024 {
            lock.lock(); exceeded = true; lock.unlock(); downloadTask.cancel(); return
        }
        update(totalBytesExpectedToWrite > 0 ? min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)) : nil)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url?.scheme?.lowercased() == "https" ? request : nil)
    }
}

@MainActor
final class NativeLibrary {
    private(set) var catalog = Catalog()
    private(set) var loadError: String?
    let player = NativePlayer()
    var changed: (() -> Void)?
    private let root: URL
    private var catalogURL: URL { root.appendingPathComponent("catalog.json") }
    private var files: URL { root.appendingPathComponent("Music", isDirectory: true) }
    private var pump: Task<Void, Never>?
    private var transfer: Task<Void, Error>?
    private var activeID: String?
    private var lastProgress: TimeInterval = 0

    init() {
        root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("MiMedia", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: catalogURL.path) {
                catalog = try JSONDecoder().decode(Catalog.self, from: Data(contentsOf: catalogURL))
                for index in catalog.jobs.indices where ["downloading", "verifying", "saving"].contains(catalog.jobs[index].state) {
                    catalog.jobs[index].state = "interrupted"
                    catalog.jobs[index].detail = "iOS interrumpió el proceso. Confirma autorización y reintenta."
                }
                try persist(catalog)
            }
        } catch { loadError = "No se pudo abrir la biblioteca. Sus archivos se conservan: \(error.localizedDescription)" }
        player.lookup = { [weak self] id in self?.catalog.songs.first { $0.id == id } }
        player.fileURL = { [weak self] song in self?.file(song) ?? URL(fileURLWithPath: "/unavailable") }
        player.shuffled = catalog.shuffled; player.repeatMode = catalog.repeatMode
        player.changed = { [weak self] in self?.changed?() }
    }
    private func persist(_ value: Catalog) throws {
        let data = try JSONEncoder().encode(value)
        try data.write(to: catalogURL, options: .atomic)
    }
    private func commit(_ value: Catalog) throws { try persist(value); catalog = value; changed?() }
    func file(_ song: Song) -> URL {
        // Catalog filenames are generated here, never supplied as arbitrary paths by JavaScript.
        files.appendingPathComponent((song.filename as NSString).lastPathComponent)
    }
    private func job(_ id: String, state: String, detail: String = "", progress: Double? = nil) throws {
        var updated = catalog
        guard let index = updated.jobs.firstIndex(where: { $0.id == id }), updated.jobs[index].state != "cancelled" else { return }
        updated.jobs[index].state = state; updated.jobs[index].detail = detail; updated.jobs[index].progress = progress
        try commit(updated)
    }
    private func startQueue() {
        guard loadError == nil, pump == nil else { return }
        pump = Task { [weak self] in
            guard let self else { return }
            defer { self.pump = nil; self.activeID = nil; self.transfer = nil }
            while let pending = self.catalog.jobs.first(where: { $0.state == "queued" }) {
                self.activeID = pending.id
                let task = Task { try await self.download(pending) }
                self.transfer = task
                do { try await task.value }
                catch {
                    if self.catalog.jobs.first(where: { $0.id == pending.id })?.state != "cancelled" {
                        try? self.job(pending.id, state: "failed", detail: "No descargada: \(error.localizedDescription)")
                    }
                }
                self.transfer = nil; self.activeID = nil
            }
        }
    }
    private func download(_ pending: DownloadJob) async throws {
        let url = try AudioLinks.validated(pending.url)
        guard !AudioLinks.youtube.contains(url.host?.lowercased() ?? "") else { throw NativeError("Motor YouTube pendiente.") }
        try job(pending.id, state: "downloading", detail: "Descargando audio…")
        let observer = TransferProgress { [weak self] fraction in
            Task { @MainActor in
                guard let self, Date().timeIntervalSince1970 - self.lastProgress >= 0.7,
                      let index = self.catalog.jobs.firstIndex(where: { $0.id == pending.id }), self.catalog.jobs[index].state == "downloading" else { return }
                self.lastProgress = Date().timeIntervalSince1970
                self.catalog.jobs[index].progress = fraction
                self.changed?() // Progress is transient; durable state was saved before transfer.
            }
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 45
        let temporary: URL, response: URLResponse
        do { (temporary, response) = try await URLSession.shared.download(for: request, delegate: observer) }
        catch { if observer.tooLarge { throw NativeError("El archivo supera el límite de 150 MB.") }; throw error }
        defer { try? FileManager.default.removeItem(at: temporary) }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), http.statusCode != 206,
              http.value(forHTTPHeaderField: "Content-Range") == nil, response.url?.scheme == "https" else { throw NativeError("El servidor no devolvió un archivo HTTPS completo.") }
        let mime = (response.mimeType ?? "").lowercased()
        let ext = (response.url ?? url).pathExtension.lowercased()
        guard !["audio/x-mpegurl", "audio/mpegurl", "audio/x-scpls"].contains(mime),
              mime.hasPrefix("audio/") || ((mime.isEmpty || mime == "application/octet-stream") && AudioLinks.extensions.contains(ext)) else {
            throw NativeError("El enlace no devuelve un archivo de audio directo compatible.")
        }
        let size = (try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size > 0 && size <= 150 * 1024 * 1024 else { throw NativeError("Archivo vacío o mayor de 150 MB.") }
        try job(pending.id, state: "verifying", detail: "Verificando el archivo local…")
        let probe = try AVAudioPlayer(contentsOf: temporary)
        guard probe.duration.isFinite && probe.duration > 0 else { throw NativeError("No hay audio reproducible en el archivo.") }
        let duration = probe.duration
        let hash = try await Task.detached(priority: .utility) {
            let handle = try FileHandle(forReadingFrom: temporary)
            defer { try? handle.close() }
            var digest = SHA256()
            while let data = try handle.read(upToCount: 65536), !data.isEmpty { digest.update(data: data) }
            return digest.finalize().map { String(format: "%02x", $0) }.joined()
        }.value
        try Task.checkCancellation()
        var updated = catalog
        guard let index = updated.jobs.firstIndex(where: { $0.id == pending.id }), updated.jobs[index].state != "cancelled" else { throw CancellationError() }
        if let duplicate = updated.songs.first(where: { $0.hash == hash && FileManager.default.fileExists(atPath: file($0).path) }) {
            updated.jobs[index].state = "completed"; updated.jobs[index].songID = duplicate.id
            updated.jobs[index].detail = "El mismo audio ya estaba guardado. No se creó otra copia."
            try commit(updated); return
        }
        let filename = UUID().uuidString + "." + (AudioLinks.extensions.contains(ext) ? ext : "audio")
        let destination = files.appendingPathComponent(filename)
        var published = false
        defer { if !published { try? FileManager.default.removeItem(at: destination) } }
        try FileManager.default.moveItem(at: temporary, to: destination)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: destination.path)
        let song = Song(title: pending.title, filename: filename, source: pending.url, hash: hash, size: Int64(size), duration: duration)
        updated.songs.append(song)
        updated.jobs[index].state = "completed"; updated.jobs[index].songID = song.id
        updated.jobs[index].detail = "Archivo completo guardado en el iPhone."; updated.jobs[index].progress = nil
        try commit(updated); published = true
    }
    private func string(_ args: [String: Any], _ name: String) throws -> String {
        guard let value = args[name] as? String, !value.isEmpty else { throw NativeError("Falta \(name).") }; return value
    }
    func perform(_ method: String, args: [String: Any]) throws {
        if let loadError { throw NativeError(loadError) }
        switch method {
        case "addTestAudio":
            guard let bundled = Bundle.main.url(forResource: "prueba-mimedia", withExtension: "wav") else { throw NativeError("No se incluyó el tono de prueba en el paquete.") }
            let bytes = try Data(contentsOf: bundled)
            let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            if catalog.songs.contains(where: { $0.hash == hash && FileManager.default.fileExists(atPath: file($0).path) }) { return }
            let probe = try AVAudioPlayer(contentsOf: bundled)
            let name = UUID().uuidString + ".wav", destination = files.appendingPathComponent(name)
            try FileManager.default.copyItem(at: bundled, to: destination)
            var confirmed = false
            defer { if !confirmed { try? FileManager.default.removeItem(at: destination) } }
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: destination.path)
            var updated = catalog
            updated.songs.append(Song(title: "Tono de prueba local (no descargado)", filename: name, source: "app://prueba-mimedia.wav", hash: hash, size: Int64(bytes.count), duration: probe.duration))
            try commit(updated); confirmed = true
        case "enqueue":
            guard args["authorized"] as? Bool == true else { throw NativeError("Confirma la autorización antes de descargar.") }
            let urls = try AudioLinks.extract(try string(args, "text"))
            var updated = catalog
            for url in urls {
                let value = url.absoluteString
                if updated.songs.contains(where: { $0.source == value && FileManager.default.fileExists(atPath: file($0).path) }) || updated.jobs.contains(where: { $0.url == value && ["queued", "downloading", "verifying", "unsupported"].contains($0.state) }) { continue }
                var next = DownloadJob(url: value, title: url.deletingPathExtension().lastPathComponent.removingPercentEncoding ?? "Audio personal")
                if next.title.isEmpty { next.title = "Audio personal" }
                if AudioLinks.youtube.contains(url.host?.lowercased() ?? "") { next.title = "Enlace YouTube"; next.state = "unsupported"; next.detail = "Motor pendiente. La autorización no elimina las restricciones de YouTube." }
                updated.jobs.append(next)
            }
            try commit(updated); startQueue()
        case "continue": startQueue()
        case "cancel":
            let id = try string(args, "id"); var updated = catalog
            if let index = updated.jobs.firstIndex(where: { $0.id == id }), ["queued", "downloading", "verifying"].contains(updated.jobs[index].state) {
                updated.jobs[index].state = "cancelled"; updated.jobs[index].detail = "Cancelada por el usuario."
                try commit(updated); if activeID == id { transfer?.cancel() }
            }
        case "retry":
            guard args["authorized"] as? Bool == true else { throw NativeError("Marca de nuevo la autorización para reintentar.") }
            let id = try string(args, "id"); var updated = catalog
            if let index = updated.jobs.firstIndex(where: { $0.id == id }), ["failed", "cancelled", "interrupted", "removed"].contains(updated.jobs[index].state) {
                updated.jobs[index].state = "queued"; updated.jobs[index].detail = ""; updated.jobs[index].authorizedAt = Date().timeIntervalSince1970
                try commit(updated); startQueue()
            }
        case "play":
            let id = try string(args, "id"); try player.play(id, ids: args["queue"] as? [String] ?? catalog.songs.map(\.id))
        case "pause": player.pause()
        case "resume": try player.resume()
        case "next": try player.next()
        case "previous": try player.previous()
        case "seek": player.seek(args["seconds"] as? Double ?? 0)
        case "preferences":
            var updated = catalog; updated.shuffled = args["shuffled"] as? Bool ?? updated.shuffled
            let mode = args["repeatMode"] as? String ?? updated.repeatMode
            guard ["off", "one", "all"].contains(mode) else { throw NativeError("Modo de repetición inválido.") }
            updated.repeatMode = mode; try commit(updated); player.shuffled = updated.shuffled; player.repeatMode = mode
        case "favorite", "edit":
            let id = try string(args, "id"); var updated = catalog
            guard let index = updated.songs.firstIndex(where: { $0.id == id }) else { throw NativeError("La canción ya no está en la biblioteca.") }
            if method == "favorite" { updated.songs[index].favorite.toggle() }
            else {
                let title = try string(args, "title").trimmingCharacters(in: .whitespacesAndNewlines)
                let artist = args["artist"] as? String ?? "", album = args["album"] as? String ?? "", year = args["year"] as? String ?? ""
                guard !title.isEmpty, title.count <= 150, artist.count <= 150, album.count <= 150, year.isEmpty || year.range(of: "^[0-9]{4}$", options: .regularExpression) != nil else { throw NativeError("Revisa título, artista, álbum y año.") }
                updated.songs[index].title = title; updated.songs[index].artist = artist; updated.songs[index].album = album; updated.songs[index].year = year
                if let image = args["artwork"] as? String {
                    guard image.hasPrefix("data:image/jpeg;base64,"), let data = Data(base64Encoded: String(image.dropFirst("data:image/jpeg;base64,".count))), data.count <= 512000, UIImage(data: data) != nil else { throw NativeError("Carátula no válida.") }
                    updated.songs[index].artwork = image
                } else if args["removeArtwork"] as? Bool == true { updated.songs[index].artwork = nil }
            }
            try commit(updated); player.publish()
        case "playlist.create":
            let name = try string(args, "name").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty && name.count <= 80 else { throw NativeError("Escribe un nombre de 1 a 80 caracteres.") }
            var updated = catalog; updated.playlists.append(Playlist(name: name)); try commit(updated)
        case "playlist.rename", "playlist.delete", "playlist.songs":
            let id = try string(args, "id"); var updated = catalog
            guard let index = updated.playlists.firstIndex(where: { $0.id == id }) else { throw NativeError("La playlist ya no existe.") }
            if method == "playlist.delete" { updated.playlists.remove(at: index) }
            else if method == "playlist.rename" {
                let name = try string(args, "name").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty && name.count <= 80 else { throw NativeError("Nombre de playlist inválido.") }; updated.playlists[index].name = name
            } else {
                var seen = Set<String>(); let known = Set(updated.songs.map(\.id))
                updated.playlists[index].songIDs = (args["songIDs"] as? [String] ?? []).filter { known.contains($0) && seen.insert($0).inserted }
            }
            try commit(updated)
        case "deleteSong":
            let id = try string(args, "id"); var updated = catalog
            guard let song = updated.songs.first(where: { $0.id == id }) else { return }
            updated.songs.removeAll { $0.id == id }
            for index in updated.playlists.indices { updated.playlists[index].songIDs.removeAll { $0 == id } }
            for index in updated.jobs.indices where updated.jobs[index].songID == id { updated.jobs[index].state = "removed"; updated.jobs[index].detail = "Archivo eliminado de este iPhone." }
            try commit(updated); player.forget(id); try? FileManager.default.removeItem(at: file(song))
        default: throw NativeError("Operación no admitida.")
        }
    }
    func snapshot() -> [String: Any] {
        let encoded = (try? JSONEncoder().encode(catalog)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        return encoded.merging(["currentID": player.currentID.map { $0 as Any } ?? NSNull(), "playing": player.playing, "position": player.position, "duration": player.duration, "loadError": loadError.map { $0 as Any } ?? NSNull()]) { _, next in next }
    }
}
