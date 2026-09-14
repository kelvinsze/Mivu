import Foundation

/// Fetches normalized ratings exclusively from Mivu's Ratings API.
public enum UnifiedRatingsAPIClient {
    private static let cachePrefix = "mivu.unified-ratings."
    private static let cacheTTL: TimeInterval = 24 * 60 * 60

    public static func enrich(_ item: MediaItem) async -> MediaItem? {
        guard let lookup = Lookup(item: item) else { return nil }

        if let cached = cachedResponse(for: lookup) {
            return cached.applying(to: item)
        }

        guard let url = lookup.url else { return nil }
        var request = URLRequest(url: url)
        // A cold request may need both MDBList metadata and a Douban lookup.
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode),
              let ratings = try? JSONDecoder().decode(Response.self, from: data) else {
            return nil
        }

        cache(ratings, for: lookup)
        return ratings.applying(to: item)
    }

    private static var endpoint: URL? {
        let rawURL = (Bundle.main.object(forInfoDictionaryKey: "RatingsAPIBaseURL") as? String)
            ?? "https://mivu-rating-api.koldllc.com"
        return URL(string: rawURL)
    }

    private static func cachedResponse(for lookup: Lookup) -> Response? {
        guard let data = UserDefaults.standard.data(forKey: cachePrefix + lookup.cacheKey),
              let entry = try? JSONDecoder().decode(CacheEntry.self, from: data),
              entry.expiresAt > Date() else {
            return nil
        }
        return entry.response
    }

    private static func cache(_ response: Response, for lookup: Lookup) {
        let entry = CacheEntry(response: response, expiresAt: Date().addingTimeInterval(cacheTTL))
        guard let data = try? JSONEncoder().encode(entry) else { return }
        UserDefaults.standard.set(data, forKey: cachePrefix + lookup.cacheKey)
    }
}

private extension UnifiedRatingsAPIClient {
    struct Lookup {
        let imdb: String?
        let tmdb: String?
        let tvdb: String?
        let mediaType: String

        init?(item: MediaItem) {
            let ids = item.providerIds ?? [:]
            let imdb = Self.providerID(in: ids, named: "imdb")
            let tmdb = Self.providerID(in: ids, named: "tmdb")
            let tvdb = Self.providerID(in: ids, named: "tvdb")

            self.imdb = Self.isValidIMDbID(imdb) ? imdb : nil
            self.tmdb = Self.isPositiveInteger(tmdb) ? tmdb : nil
            self.tvdb = Self.isPositiveInteger(tvdb) ? tvdb : nil
            self.mediaType = tvdb == nil ? "movie" : "tv"

            guard self.imdb != nil || self.tmdb != nil || self.tvdb != nil else { return nil }
        }

        var url: URL? {
            guard let endpoint = UnifiedRatingsAPIClient.endpoint else { return nil }
            var components = URLComponents(url: endpoint.appendingPathComponent("v1/ratings"), resolvingAgainstBaseURL: false)
            var query: [URLQueryItem] = []

            if let imdb {
                query.append(URLQueryItem(name: "imdb", value: imdb))
            } else {
                if let tmdb { query.append(URLQueryItem(name: "tmdb", value: tmdb)) }
                if let tvdb { query.append(URLQueryItem(name: "tvdb", value: tvdb)) }
                query.append(URLQueryItem(name: "type", value: mediaType))
            }

            components?.queryItems = query
            return components?.url
        }

        var cacheKey: String {
            [imdb ?? "", tmdb ?? "", tvdb ?? "", mediaType].joined(separator: "-")
        }

        private static func providerID(in ids: [String: String], named name: String) -> String? {
            ids.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
        }

        private static func isValidIMDbID(_ value: String?) -> Bool {
            guard let value, value.hasPrefix("tt"), value.count > 2 else { return false }
            return value.dropFirst(2).allSatisfy(\.isNumber)
        }

        private static func isPositiveInteger(_ value: String?) -> Bool {
            guard let value, let number = Int(value), number > 0 else { return false }
            return String(number) == value
        }
    }

    struct CacheEntry: Codable {
        let response: Response
        let expiresAt: Date
    }

    struct Response: Codable {
        let media: Media
        let ids: IDs
        let ratings: Ratings

        func applying(to item: MediaItem) -> MediaItem {
            var enriched = item
            var providerIDs = item.providerIds ?? [:]

            if let imdb = ids.imdb { providerIDs["Imdb"] = imdb }
            if let tmdb = ids.tmdb { providerIDs["Tmdb"] = String(tmdb) }
            if let tvdb = ids.tvdb { providerIDs["Tvdb"] = String(tvdb) }
            if let douban = ids.douban { providerIDs["Douban"] = douban }

            enriched.providerIds = providerIDs.isEmpty ? nil : providerIDs
            enriched.imdbRating = ratings.imdb?.score ?? enriched.imdbRating
            enriched.doubanRating = ratings.douban?.score ?? enriched.doubanRating
            enriched.rottenTomatoesRating = ratings.rottenTomatoes?.critics ?? enriched.rottenTomatoesRating
            enriched.year = enriched.year ?? media.year
            return enriched
        }
    }

    struct Media: Codable {
        let year: Int?
    }

    struct IDs: Codable {
        let imdb: String?
        let tmdb: Int?
        let tvdb: Int?
        let douban: String?
    }

    struct Ratings: Codable {
        let imdb: Score?
        let rottenTomatoes: RottenTomatoes?
        let douban: Douban?
    }

    struct Score: Codable {
        let score: Double
    }

    struct RottenTomatoes: Codable {
        let critics: Double?
    }

    struct Douban: Codable {
        let score: Double?
    }
}
