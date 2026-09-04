import Testing
import Foundation
@testable import VigoCore

@Suite("ZIP reading")
struct ZipArchiveTests {

    private func fixture(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil)
            ?? Bundle.module.url(forResource: name, withExtension: nil))
        return try Data(contentsOf: url)
    }

    /// The real Vitrasa archive stores its entries uncompressed.
    @Test("Reads a stored (uncompressed) entry")
    func storedEntry() throws {
        let archive = try ZipArchive(data: try fixture("stored.zip"))
        #expect(archive.entryNames == ["stops.txt"])
        let data = try #require(try archive.extract("stops.txt"))
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.hasPrefix("stop_id,stop_code,stop_name"))
        #expect(text.contains("P006930"))
    }

    @Test("Reads a deflated entry")
    func deflatedEntry() throws {
        let archive = try ZipArchive(data: try fixture("deflated.zip"))
        #expect(archive.contains("stops.txt"))
        #expect(archive.contains("big.txt"))
        let big = try #require(try archive.extract("big.txt"))
        let text = String(decoding: big, as: UTF8.self)
        #expect(text.hasPrefix("trip_id,arrival_time"))
        #expect(text.contains("T3999,05:39:00"))
        #expect(text.split(separator: "\n").count == 4001)
    }

    @Test("A missing entry returns nil rather than throwing")
    func missingEntry() throws {
        let archive = try ZipArchive(data: try fixture("stored.zip"))
        #expect(try archive.extract("calendar.txt") == nil)
    }

    @Test("Rejects something that is not a ZIP")
    func notAZip() {
        #expect(throws: ZipArchive.Failure.self) {
            _ = try ZipArchive(data: Data("this is not a zip file at all".utf8))
        }
    }

    /// A truncated download must fail loudly. Silently importing half a feed would leave
    /// the app confidently showing an incomplete timetable.
    @Test("A truncated archive is rejected")
    func truncated() throws {
        var data = try fixture("deflated.zip")
        data = data.prefix(data.count / 2)
        #expect(throws: (any Error).self) {
            let archive = try ZipArchive(data: data)
            _ = try archive.extract("stops.txt")
        }
    }

    @Test("Corrupted entry bytes fail the checksum")
    func corruptPayload() throws {
        var bytes = [UInt8](try fixture("stored.zip"))
        // Flip a byte inside the stored payload, past the local header.
        bytes[80] = bytes[80] ^ 0xFF
        let archive = try ZipArchive(data: Data(bytes))
        #expect(throws: ZipArchive.Failure.self) { _ = try archive.extract("stops.txt") }
    }

    @Test("Feeds the parser straight out of the archive")
    func providerBridge() throws {
        let provider = try GTFSZipProvider(data: try fixture("stored.zip"))
        let data = try #require(try provider.data(forFile: "stops.txt"))
        let table = try CSVTable(data: data, fileName: "stops.txt")
        #expect(table.rows.first?[1] == "P006930")
        #expect(try provider.data(forFile: "nope.txt") == nil)
    }

    @Test("CRC-32 matches the reference value for a known input")
    func crc() {
        // "123456789" has the well-known CRC-32 check value 0xCBF43926.
        #expect(ZipArchive.crc32(Array("123456789".utf8)) == 0xCBF4_3926)
    }
}
