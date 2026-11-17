import AVFoundation
import MediaPlayer
import UIKit

@MainActor
final class NativePlayer: NSObject, AVAudioPlayerDelegate {
    var changed: (() -> Void)?
    var lookup: ((String) -> Song?)?
    var fileURL: ((Song) -> URL)?
    private var player: AVAudioPlayer?
    private var queue: [String] = []
    private var index = 0
    private(set) var currentID: String?
    var shuffled = false
    var repeatMode = "off"
    var playing: Bool { player?.isPlaying ?? false }
    var position: Double { player?.currentTime ?? 0 }
    var duration: Double { player?.duration ?? 0 }
    private var interruptionWasPlaying = false
    private var observers: [NSObjectProtocol] = []

    override init() {
        super.init()
        let commands = MPRemoteCommandCenter.shared()
        commands.playCommand.addTarget { [weak self] _ in Task { @MainActor in try? self?.resume() }; return .success }
        commands.pauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.pause() }; return .success }
        commands.nextTrackCommand.addTarget { [weak self] _ in Task { @MainActor in try? self?.next() }; return .success }
        commands.previousTrackCommand.addTarget { [weak self] _ in Task { @MainActor in try? self?.previous() }; return .success }
        commands.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            Task { @MainActor in self?.seek(event.positionTime) }; return .success
        }
        observers.append(NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] notification in
            let type = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let options = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            Task { @MainActor in
                guard let self else { return }
                if type == AVAudioSession.InterruptionType.began.rawValue { self.interruptionWasPlaying = self.playing; self.pause() }
                else if self.interruptionWasPlaying && AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume) { try? self.resume() }
            }
        })
        observers.append(NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] notification in
            let reason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            if reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue { Task { @MainActor in self?.pause() } }
        })
    }
    func play(_ id: String, ids: [String]) throws {
        let allowed = ids.filter { lookup?($0) != nil }
        guard allowed.contains(id) else { throw NativeError("La canción no está en esta cola.") }
        let nextQueue = shuffled ? [id] + allowed.filter { $0 != id }.shuffled() : allowed
        let nextIndex = nextQueue.firstIndex(of: id) ?? 0
        try start(id)
        queue = nextQueue; index = nextIndex
    }
    private func start(_ id: String) throws {
        guard let song = lookup?(id), let url = fileURL?(song) else { throw NativeError("El archivo local no está disponible.") }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default)
        try session.setActive(true)
        let next = try AVAudioPlayer(contentsOf: url)
        next.delegate = self
        next.prepareToPlay()
        guard next.play() else { throw NativeError("No se pudo reproducir el audio.") }
        player?.stop(); player = next; currentID = id
        publish()
    }
    func resume() throws {
        guard let player else { return }
        try AVAudioSession.sharedInstance().setActive(true)
        guard player.play() else { throw NativeError("No se pudo continuar la reproducción.") }
        publish()
    }
    func pause() { player?.pause(); publish() }
    func seek(_ seconds: Double) {
        guard seconds.isFinite else { return }
        player?.currentTime = min(max(seconds, 0), duration); publish()
    }
    func next(ended: Bool = false) throws {
        guard !queue.isEmpty else { return }
        if ended && repeatMode == "one" { try start(queue[index]); return }
        if index + 1 < queue.count { try start(queue[index + 1]); index += 1 }
        else if repeatMode == "all" {
            let nextQueue = shuffled ? queue.shuffled() : queue
            try start(nextQueue[0]); queue = nextQueue; index = 0
        } else { publish() }
    }
    func previous() throws {
        if position > 3 { seek(0); return }
        if index > 0 { try start(queue[index - 1]); index -= 1 }
    }
    func forget(_ id: String) {
        if currentID == id { player?.stop(); player = nil; currentID = nil }
        queue.removeAll { $0 == id }; index = currentID.flatMap { queue.firstIndex(of: $0) } ?? 0
        publish()
    }
    func publish() {
        if let id = currentID, let song = lookup?(id) {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = [
                MPMediaItemPropertyTitle: song.title, MPMediaItemPropertyArtist: song.artist.isEmpty ? "MiMedia" : song.artist,
                MPMediaItemPropertyAlbumTitle: song.album, MPMediaItemPropertyPlaybackDuration: duration,
                MPNowPlayingInfoPropertyElapsedPlaybackTime: position, MPNowPlayingInfoPropertyPlaybackRate: playing ? 1.0 : 0.0
            ]
        } else { MPNowPlayingInfoCenter.default().nowPlayingInfo = nil }
        changed?()
    }
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if flag { try? self.next(ended: true) }; self.publish()
        }
    }
}
