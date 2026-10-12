import Foundation
import VisualiserCore

/// Fetches line-timed lyrics from LRCLIB: exact lookup first, then a looser search.
/// Results (including "none") are cached per track; completion runs on the main queue.
final class LyricsService {
    private var cache: [String: LyricsTimeline?] = [:]
    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.httpAdditionalHeaders = ["User-Agent": "AlbumVisualiser/0.1 (personal macOS app)"]
        session = URLSession(configuration: config)
    }

    func cached(_ track: TrackInfo) -> LyricsTimeline?? { cache[track.id] }

    func fetch(_ track: TrackInfo, duration: Double?, completion: @escaping (LyricsTimeline?) -> Void) {
        if let hit = cache[track.id] { return completion(hit) }
        let get = LyricsClient.getURL(title: track.title, artist: track.artist, album: track.album,
                                      duration: duration.map { Int($0.rounded()) })
        load(get) { [weak self] data in
            if let lines = data.flatMap(LyricsClient.parseGet) { return self?.finish(track, lines, completion) ?? () }
            let search = LyricsClient.searchURL(title: track.title, artist: track.artist)
            self?.load(search) { data in
                self?.finish(track, data.flatMap(LyricsClient.parseSearch), completion)
            }
        }
    }

    private func finish(_ track: TrackInfo, _ lines: [LyricLine]?, _ completion: @escaping (LyricsTimeline?) -> Void) {
        let timeline = lines.map(LyricsTimeline.init(lines:))
        DispatchQueue.main.async {
            self.cache[track.id] = .some(timeline)
            completion(timeline)
        }
    }

    private func load(_ url: URL, completion: @escaping (Data?) -> Void) {
        session.dataTask(with: url) { data, response, _ in
            let ok = (response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false
            completion(ok ? data : nil)
        }.resume()
    }
}
