#if !APPSTORE
import Foundation

// MARK: - Model

struct YTChannel: Equatable {
    let id: String
    let title: String
    let thumbnail: URL?
    let subscribers: Int
    let views: Int
    let videos: Int
    let uploadsPlaylist: String
}

struct YTVideoStat: Identifiable, Equatable {
    let id: String
    let title: String
    let published: Date
    let seconds: Int
    let views: Int
    let likes: Int
    let comments: Int
    let thumbnail: URL?
    var isShort: Bool { seconds > 0 && seconds <= 180 }
    var url: URL { URL(string: isShort ? "https://www.youtube.com/shorts/\(id)" : "https://www.youtube.com/watch?v=\(id)")! }
    /// Likes and comments per 100 views.
    var engagement: Double { views > 0 ? Double(likes + comments) / Double(views) * 100 : 0 }
}

struct YTDay: Identifiable, Equatable {
    var id: Date { date }
    let date: Date
    let views: Int
    let minutes: Int
    let subscribersGained: Int
    let subscribersLost: Int
}

struct YTSlice: Identifiable, Equatable {
    var id: String { label }
    let label: String
    let value: Double
}

struct YTTopVideo: Identifiable, Equatable {
    let id: String
    let views: Int
    let minutes: Int
    let averageViewPercentage: Double
    let subscribersGained: Int
}

struct YTAnalytics: Equatable {
    var days: Int
    var daily: [YTDay] = []
    var traffic: [YTSlice] = []
    var countries: [YTSlice] = []
    var ageGender: [YTSlice] = []
    var topVideos: [YTTopVideo] = []
    var averageViewDuration: Double = 0
    var averageViewPercentage: Double = 0
    var revenue: Double?

    var views: Int { daily.reduce(0) { $0 + $1.views } }
    var minutes: Int { daily.reduce(0) { $0 + $1.minutes } }
    var netSubscribers: Int { daily.reduce(0) { $0 + $1.subscribersGained - $1.subscribersLost } }
}

// MARK: - API

/// The YouTube Data API v3 and the YouTube Analytics API v2, for the signed-in channel.
enum YouTubeAPI {
    static func channel() async throws -> YTChannel {
        let json = try await get("https://www.googleapis.com/youtube/v3/channels",
                                 ["part": "snippet,statistics,contentDetails", "mine": "true"])
        guard let item = (json["items"] as? [[String: Any]])?.first else {
            throw YouTubeAPIError.message("This Google account has no YouTube channel. Sign in with the account that owns the channel.")
        }
        let snippet = item["snippet"] as? [String: Any] ?? [:]
        let stats = item["statistics"] as? [String: Any] ?? [:]
        let uploads = ((item["contentDetails"] as? [String: Any])?["relatedPlaylists"] as? [String: Any])?["uploads"] as? String ?? ""
        return YTChannel(id: item["id"] as? String ?? "",
                         title: snippet["title"] as? String ?? "",
                         thumbnail: thumb(snippet),
                         subscribers: int(stats["subscriberCount"]),
                         views: int(stats["viewCount"]),
                         videos: int(stats["videoCount"]),
                         uploadsPlaylist: uploads)
    }

    /// The latest `limit` uploads with their statistics, newest first.
    static func videos(playlist: String, limit: Int = 100) async throws -> [YTVideoStat] {
        var ids: [String] = []
        var page: String?
        repeat {
            var q = ["part": "contentDetails", "playlistId": playlist, "maxResults": "50"]
            if let page { q["pageToken"] = page }
            let json = try await get("https://www.googleapis.com/youtube/v3/playlistItems", q)
            ids += (json["items"] as? [[String: Any]] ?? []).compactMap {
                ($0["contentDetails"] as? [String: Any])?["videoId"] as? String
            }
            page = json["nextPageToken"] as? String
        } while page != nil && ids.count < limit
        return try await stats(ids: Array(ids.prefix(limit))).sorted { $0.published > $1.published }
    }

    /// Statistics for any videos of the channel, 50 per request.
    static func stats(ids: [String]) async throws -> [YTVideoStat] {
        var out: [YTVideoStat] = []
        for batch in stride(from: 0, to: ids.count, by: 50).map({ Array(ids[$0..<min($0 + 50, ids.count)]) }) {
            let json = try await get("https://www.googleapis.com/youtube/v3/videos",
                                     ["part": "snippet,statistics,contentDetails", "id": batch.joined(separator: ",")])
            for item in json["items"] as? [[String: Any]] ?? [] {
                let sn = item["snippet"] as? [String: Any] ?? [:]
                let st = item["statistics"] as? [String: Any] ?? [:]
                let cd = item["contentDetails"] as? [String: Any] ?? [:]
                out.append(YTVideoStat(id: item["id"] as? String ?? "",
                                       title: sn["title"] as? String ?? "",
                                       published: iso.date(from: sn["publishedAt"] as? String ?? "") ?? .distantPast,
                                       seconds: duration(cd["duration"] as? String ?? ""),
                                       views: int(st["viewCount"]),
                                       likes: int(st["likeCount"]),
                                       comments: int(st["commentCount"]),
                                       thumbnail: thumb(sn)))
            }
        }
        return out
    }

    /// Channel analytics over the last `days` days (YouTube's numbers lag by about two days).
    static func analytics(days: Int) async throws -> YTAnalytics {
        let end = Date()
        let start = Calendar.current.date(byAdding: .day, value: -days, to: end) ?? end
        var a = YTAnalytics(days: days)

        let daily = try await report(start, end, metrics: "views,estimatedMinutesWatched,subscribersGained,subscribersLost",
                                     dimensions: "day", sort: "day")
        a.daily = daily.compactMap { r in
            guard let d = day.date(from: r[0] as? String ?? "") else { return nil }
            return YTDay(date: d, views: int(r[1]), minutes: int(r[2]), subscribersGained: int(r[3]), subscribersLost: int(r[4]))
        }
        if let totals = try? await report(start, end, metrics: "averageViewDuration,averageViewPercentage").first {
            a.averageViewDuration = dbl(totals[0])
            a.averageViewPercentage = dbl(totals[1])
        }
        a.traffic = (try? await report(start, end, metrics: "views", dimensions: "insightTrafficSourceType", sort: "-views"))?
            .map { YTSlice(label: trafficName($0[0] as? String ?? ""), value: dbl($0[1])) } ?? []
        a.countries = (try? await report(start, end, metrics: "views", dimensions: "country", sort: "-views", max: 8))?
            .map { YTSlice(label: Locale.current.localizedString(forRegionCode: $0[0] as? String ?? "") ?? ($0[0] as? String ?? ""),
                           value: dbl($0[1])) } ?? []
        a.ageGender = (try? await report(start, end, metrics: "viewerPercentage", dimensions: "ageGroup,gender"))?
            .map { YTSlice(label: "\(($0[0] as? String ?? "").replacingOccurrences(of: "age", with: "").replacingOccurrences(of: "-", with: "–")) · \(($0[1] as? String ?? "") == "female" ? "Women" : "Men")",
                           value: dbl($0[2])) } ?? []
        a.topVideos = (try? await report(start, end, metrics: "views,estimatedMinutesWatched,averageViewPercentage,subscribersGained",
                                         dimensions: "video", sort: "-views", max: 10))?
            .map { YTTopVideo(id: $0[0] as? String ?? "", views: int($0[1]), minutes: int($0[2]),
                              averageViewPercentage: dbl($0[3]), subscribersGained: int($0[4])) } ?? []
        // Only for monetized channels; anything else answers 403.
        if let rev = try? await report(start, end, metrics: "estimatedRevenue").first { a.revenue = dbl(rev[0]) }
        return a
    }

    // MARK: Plumbing

    private static func report(_ start: Date, _ end: Date, metrics: String, dimensions: String? = nil,
                               sort: String? = nil, max: Int? = nil) async throws -> [[Any]] {
        var q = ["ids": "channel==MINE", "startDate": day.string(from: start), "endDate": day.string(from: end), "metrics": metrics]
        if let dimensions { q["dimensions"] = dimensions }
        if let sort { q["sort"] = sort }
        if let max { q["maxResults"] = String(max) }
        let json = try await get("https://youtubeanalytics.googleapis.com/v2/reports", q)
        return json["rows"] as? [[Any]] ?? []
    }

    private static func get(_ base: String, _ query: [String: String]) async throws -> [String: Any] {
        var c = URLComponents(string: base)!
        c.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        var req = URLRequest(url: c.url!, timeoutInterval: 20)
        req.setValue("Bearer \(try await YouTubeAuth.shared.token())", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: req)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            let msg = ((json["error"] as? [String: Any])?["message"] as? String) ?? "YouTube API error"
            throw YouTubeAPIError.message(msg)
        }
        return json
    }

    private static let iso = ISO8601DateFormatter()
    private static let day: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static func int(_ v: Any?) -> Int {
        if let i = v as? Int { return i }
        if let d = v as? Double { return Int(d) }
        if let s = v as? String { return Int(s) ?? 0 }
        return 0
    }
    private static func dbl(_ v: Any?) -> Double {
        if let d = v as? Double { return d }
        if let i = v as? Int { return Double(i) }
        if let s = v as? String { return Double(s) ?? 0 }
        return 0
    }

    private static func thumb(_ snippet: [String: Any]) -> URL? {
        let t = snippet["thumbnails"] as? [String: Any] ?? [:]
        for k in ["medium", "high", "default"] {
            if let u = (t[k] as? [String: Any])?["url"] as? String { return URL(string: u) }
        }
        return nil
    }

    /// "PT1M5S" → 65.
    private static func duration(_ s: String) -> Int {
        var total = 0, n = 0
        for ch in s {
            if let d = ch.wholeNumberValue { n = n * 10 + d; continue }
            switch ch {
            case "H": total += n * 3600
            case "M": total += n * 60
            case "S": total += n
            default: break
            }
            n = 0
        }
        return total
    }

    private static func trafficName(_ s: String) -> String {
        switch s {
        case "SHORTS": return "Shorts feed"
        case "YT_SEARCH": return "YouTube search"
        case "SUBSCRIBER": return "Subscriptions"
        case "RELATED_VIDEO": return "Suggested videos"
        case "BROWSE": return "Browse / Home"
        case "EXT_URL": return "External"
        case "YT_CHANNEL": return "Channel page"
        case "NO_LINK_OTHER": return "Direct"
        case "PLAYLIST": return "Playlists"
        case "NOTIFICATION": return "Notifications"
        case "HASHTAGS": return "Hashtags"
        case "END_SCREEN": return "End screens"
        case "YT_OTHER_PAGE": return "Other YouTube pages"
        case "YT_PLAYLIST_PAGE": return "Playlist pages"
        case "SHORTS_CONTENT_LINKS": return "Links in Shorts"
        case "ADVERTISING": return "Ads"
        case "SOUND_PAGE": return "Sound pages"
        default: return s.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}
#endif
