import CoreGraphics
import Foundation
import ImageIO
import VisualiserCore

/// Fetches a track's cover by walking ArtworkResolver's candidates in order.
/// Completion runs on the main queue with nil meaning "use the placeholder".
final class ArtworkLoader {
    private var cache: [String: CGImage] = [:]
    private let session: URLSession
    private let musicRawData: (@escaping (Data?) -> Void) -> Void

    init(musicRawData: @escaping (@escaping (Data?) -> Void) -> Void) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 5
        session = URLSession(configuration: config)
        self.musicRawData = musicRawData
    }

    func load(for track: TrackInfo, completion: @escaping (CGImage?) -> Void) {
        if let hit = cache[track.id] { return completion(hit) }

        let go: (Data?) -> Void = { [weak self] raw in
            let candidates = ArtworkResolver.candidates(for: track, hasRawData: raw != nil)
            self?.attempt(candidates[...], raw: raw) { image in
                DispatchQueue.main.async {
                    if let image { self?.cache[track.id] = image }
                    completion(image)
                }
            }
        }
        if track.app == .music { musicRawData(go) } else { go(nil) }
    }

    private func attempt(_ rest: ArraySlice<ArtworkSource>, raw: Data?, done: @escaping (CGImage?) -> Void) {
        guard let next = rest.first else { return done(nil) }
        let tail = rest.dropFirst()
        let fallThrough: (CGImage?) -> Void = { [weak self] img in
            if let img { done(img) } else { self?.attempt(tail, raw: raw, done: done) ?? done(nil) }
        }
        switch next {
        case .placeholder:
            done(nil)
        case .musicRawData:
            fallThrough(raw.flatMap(Self.decode))
        case .url(let url):
            fetch(url) { fallThrough($0.flatMap(Self.decode)) }
        case .itunesLookup(let title, let artist):
            fetch(ArtworkResolver.itunesSearchURL(title: title, artist: artist)) { [weak self] data in
                guard let self, let data, let art = ArtworkResolver.parseITunesSearch(data) else { return fallThrough(nil) }
                self.fetch(art) { fallThrough($0.flatMap(Self.decode)) }
            }
        }
    }

    private func fetch(_ url: URL, completion: @escaping (Data?) -> Void) {
        session.dataTask(with: url) { data, response, _ in
            let ok = (response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false
            completion(ok ? data : nil)
        }.resume()
    }

    static func decode(_ data: Data) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }
}
