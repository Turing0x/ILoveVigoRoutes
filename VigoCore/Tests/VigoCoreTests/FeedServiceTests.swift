import Testing
import Foundation
@testable import VigoCore

/// Stands in for the network, recording the conditional headers it was asked to send.
actor StubDownloader: GTFSFeedDownloading {
    private(set) var calls: [(etag: String?, lastModified: String?)] = []
    private var responses: [DownloadedFeed?]

    init(responses: [DownloadedFeed?]) { self.responses = responses }

    func download(etag: String?, lastModified: String?) async throws -> DownloadedFeed? {
        calls.append((etag, lastModified))
        guard !responses.isEmpty else { return nil }
        return responses.removeFirst()
    }
}

@Suite("Feed refresh")
struct FeedServiceTests {

    private func zipFixture() throws -> Data {
        let url = try #require(Bundle.module.url(forResource: "Fixtures/stored", withExtension: "zip")
            ?? Bundle.module.url(forResource: "stored", withExtension: "zip"))
        return try Data(contentsOf: url)
    }

    @Test("Checks when nothing has been imported yet")
    func checksWhenEmpty() throws {
        let db = try AppDatabase.inMemory()
        let repository = TransitRepository(database: db)
        let service = GTFSFeedService(downloader: StubDownloader(responses: []),
                                      database: db, repository: repository)
        #expect(try service.shouldCheck())
    }

    /// The window is only seven days wide, so an interval-only policy would let the app
    /// sit on an expired timetable.
    @Test("Checks as soon as the imported window no longer covers today")
    func checksWhenWindowExpired() throws {
        let db = try Fixture.importedDatabase()
        let repository = TransitRepository(database: db)
        let service = GTFSFeedService(downloader: StubDownloader(responses: []),
                                      database: db, repository: repository,
                                      checkInterval: 365 * 24 * 3600)
        // Fixture window is 2026-09-04 … 2026-09-06.
        #expect(try !service.shouldCheck(now: Fixture.date(2026, 9, 4, 9, 0)),
                "inside the window and checked just now")
        #expect(try service.shouldCheck(now: Fixture.date(2026, 9, 20, 9, 0)),
                "the window has run out, the interval must not hold it back")
    }

    @Test("Checks on the last day of the window")
    func checksOnFinalDay() throws {
        let db = try Fixture.importedDatabase()
        let service = GTFSFeedService(downloader: StubDownloader(responses: []),
                                      database: db, repository: TransitRepository(database: db),
                                      checkInterval: 365 * 24 * 3600)
        #expect(try service.shouldCheck(now: Fixture.date(2026, 9, 6, 9, 0)),
                "one day left means fetch now, not tomorrow when it is too late")
    }

    /// The whole point of storing the ETag: the usual answer should be a 304.
    @Test("Sends the stored validators and treats 304 as up to date")
    func conditionalRequest() async throws {
        let db = try AppDatabase.inMemory()
        let repository = TransitRepository(database: db)
        let parsed = try GTFSParser().parse(from: Fixture.provider)
        _ = try GTFSImporter(database: db).import(
            feed: parsed.feed,
            provenance: FeedProvenance(etag: "\"abc123\"",
                                       lastModified: "Mon, 31 Aug 2026 04:31:47 GMT",
                                       sourceURL: nil))

        let downloader = StubDownloader(responses: [nil])   // 304
        let service = GTFSFeedService(downloader: downloader, database: db,
                                      repository: repository, checkInterval: 0)
        let outcome = try await service.refreshIfNeeded(now: Fixture.date(2026, 9, 4, 9, 0))

        guard case .upToDate = outcome else {
            Issue.record("expected upToDate, got \(outcome)"); return
        }
        let calls = await downloader.calls
        #expect(calls.count == 1)
        #expect(calls[0].etag == "\"abc123\"")
        #expect(calls[0].lastModified == "Mon, 31 Aug 2026 04:31:47 GMT")
    }

    /// A 304 must not be recorded as if fresh data had arrived, or the UI would claim the
    /// timetable is newer than it is.
    @Test("A 304 updates the check time but not the import time")
    func checkTimeIsSeparate() async throws {
        let db = try Fixture.importedDatabase()
        let repository = TransitRepository(database: db)
        let importedAt = try repository.feedStatus().importedAt
        let service = GTFSFeedService(downloader: StubDownloader(responses: [nil]),
                                      database: db, repository: repository, checkInterval: 0)
        _ = try await service.refreshIfNeeded(now: Fixture.date(2026, 9, 4, 9, 0))

        let status = try repository.feedStatus()
        #expect(status.importedAt == importedAt, "the data did not change, so neither should its date")
        #expect(status.lastCheckedAt == Fixture.date(2026, 9, 4, 9, 0))
    }

    @Test("A forced refresh drops the validators so it cannot be answered with a 304")
    func forcedRefreshIgnoresValidators() async throws {
        let db = try Fixture.importedDatabase()
        let downloader = StubDownloader(responses: [nil])
        let service = GTFSFeedService(downloader: downloader, database: db,
                                      repository: TransitRepository(database: db))
        _ = try await service.refreshIfNeeded(force: true)
        let calls = await downloader.calls
        #expect(calls[0].etag == nil)
        #expect(calls[0].lastModified == nil)
    }

    @Test("Skips the network when the feed is current and was checked recently")
    func skipsWhenFresh() async throws {
        let db = try Fixture.importedDatabase()
        let downloader = StubDownloader(responses: [])
        let service = GTFSFeedService(downloader: downloader, database: db,
                                      repository: TransitRepository(database: db),
                                      checkInterval: 24 * 3600)
        let outcome = try await service.refreshIfNeeded(now: Fixture.date(2026, 9, 4, 9, 0))
        guard case .skipped = outcome else {
            Issue.record("expected skipped, got \(outcome)"); return
        }
        #expect(await downloader.calls.isEmpty, "no request should have been made")
    }

    @Test("A download failure propagates instead of being silently swallowed")
    func downloadFailurePropagates() async throws {
        struct FailingDownloader: GTFSFeedDownloading {
            func download(etag: String?, lastModified: String?) async throws -> DownloadedFeed? {
                throw FeedDownloadError.httpStatus(503)
            }
        }
        let db = try AppDatabase.inMemory()
        let service = GTFSFeedService(downloader: FailingDownloader(), database: db,
                                      repository: TransitRepository(database: db))
        await #expect(throws: FeedDownloadError.self) {
            _ = try await service.refreshIfNeeded()
        }
    }

    @Test("Reports progress through the stages")
    func reportsProgress() async throws {
        let db = try AppDatabase.inMemory()
        let parsed = try GTFSParser().parse(from: Fixture.provider)
        // Feed the real pipeline a genuine archive so unpacking is exercised too.
        let downloaded = DownloadedFeed(
            data: try zipFixture(),
            provenance: FeedProvenance(etag: nil, lastModified: nil, sourceURL: nil))
        _ = parsed

        let stages = StageRecorder()
        let service = GTFSFeedService(downloader: StubDownloader(responses: [downloaded]),
                                      database: db, repository: TransitRepository(database: db))
        // The stored fixture only holds stops.txt, so the import is expected to fail on a
        // missing required file — the point here is that the early stages were reported.
        _ = try? await service.refreshIfNeeded(force: true) { stages.record($0.stage) }
        #expect(stages.stages.contains(.downloading))
        #expect(stages.stages.contains(.unpacking))
    }
}

final class StageRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [ImportProgress.Stage] = []
    var stages: [ImportProgress.Stage] { lock.withLock { storage } }
    func record(_ stage: ImportProgress.Stage) { lock.withLock { storage.append(stage) } }
}
