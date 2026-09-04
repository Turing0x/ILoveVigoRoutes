import Foundation

/// Fetches the published GTFS archive, honouring HTTP validators.
public protocol GTFSFeedDownloading: Sendable {
    /// Returns `nil` when the server answers 304, meaning the local copy is still current.
    func download(etag: String?, lastModified: String?) async throws -> DownloadedFeed?
}

public struct DownloadedFeed: Sendable {
    public let data: Data
    public let provenance: FeedProvenance
    public init(data: Data, provenance: FeedProvenance) {
        self.data = data; self.provenance = provenance
    }
}

public enum FeedDownloadError: Error, CustomStringConvertible, Sendable {
    case transport(String)
    case httpStatus(Int)
    case emptyBody

    public var description: String {
        switch self {
        case .transport(let m): "could not reach the feed: \(m)"
        case .httpStatus(let c): "the feed server answered HTTP \(c)"
        case .emptyBody: "the feed server returned an empty body"
        }
    }
}

public struct VitrasaFeedDownloader: GTFSFeedDownloading {
    public static let defaultURL = URL(string: "https://datos.vigo.org/data/transporte/gtfs_vigo.zip")!

    let url: URL
    let session: URLSession

    public init(url: URL = VitrasaFeedDownloader.defaultURL, session: URLSession? = nil) {
        self.url = url
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 60
            config.timeoutIntervalForResource = 300
            config.allowsExpensiveNetworkAccess = true
            self.session = URLSession(configuration: config)
        }
    }

    public func download(etag: String?, lastModified: String?) async throws -> DownloadedFeed? {
        var request = URLRequest(url: url)
        request.setValue(ConcelloRealtimeClient.userAgent, forHTTPHeaderField: "User-Agent")
        // The archive is 16 MB and is regenerated weekly. Asking conditionally means the
        // usual answer is a few hundred bytes of 304 rather than a fresh download.
        if let etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        if let lastModified { request.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since") }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw FeedDownloadError.transport(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else { throw FeedDownloadError.emptyBody }
        if http.statusCode == 304 { return nil }
        guard (200...299).contains(http.statusCode) else {
            throw FeedDownloadError.httpStatus(http.statusCode)
        }
        guard !data.isEmpty else { throw FeedDownloadError.emptyBody }

        return DownloadedFeed(data: data, provenance: FeedProvenance(
            etag: http.value(forHTTPHeaderField: "ETag"),
            lastModified: http.value(forHTTPHeaderField: "Last-Modified"),
            sourceURL: url))
    }
}

public enum FeedRefreshOutcome: Sendable {
    case upToDate
    case imported(ImportSummary)
    case skipped(reason: String)
}

/// Decides when to re-fetch the feed and performs the import.
///
/// The published feed only ever covers seven days, so "download it once at first launch"
/// is not a viable strategy: the data goes stale on a known schedule. This checks daily
/// by default and always checks when the imported window has run out.
public struct GTFSFeedService: Sendable {
    let downloader: any GTFSFeedDownloading
    let database: AppDatabase
    let repository: TransitRepository
    /// How long to wait between conditional checks under normal circumstances.
    let checkInterval: TimeInterval

    public init(downloader: any GTFSFeedDownloading,
                database: AppDatabase,
                repository: TransitRepository,
                checkInterval: TimeInterval = 24 * 3600) {
        self.downloader = downloader
        self.database = database
        self.repository = repository
        self.checkInterval = checkInterval
    }

    /// Whether a check is worth making right now.
    public func shouldCheck(now: Date = Date()) throws -> Bool {
        let status = try repository.feedStatus()
        guard status.importedAt != nil else { return true }             // nothing imported yet
        let lastChecked = status.lastCheckedAt ?? status.importedAt ?? .distantPast
        let today = ServiceDate(now, calendar: repository.calendar)
        // An expired or nearly expired window overrides the interval: without fresh data
        // the timetable simply stops being able to answer.
        if !status.covers(today) { return true }
        if let remaining = status.daysRemaining(from: today, calendar: repository.calendar),
           remaining <= 1 { return true }
        return now.timeIntervalSince(lastChecked) >= checkInterval
    }

    @discardableResult
    public func refreshIfNeeded(
        force: Bool = false,
        now: Date = Date(),
        progress: (@Sendable (ImportProgress) -> Void)? = nil
    ) async throws -> FeedRefreshOutcome {
        let status = try repository.feedStatus()
        if !force, try !shouldCheck(now: now) {
            return .skipped(reason: "checked recently and the current feed still covers today")
        }

        progress?(ImportProgress(stage: .downloading, fraction: 0))
        // On a forced refresh the validators are deliberately dropped, so the user gets a
        // real download rather than a 304 they cannot see.
        let downloaded = try await downloader.download(
            etag: force ? nil : status.etag,
            lastModified: force ? nil : status.lastModified)

        try markChecked(now: now)
        guard let downloaded else { return .upToDate }

        progress?(ImportProgress(stage: .unpacking, fraction: 0.02))
        let provider = try GTFSZipProvider(data: downloaded.data)

        progress?(ImportProgress(stage: .parsing, fraction: 0.04))
        let parsed = try GTFSParser().parse(from: provider)

        let summary = try GTFSImporter(database: database).import(
            feed: parsed.feed,
            parseWarnings: parsed.warnings,
            provenance: downloaded.provenance,
            importedAt: now,
            progress: progress)
        return .imported(summary)
    }

    /// Records that a check happened, separately from when data was last imported.
    ///
    /// Kept distinct so the UI can say "data from Monday, checked five minutes ago"
    /// instead of implying the timetable itself is five minutes old.
    private func markChecked(now: Date) throws {
        try database.writer.write { db in
            try MetadataRow(key: FeedMetadataKey.lastCheckedAt,
                            value: ISO8601DateFormatter().string(from: now)).upsert(db)
        }
    }
}
