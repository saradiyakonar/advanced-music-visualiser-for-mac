import Foundation

public enum ArtworkSource: Equatable, Sendable {
    case url(URL)
    case musicRawData
    case itunesLookup(title: String, artist: String)
    case placeholder
}

/// Where to look for a track's cover, in order. The last option is always the placeholder.
public enum ArtworkResolver {
    public static func candidates(for t: TrackInfo, hasRawData: Bool) -> [ArtworkSource] {
        switch t.app {
        case .spotify:
            return (t.artworkURL.map { [.url($0)] } ?? []) + [.placeholder]
        case .music:
            return (hasRawData ? [.musicRawData] : []) + [.itunesLookup(title: t.title, artist: t.artist), .placeholder]
        }
    }

    /// First result's artwork from an iTunes Search API response, upsized to 1000×1000.
    public static func parseITunesSearch(_ data: Data) -> URL? {
        struct Response: Decodable {
            struct Result: Decodable { let artworkUrl100: String? }
            let results: [Result]
        }
        guard let r = try? JSONDecoder().decode(Response.self, from: data),
              let s = r.results.first?.artworkUrl100 else { return nil }
        return URL(string: s.replacingOccurrences(of: "100x100", with: "1000x1000"))
    }

    public static func itunesSearchURL(title: String, artist: String) -> URL {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?")
        func enc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: allowed) ?? "" }
        let term = enc("\(artist) \(title)")
        return URL(string: "https://itunes.apple.com/search?term=\(term)&entity=song&limit=1")!
    }
}
