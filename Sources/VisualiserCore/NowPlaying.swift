import Foundation

public enum PlayerApp: String, Sendable, CaseIterable {
    case spotify, music

    public var bundleID: String {
        switch self {
        case .spotify: "com.spotify.client"
        case .music: "com.apple.Music"
        }
    }
}

public enum PlayerState: Sendable, Equatable {
    case playing, paused, stopped
}

public struct TrackInfo: Equatable, Sendable {
    public var app: PlayerApp
    public var id: String
    public var title: String
    public var artist: String
    public var album: String
    public var state: PlayerState
    public var artworkURL: URL?

    public init(app: PlayerApp, id: String, title: String, artist: String, album: String,
                state: PlayerState, artworkURL: URL?) {
        self.app = app
        self.id = id
        self.title = title
        self.artist = artist
        self.album = album
        self.state = state
        self.artworkURL = artworkURL
    }
}

/// Parses the output of the now-playing AppleScripts: fields joined by U+001F in the
/// order state, id, title, artist, album, artworkURL (empty string when missing).
public enum AppleScriptParser {
    public static let separator = "\u{1F}"

    public static func parse(_ output: String, app: PlayerApp) -> TrackInfo? {
        let f = output.components(separatedBy: separator)
        guard f.count >= 6 else { return nil }
        let state: PlayerState
        switch f[0].trimmingCharacters(in: .whitespaces).lowercased() {
        case "playing": state = .playing
        case "paused": state = .paused
        default: return nil
        }
        let title = f[2]
        guard !title.isEmpty else { return nil }
        let art = f[5].trimmingCharacters(in: .whitespacesAndNewlines)
        return TrackInfo(app: app, id: f[1], title: title, artist: f[3], album: f[4], state: state,
                         artworkURL: art.isEmpty ? nil : URL(string: art))
    }
}

extension AppleScriptParser {
    /// Fields 7 and 8: player position (seconds) and track duration
    /// (Spotify: milliseconds, Music: seconds). Duration is returned in seconds.
    public static func playback(_ output: String, app: PlayerApp) -> (position: Double, duration: Double?)? {
        let f = output.components(separatedBy: separator)
        guard f.count >= 7, let pos = number(f[6]) else { return nil }
        let raw = f.count >= 8 ? number(f[7]) : nil
        return (pos, raw.map { app == .spotify ? $0 / 1000 : $0 })
    }

    /// AppleScript formats reals with the user's locale, so "12,5" is possible.
    private static func number(_ s: String) -> Double? {
        Double(s.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: "."))
    }
}

/// Decides which player's track to show when both Spotify and Music report something:
/// the one that most recently started playing; otherwise the most recently paused one.
public final class NowPlayingArbiter {
    private struct Entry {
        var info: TrackInfo
        var playingSince: Double?
        var updatedAt: Double
    }

    private var entries: [PlayerApp: Entry] = [:]

    public init() {}

    public func update(_ info: TrackInfo?, from app: PlayerApp, at time: Double) {
        guard let info, info.state != .stopped else {
            entries[app] = nil
            return
        }
        // "Started playing" means a transition into .playing; polls and track changes
        // while already playing keep the original start time.
        let wasPlaying = entries[app]?.info.state == .playing
        let since: Double? = info.state == .playing ? (wasPlaying ? entries[app]?.playingSince : time) : nil
        entries[app] = Entry(info: info, playingSince: since, updatedAt: time)
    }

    public var current: TrackInfo? {
        let playing = entries.values.filter { $0.info.state == .playing }
        if let p = playing.max(by: { ($0.playingSince ?? 0) < ($1.playingSince ?? 0) }) { return p.info }
        return entries.values.max(by: { $0.updatedAt < $1.updatedAt })?.info
    }
}
