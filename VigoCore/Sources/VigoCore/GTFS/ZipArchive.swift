import Foundation
import Compression

/// A read-only ZIP reader covering exactly what a GTFS feed needs.
///
/// Written rather than pulled in as a dependency: the brief keeps dependencies to GRDB
/// alone, and this needs to handle two storage methods and nothing else. It is verified
/// against the real 16 MB Vitrasa archive, and every entry's CRC-32 is checked on
/// extraction, so a truncated download fails loudly instead of producing a half-feed.
public struct ZipArchive: Sendable {

    public enum Failure: Error, CustomStringConvertible, Sendable {
        case notAZipArchive
        case unsupportedZip64
        case unsupportedCompression(UInt16, entry: String)
        case corruptEntry(String, reason: String)
        case checksumMismatch(String)

        public var description: String {
            switch self {
            case .notAZipArchive: "not a ZIP archive (no end-of-central-directory record)"
            case .unsupportedZip64: "ZIP64 archives are not supported"
            case .unsupportedCompression(let m, let e): "entry '\(e)' uses unsupported compression method \(m)"
            case .corruptEntry(let e, let r): "entry '\(e)' is malformed: \(r)"
            case .checksumMismatch(let e): "entry '\(e)' failed its CRC-32 check; the download is corrupt"
            }
        }
    }

    struct Entry {
        let name: String
        let compressionMethod: UInt16
        let crc32: UInt32
        let compressedSize: Int
        let uncompressedSize: Int
        let localHeaderOffset: Int
    }

    private let data: [UInt8]
    private let entries: [String: Entry]

    public var entryNames: [String] { Array(entries.keys).sorted() }

    public init(data: Data) throws {
        self.data = [UInt8](data)
        self.entries = try Self.readCentralDirectory(self.data)
    }

    public init(contentsOf url: URL) throws {
        try self.init(data: try Data(contentsOf: url, options: .mappedIfSafe))
    }

    public func contains(_ name: String) -> Bool { entries[name] != nil }

    /// Returns `nil` when the entry is absent — several GTFS files are optional.
    public func extract(_ name: String) throws -> Data? {
        guard let entry = entries[name] else { return nil }

        // The local header repeats the name and extra-field lengths, which may differ
        // from the central directory's, so the data offset must be read from it.
        let headerStart = entry.localHeaderOffset
        guard headerStart + 30 <= data.count,
              readUInt32(data, headerStart) == 0x0403_4B50 else {
            throw Failure.corruptEntry(name, reason: "bad local header signature")
        }
        let nameLength = Int(readUInt16(data, headerStart + 26))
        let extraLength = Int(readUInt16(data, headerStart + 28))
        let dataStart = headerStart + 30 + nameLength + extraLength
        guard dataStart + entry.compressedSize <= data.count else {
            throw Failure.corruptEntry(name, reason: "declared size runs past the end of the archive")
        }

        let compressed = Array(data[dataStart ..< dataStart + entry.compressedSize])
        let output: [UInt8]
        switch entry.compressionMethod {
        case 0:
            output = compressed
        case 8:
            output = try Self.inflate(compressed, expectedSize: entry.uncompressedSize, name: name)
        default:
            throw Failure.unsupportedCompression(entry.compressionMethod, entry: name)
        }

        guard output.count == entry.uncompressedSize else {
            throw Failure.corruptEntry(
                name, reason: "expected \(entry.uncompressedSize) bytes, got \(output.count)")
        }
        // Zero CRC with zero length is legitimately unset for empty entries.
        if !(entry.crc32 == 0 && output.isEmpty) {
            guard Self.crc32(output) == entry.crc32 else { throw Failure.checksumMismatch(name) }
        }
        return Data(output)
    }

    // MARK: - Central directory

    private static func readCentralDirectory(_ bytes: [UInt8]) throws -> [String: Entry] {
        // The EOCD sits at the very end, unless a trailing comment pushes it back by up
        // to 65535 bytes.
        let minimumEOCD = 22
        guard bytes.count >= minimumEOCD else { throw Failure.notAZipArchive }
        let searchLowerBound = max(0, bytes.count - minimumEOCD - 65_535)
        var eocd = -1
        var i = bytes.count - minimumEOCD
        while i >= searchLowerBound {
            if readUInt32(bytes, i) == 0x0605_4B50 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { throw Failure.notAZipArchive }

        let entryCount = Int(readUInt16(bytes, eocd + 10))
        let directoryOffset = Int(readUInt32(bytes, eocd + 16))
        // 0xFFFF/0xFFFFFFFF sentinels mean the real values live in a ZIP64 record.
        guard entryCount != 0xFFFF, directoryOffset != 0xFFFF_FFFF else {
            throw Failure.unsupportedZip64
        }

        var entries: [String: Entry] = [:]
        var cursor = directoryOffset
        for _ in 0 ..< entryCount {
            guard cursor + 46 <= bytes.count, readUInt32(bytes, cursor) == 0x0201_4B50 else {
                throw Failure.corruptEntry("<central directory>", reason: "bad signature at \(cursor)")
            }
            let method = readUInt16(bytes, cursor + 10)
            let crc = readUInt32(bytes, cursor + 16)
            let compressedSize = Int(readUInt32(bytes, cursor + 20))
            let uncompressedSize = Int(readUInt32(bytes, cursor + 24))
            let nameLength = Int(readUInt16(bytes, cursor + 28))
            let extraLength = Int(readUInt16(bytes, cursor + 30))
            let commentLength = Int(readUInt16(bytes, cursor + 32))
            let localOffset = Int(readUInt32(bytes, cursor + 42))
            guard cursor + 46 + nameLength <= bytes.count else {
                throw Failure.corruptEntry("<central directory>", reason: "name runs past end")
            }
            let name = String(decoding: bytes[cursor + 46 ..< cursor + 46 + nameLength], as: UTF8.self)
            if compressedSize == Int(UInt32.max) || uncompressedSize == Int(UInt32.max) {
                throw Failure.unsupportedZip64
            }
            // Directory entries carry no payload.
            if !name.hasSuffix("/") {
                entries[name] = Entry(name: name, compressionMethod: method, crc32: crc,
                                      compressedSize: compressedSize,
                                      uncompressedSize: uncompressedSize,
                                      localHeaderOffset: localOffset)
            }
            cursor += 46 + nameLength + extraLength + commentLength
        }
        return entries
    }

    // MARK: - DEFLATE

    private static func inflate(_ input: [UInt8], expectedSize: Int, name: String) throws -> [UInt8] {
        guard expectedSize > 0 else { return [] }
        // ZIP stores raw DEFLATE, which is what COMPRESSION_ZLIB means here.
        var output = [UInt8](repeating: 0, count: expectedSize)
        let written = input.withUnsafeBufferPointer { source in
            output.withUnsafeMutableBufferPointer { destination in
                compression_decode_buffer(
                    destination.baseAddress!, expectedSize,
                    source.baseAddress!, input.count,
                    nil, COMPRESSION_ZLIB)
            }
        }
        guard written == expectedSize else {
            throw Failure.corruptEntry(name, reason: "inflate produced \(written) of \(expectedSize) bytes")
        }
        return output
    }

    // MARK: - CRC-32

    private static let crcTable: [UInt32] = {
        (0 ..< 256).map { i -> UInt32 in
            var c = UInt32(i)
            for _ in 0 ..< 8 { c = (c & 1) != 0 ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1) }
            return c
        }
    }()

    static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for b in bytes { c = crcTable[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }
}

@inline(__always) private func readUInt16(_ b: [UInt8], _ i: Int) -> UInt16 {
    UInt16(b[i]) | (UInt16(b[i + 1]) << 8)
}

@inline(__always) private func readUInt32(_ b: [UInt8], _ i: Int) -> UInt32 {
    UInt32(b[i]) | (UInt32(b[i + 1]) << 8) | (UInt32(b[i + 2]) << 16) | (UInt32(b[i + 3]) << 24)
}

/// Reads GTFS files straight out of a ZIP, so the archive never has to be unpacked to disk.
public struct GTFSZipProvider: GTFSFileProviding {
    private let archive: ZipArchive
    public init(archive: ZipArchive) { self.archive = archive }
    public init(data: Data) throws { self.archive = try ZipArchive(data: data) }
    public func data(forFile name: String) throws -> Data? { try archive.extract(name) }
}
