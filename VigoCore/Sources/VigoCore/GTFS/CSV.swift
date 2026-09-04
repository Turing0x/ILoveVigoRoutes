import Foundation

public struct CSVError: Error, CustomStringConvertible, Sendable {
    public let file: String
    public let line: Int
    public let reason: String
    public var description: String { "\(file):\(line): \(reason)" }
}

/// A minimal RFC 4180 reader that works over raw UTF-8 bytes.
///
/// Byte-level rather than `String`-level because `stop_times.txt` is 8 MB and
/// `shapes.txt` another 8 MB; going through `String.split` allocates far too much.
///
/// Handles the specific messiness observed in the Vitrasa feed (see `DATA-SOURCES.md` §2.7):
/// a UTF-8 BOM, header names padded with spaces (`service_id, monday, …`), a literal
/// tab inside `route_long_name`, and CRLF line endings.
public struct CSVTable: Sendable {
    public let fileName: String
    public let headers: [String]
    private let headerIndex: [String: Int]
    public let rows: [[String]]

    public init(data: Data, fileName: String) throws {
        self.fileName = fileName
        var bytes = [UInt8](data)
        // Strip UTF-8 BOM.
        if bytes.count >= 3, bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF {
            bytes.removeFirst(3)
        }
        var parsed = Self.parse(bytes)
        guard !parsed.isEmpty else {
            throw CSVError(file: fileName, line: 0, reason: "empty file")
        }
        // Header names are trimmed: the feed's calendar.txt ships " monday", " tuesday"…
        let headers = parsed.removeFirst().map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        self.headers = headers
        var index: [String: Int] = [:]
        for (i, h) in headers.enumerated() where index[h] == nil { index[h] = i }
        self.headerIndex = index
        self.rows = parsed
    }

    public var columnCount: Int { headers.count }

    public func columnIndex(_ name: String) -> Int? { headerIndex[name] }

    /// Throws when a column the caller treats as mandatory is absent, so a feed that
    /// silently drops a column fails loudly at import instead of producing empty data.
    public func requiredColumnIndex(_ name: String) throws -> Int {
        guard let i = headerIndex[name] else {
            throw CSVError(file: fileName, line: 1,
                           reason: "missing required column '\(name)'; present: \(headers)")
        }
        return i
    }

    private static func parse(_ bytes: [UInt8]) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field: [UInt8] = []
        var inQuotes = false
        var i = 0
        let n = bytes.count
        var sawAnyByteInRow = false

        @inline(__always) func endField() {
            row.append(String(decoding: field, as: UTF8.self))
            field.removeAll(keepingCapacity: true)
        }
        @inline(__always) func endRow() {
            endField()
            // Skip blank trailing lines rather than emitting a bogus one-empty-field row.
            if !(row.count == 1 && row[0].isEmpty && !sawAnyByteInRow) { rows.append(row) }
            row.removeAll(keepingCapacity: true)
            sawAnyByteInRow = false
        }

        while i < n {
            let b = bytes[i]
            if inQuotes {
                if b == 0x22 { // "
                    if i + 1 < n, bytes[i + 1] == 0x22 { field.append(0x22); i += 2; continue }
                    inQuotes = false; i += 1; continue
                }
                field.append(b); i += 1; continue
            }
            switch b {
            case 0x22: // "
                inQuotes = true; sawAnyByteInRow = true; i += 1
            case 0x2C: // ,
                endField(); sawAnyByteInRow = true; i += 1
            case 0x0A: // \n
                endRow(); i += 1
            case 0x0D: // \r — swallow, handle the \n (or a lone \r) as the terminator
                if i + 1 < n, bytes[i + 1] == 0x0A { endRow(); i += 2 } else { endRow(); i += 1 }
            default:
                field.append(b); sawAnyByteInRow = true; i += 1
            }
        }
        if !field.isEmpty || !row.isEmpty { endRow() }
        return rows
    }
}

extension Array where Element == String {
    /// Trimmed value at `index`, or `nil` when the column is absent or blank.
    ///
    /// Values are always trimmed: the feed ships a literal tab at the start of
    /// route 18A's `route_long_name`.
    @inline(__always)
    func csvValue(_ index: Int?) -> String? {
        guard let index, index < count else { return nil }
        let v = self[index].trimmingCharacters(in: .whitespacesAndNewlines)
        return v.isEmpty ? nil : v
    }
}
