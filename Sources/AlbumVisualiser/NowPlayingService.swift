import AppKit
import QuartzCore
import VisualiserCore

/// Asks Spotify and Music what's playing, via their AppleScript interfaces.
///
/// Scripts only run when the player is already running, so this never launches either app.
/// Updates come from the players' distributed notifications, with a 2 s poll as backup.
final class NowPlayingService {
    var onChange: ((TrackInfo?) -> Void)?

    private let arbiter = NowPlayingArbiter()
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var scripts: [PlayerApp: NSAppleScript] = [:]
    private var lastPublished: TrackInfo?
    private var hasPublished = false

    private static let notificationNames: [PlayerApp: String] = [
        .spotify: "com.spotify.client.PlaybackStateChanged",
        .music: "com.apple.Music.playerInfo",
    ]

    private static func source(for app: PlayerApp) -> String {
        let sep = "(ASCII character 31)"
        switch app {
        case .spotify:
            return """
            tell application id "com.spotify.client"
                set s to player state as string
                if s is "stopped" then return "stopped"
                set t to current track
                return s & \(sep) & (id of t) & \(sep) & (name of t) & \(sep) & (artist of t) & \(sep) & (album of t) & \(sep) & (artwork url of t) & \(sep) & (player position as string) & \(sep) & ((duration of t) as string)
            end tell
            """
        case .music:
            return """
            tell application id "com.apple.Music"
                set s to player state as string
                if s is "stopped" then return "stopped"
                set t to current track
                return s & \(sep) & (persistent ID of t) & \(sep) & (name of t) & \(sep) & (artist of t) & \(sep) & (album of t) & \(sep) & "" & \(sep) & (player position as string) & \(sep) & ((duration of t) as string)
            end tell
            """
        }
    }

    var current: TrackInfo? { arbiter.current }

    /// Playback position of the current track, sampled at the last refresh.
    private(set) var clock: PlaybackClock?
    /// Current track length in seconds, if the player reported it.
    private(set) var duration: Double?
    private var rawOutput: [PlayerApp: String?] = [:]

    func start() {
        // A fresh window needs the current track even if it hasn't changed since last time.
        hasPublished = false
        lastPublished = nil
        let center = DistributedNotificationCenter.default()
        for (_, name) in Self.notificationNames {
            observers.append(center.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
                self?.refresh()
            })
        }
        let ws = NSWorkspace.shared.notificationCenter
        for n in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(ws.addObserver(forName: n, object: nil, queue: .main) { [weak self] _ in self?.refresh() })
        }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
        refresh()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        observers.forEach {
            DistributedNotificationCenter.default().removeObserver($0)
            NSWorkspace.shared.notificationCenter.removeObserver($0)
        }
        observers.removeAll()
    }

    enum Command {
        case playPause, next, previous
        var verb: String {
            switch self {
            case .playPause: "playpause"
            case .next: "next track"
            case .previous: "previous track"
            }
        }
    }

    /// Sends a playback command to the player in use (or whichever is running), off the
    /// main thread, then refreshes so the visual follows the change.
    func send(_ command: Command) {
        let preferred = arbiter.current?.app
        guard let app = preferred.flatMap({ Self.isRunning($0) ? $0 : nil }) ?? PlayerApp.allCases.first(where: Self.isRunning)
        else { return }
        scriptQueue.async { [weak self] in
            var error: NSDictionary?
            NSAppleScript(source: "tell application id \"\(app.bundleID)\" to \(command.verb)")?.executeAndReturnError(&error)
            if let error { Log.write("\(app.rawValue) command \(command.verb) failed: \(error)") }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self?.refresh() }
        }
    }

    static func isRunning(_ app: PlayerApp) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID).isEmpty
    }

    /// AppleScript calls to Spotify take ~250 ms, so they run on their own queue;
    /// results are applied on the main queue. Overlapping refreshes are skipped.
    private let scriptQueue = DispatchQueue(label: "album-visualiser.applescript", qos: .userInitiated)
    private var refreshing = false

    func refresh() {
        guard !refreshing else { return }
        refreshing = true
        let running = PlayerApp.allCases.filter(Self.isRunning)
        scriptQueue.async { [weak self] in
            guard let self else { return }
            var results: [(PlayerApp, TrackInfo?, String?, Double)] = []
            for app in PlayerApp.allCases {
                if running.contains(app) {
                    let (info, raw) = Log.timed("AppleScript \(app.rawValue)", slowerThan: 400) { self.query(app) }
                    let sample = info == nil ? nil : self.samplePosition(app)
                    results.append((app, info, raw, CACurrentMediaTime()))
                    if let sample { DispatchQueue.main.async { self.positionSamples[app] = sample } }
                } else {
                    results.append((app, nil, nil, CACurrentMediaTime()))
                }
            }
            DispatchQueue.main.async { self.apply(results) }
        }
    }

    private func apply(_ results: [(PlayerApp, TrackInfo?, String?, Double)]) {
        refreshing = false
        let now = ProcessInfo.processInfo.systemUptime
        var sampledAt: [PlayerApp: Double] = [:]
        for (app, info, raw, at) in results {
            arbiter.update(info, from: app, at: now)
            rawOutput[app] = raw
            sampledAt[app] = at
        }
        let cur = arbiter.current
        if let cur, let out = rawOutput[cur.app] ?? nil, let pb = AppleScriptParser.playback(out, app: cur.app) {
            // Prefer the precise, separately timed position sample when we have one.
            let precise = positionSamples[cur.app]
            clock = PlaybackClock(position: precise?.position ?? pb.position,
                                  hostTime: precise?.hostTime ?? sampledAt[cur.app] ?? CACurrentMediaTime(),
                                  playing: cur.state == .playing)
            duration = pb.duration
        } else {
            clock = nil
            duration = nil
        }
        if !hasPublished || cur != lastPublished {
            hasPublished = true
            lastPublished = cur
            onChange?(cur)
        }
    }

    /// Position read on its own (one Apple event, ~30–60 ms) and stamped at the midpoint
    /// of the call, which is much tighter than the end of the full ~250 ms track query.
    private var positionScripts: [PlayerApp: NSAppleScript] = [:]
    private var positionSamples: [PlayerApp: (position: Double, hostTime: Double)] = [:] // main only

    private func samplePosition(_ app: PlayerApp) -> (position: Double, hostTime: Double)? {
        let script = positionScripts[app] ?? {
            let s = NSAppleScript(source: "tell application id \"\(app.bundleID)\" to return (player position as string)")!
            positionScripts[app] = s
            return s
        }()
        var error: NSDictionary?
        let t0 = CACurrentMediaTime()
        let result = script.executeAndReturnError(&error)
        let t1 = CACurrentMediaTime()
        guard error == nil, let str = result.stringValue,
              let pos = Double(str.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")) else { return nil }
        return (pos, (t0 + t1) / 2)
    }

    /// Runs on `scriptQueue` only.
    private func query(_ app: PlayerApp) -> (TrackInfo?, String?) {
        let script = scripts[app] ?? {
            let s = NSAppleScript(source: Self.source(for: app))!
            scripts[app] = s
            return s
        }()
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            Log.write("\(app.rawValue) AppleScript error: \(error)")
            return (nil, nil)
        }
        let out = result.stringValue ?? ""
        return (AppleScriptParser.parse(out, app: app), out)
    }

    /// The current Music track's embedded artwork, if it has any. Fetched on the
    /// script queue; completion runs on that queue.
    func musicArtworkData(completion: @escaping (Data?) -> Void) {
        guard Self.isRunning(.music) else { return completion(nil) }
        scriptQueue.async { completion(Self.fetchMusicArtwork()) }
    }

    private static func fetchMusicArtwork() -> Data? {
        let s = NSAppleScript(source: """
        tell application id "com.apple.Music"
            try
                return raw data of artwork 1 of current track
            end try
        end tell
        """)
        var error: NSDictionary?
        guard let d = s?.executeAndReturnError(&error), error == nil else { return nil }
        let data = d.data
        return data.isEmpty ? nil : data
    }
}
