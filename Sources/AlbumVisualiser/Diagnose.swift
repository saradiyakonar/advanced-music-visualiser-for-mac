import AppKit
import VisualiserCore

/// `AlbumVisualiser --diagnose`: prints what's playing, the output device, and detected
/// beats for 10 seconds, then exits. Useful for checking permissions and beat sync.
enum Diagnose {
    static func run(seconds: Double = 10) {
        setvbuf(stdout, nil, _IOLBF, 0)
        let nowPlaying = NowPlayingService()
        nowPlaying.refresh()
        let track = nowPlaying.current
        if let t = track {
            print("track: \(t.title) — \(t.artist) [\(t.app.rawValue), \(t.state)] art=\(t.artworkURL?.absoluteString ?? "none")")
        } else {
            print("track: none")
        }

        if let o = OutputLatency.current() {
            print(String(format: "output: %@ (%@) bluetooth=%@ reported=%.0f ms", o.name, o.uid, o.isBluetooth ? "yes" : "no",
                         o.reportedLatency * 1000))
        } else {
            print("output: none")
        }

        let tap = AudioTapCapture()
        if CommandLine.arguments.contains("--tap-only"), let t = track {
            let t0 = Date()
            do {
                try tap.start(bundleID: t.app.bundleID) { _, _ in }
                print(String(format: "tap: started in %.0f ms", Date().timeIntervalSince(t0) * 1000))
            } catch {
                print(String(format: "tap: %@ after %.0f ms", "\(error)", Date().timeIntervalSince(t0) * 1000))
            }
            tap.stop()
            exit(0)
        }
        if let t = track, t.state == .playing {
            var detector: BeatDetector?
            var rmsSum: Double = 0
            var rmsCount = 0
            let lock = NSLock()
            do {
                try tap.start(bundleID: t.app.bundleID) { buf, time in
                    lock.lock(); defer { lock.unlock() }
                    if detector == nil { detector = BeatDetector(sampleRate: tap.sampleRate) }
                    var sq: Float = 0
                    for s in buf { sq += s * s }
                    rmsSum += Double((sq / Float(max(buf.count, 1))).squareRoot())
                    rmsCount += 1
                    for e in detector!.process(buf, startTime: time) {
                        print(String(format: "beat t=%.3f strength=%.2f%@", e.time, e.strength, e.isBigHit ? " BIG" : ""))
                    }
                }
                print(String(format: "tap: started on %@ at %.0f Hz", t.app.bundleID, tap.sampleRate))
            } catch {
                print("tap: \(error)")
            }
            RunLoop.main.run(until: Date().addingTimeInterval(seconds))
            lock.lock()
            print(String(format: "tap: mean rms %.4f over %d buffers", rmsCount > 0 ? rmsSum / Double(rmsCount) : 0, rmsCount))
            lock.unlock()
            tap.stop()
        } else {
            print("tap: skipped (nothing playing)")
        }
        exit(0)
    }
}
