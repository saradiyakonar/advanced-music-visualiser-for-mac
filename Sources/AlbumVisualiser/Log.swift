import Foundation
import QuartzCore

/// Appends timestamped lines to ~/Library/Logs/AlbumVisualiser.log (kept small).
enum Log {
    private static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/AlbumVisualiser.log")
    private static let queue = DispatchQueue(label: "album-visualiser.log")
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static func write(_ message: String) {
        let line = "\(formatter.string(from: Date())) \(message)\n"
        queue.async {
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile()
                h.write(Data(line.utf8))
                if h.offsetInFile > 2_000_000 { h.truncateFile(atOffset: 0) }
                try? h.close()
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
    }

    /// Runs `work`, logging how long it took if it was slow.
    @discardableResult
    static func timed<T>(_ what: String, slowerThan ms: Double = 30, _ work: () throws -> T) rethrows -> T {
        let t0 = CACurrentMediaTime()
        defer {
            let dt = (CACurrentMediaTime() - t0) * 1000
            if dt > ms { write(String(format: "SLOW %@: %.0f ms", what, dt)) }
        }
        return try work()
    }
}

/// Logs whenever the main thread stops responding for more than `threshold` seconds.
final class MainThreadWatchdog {
    private let threshold: Double
    private var lastPing = CACurrentMediaTime()
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    private var reported = false

    init(threshold: Double = 0.1) {
        self.threshold = threshold
    }

    func start() {
        Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.lock.lock()
            let now = CACurrentMediaTime()
            if self.reported {
                Log.write(String(format: "main thread recovered after %.0f ms", (now - self.lastPing) * 1000))
                self.reported = false
            }
            self.lastPing = now
            self.lock.unlock()
        }
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        t.schedule(deadline: .now() + 1, repeating: 0.05)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            self.lock.lock()
            defer { self.lock.unlock() }
            let stalled = CACurrentMediaTime() - self.lastPing
            if stalled > self.threshold, !self.reported {
                self.reported = true
                Log.write(String(format: "MAIN THREAD STALLED (%.0f ms so far)", stalled * 1000))
            }
        }
        t.resume()
        timer = t
    }
}
