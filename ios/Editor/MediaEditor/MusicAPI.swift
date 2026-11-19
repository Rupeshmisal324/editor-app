import Foundation

/// Direct-from-device music search/trending, mirroring the RN reference
/// implementation (lib/views/pages/AddPosts/components/Fetchmusic.ts) byte
/// for byte on the endpoints/field-mapping — same public, keyless Apple/
/// iTunes JSON endpoints, called natively instead of over the RN bridge so
/// the native video editor's own music picker doesn't need a JS round trip.
enum MusicAPI {

  /// Apple storefronts use lowercase ISO alpha-2 country codes. Resolved
  /// on-device, no backend — same fallback as the RN reference's
  /// DEFAULT_STOREFRONT.
  private static var storefront: String {
    let code = (Locale.current as NSLocale).object(forKey: .countryCode) as? String
    guard let code, !code.isEmpty, code != "UN" else { return "in" }
    return code.lowercased()
  }

  /// A short, explicit per-request timeout — the system default (60s) let
  /// a slow/hung response leave the picker's spinner running for a very
  /// long time with no feedback, per the user's explicit "many time API
  /// not get called and get more much time" report. Trending is TWO
  /// chained requests (feed, then lookup), so worst case is now ~20s
  /// instead of up to 120s.
  private static let session: URLSession = {
    let config = URLSessionConfiguration.default
    config.timeoutIntervalForRequest = 10
    return URLSession(configuration: config)
  }()

  enum FetchError: Error {
    case network
  }

  /// Last non-empty trending list. The picker shows it instantly on open
  /// while a fresh request runs (every open hits the API). An EMPTY result
  /// is never cached — it used to be, which left the picker on "No songs
  /// found" for the rest of the session with no further API calls.
  private(set) static var cachedTrending: [MusicTrack]?

  /// Apple's chart feed can take 30 s+ to answer, while catalogue search
  /// answers in well under a second. So both start together and the
  /// picker gets whichever list arrives first; a chart that lands later
  /// still becomes the cached list for the next open.
  static func fetchTrendingWithFallback(completion: @escaping (Result<[MusicTrack], Error>) -> Void) {
    var delivered = false
    var failures = 0
    func finish(_ result: Result<[MusicTrack], Error>) {
      guard !delivered else { return }
      if case .success(let tracks) = result, !tracks.isEmpty {
        delivered = true
        completion(result)
        return
      }
      failures += 1
      if failures == 2 { delivered = true; completion(result) }
    }
    fetchTrending { result in
      if case .success(let tracks) = result, !tracks.isEmpty { cachedTrending = tracks }
      finish(result)
    }
    search(term: "top hits", cancelPrevious: false) { result in
      if case .success(let tracks) = result, !tracks.isEmpty, cachedTrending == nil { cachedTrending = tracks }
      finish(result)
    }
  }

  /// Warms the list (and the connection) as soon as an editor opens, so
  /// the picker shows songs the moment it appears.
  static func prefetchTrending() {
    guard cachedTrending == nil, !isPrefetching else { return }
    isPrefetching = true
    fetchTrendingWithFallback { _ in isPrefetching = false }
  }
  private static var isPrefetching = false

  /// 1) Apple's "most-played" RSS feed gives the chart track IDs (no
  /// previewUrl). 2) iTunes lookup resolves those IDs to full track
  /// objects with the playable 30 s previewUrl, in chart order. Short
  /// timeout, no retry (search covers for it).
  private static func fetchTrending(completion: @escaping (Result<[MusicTrack], Error>) -> Void) {
    let storefront = storefront
    guard let feedURL = URL(string: "https://rss.marketingtools.apple.com/api/v2/\(storefront)/music/most-played/50/songs.json") else {
      completion(.failure(FetchError.network))
      return
    }
    var feedRequest = URLRequest(url: feedURL)
    feedRequest.timeoutInterval = 6
    session.dataTask(with: feedRequest) { data, response, _ in
      guard
        let data,
        (response as? HTTPURLResponse)?.statusCode == 200,
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let feed = json["feed"] as? [String: Any],
        let results = feed["results"] as? [[String: Any]]
      else {
        DispatchQueue.main.async { completion(.failure(FetchError.network)) }
        return
      }
      let ids = results.compactMap { $0["id"] as? String }
      guard !ids.isEmpty,
            let lookupURL = URL(string: "https://itunes.apple.com/lookup?id=\(ids.joined(separator: ","))&country=\(storefront)&entity=song")
      else {
        DispatchQueue.main.async { completion(.failure(FetchError.network)) }
        return
      }
      let orderById = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, $0) })
      session.dataTask(with: lookupURL) { data, response, _ in
        guard let data, (response as? HTTPURLResponse)?.statusCode == 200 else {
          DispatchQueue.main.async { completion(.failure(FetchError.network)) }
          return
        }
        let tracks = parseTracks(from: data, statusCode: (response as? HTTPURLResponse)?.statusCode)
          .sorted { (orderById[$0.id] ?? Int.max) < (orderById[$1.id] ?? Int.max) }
        DispatchQueue.main.async { completion(.success(tracks)) }
      }.resume()
    }.resume()
  }

  /// Results by search term (this session) — retyping / backspacing to an
  /// earlier term shows its songs instantly.
  private static var searchCache: [String: [MusicTrack]] = [:]
  private static var searchTask: URLSessionDataTask?

  /// Search the iTunes catalogue directly, scoped to the user's storefront.
  /// A newer search cancels the one still in flight (the picker only
  /// shows the latest term anyway).
  static func search(term: String, cancelPrevious: Bool = true, completion: @escaping (Result<[MusicTrack], Error>) -> Void) {
    let key = term.lowercased()
    if let cached = searchCache[key] {
      completion(.success(cached))
      return
    }
    let storefront = storefront
    guard
      let encoded = term.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
      let url = URL(string: "https://itunes.apple.com/search?term=\(encoded)&media=music&entity=song&country=\(storefront)&limit=50")
    else {
      completion(.failure(FetchError.network))
      return
    }
    let task = session.dataTask(with: url) { data, response, error in
      if (error as NSError?)?.code == NSURLErrorCancelled { return }
      guard let data, (response as? HTTPURLResponse)?.statusCode == 200 else {
        DispatchQueue.main.async { completion(.failure(FetchError.network)) }
        return
      }
      let tracks = parseTracks(from: data, statusCode: (response as? HTTPURLResponse)?.statusCode)
      DispatchQueue.main.async {
        if !tracks.isEmpty {
          if searchCache.count > 40 { searchCache.removeAll() }
          searchCache[key] = tracks
        }
        completion(.success(tracks))
      }
    }
    if cancelPrevious {
      searchTask?.cancel()
      searchTask = task
    }
    task.resume()
  }

  /// Shared response parsing for both the lookup and search endpoints —
  /// both return `{ results: [...] }` with the same iTunes track shape.
  /// Tracks with no playable previewUrl are dropped (MusicTrack.audioURL
  /// is non-optional, same as the RN reference silently getting an empty
  /// string it never plays).
  private static func parseTracks(from data: Data?, statusCode: Int?) -> [MusicTrack] {
    guard
      let data, statusCode == 200,
      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let results = json["results"] as? [[String: Any]]
    else { return [] }
    return results.compactMap { (item: [String: Any]) -> MusicTrack? in
      guard
        let trackId = item["trackId"],
        (item["wrapperType"] as? String) == "track" || (item["kind"] as? String) == "song",
        let previewUrlString = item["previewUrl"] as? String,
        let audioURL = URL(string: previewUrlString)
      else { return nil }
      let artwork = (item["artworkUrl100"] as? String) ?? (item["artworkUrl60"] as? String) ?? ""
      let durationMs = (item["trackTimeMillis"] as? NSNumber)?.doubleValue ?? 0
      return MusicTrack(
        id: "\(trackId)",
        title: (item["trackName"] as? String) ?? "Unknown Track",
        artist: (item["artistName"] as? String) ?? "Unknown Artist",
        albumArt: artwork,
        audioURL: audioURL,
        durationSeconds: durationMs / 1000
      )
    }
  }
}
