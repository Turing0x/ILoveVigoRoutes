import Testing
import Foundation
@testable import VigoCore

@Suite("CSV parsing")
struct CSVTests {

    @Test("Parses a plain table")
    func plainTable() throws {
        let t = try CSVTable(data: Data("a,b,c\n1,2,3\n4,5,6\n".utf8), fileName: "t.csv")
        #expect(t.headers == ["a", "b", "c"])
        #expect(t.rows.count == 2)
        #expect(t.rows[1] == ["4", "5", "6"])
    }

    /// The feed's calendar.txt ships "service_id, monday, tuesday, …" with padding.
    /// Untrimmed, every day column would be looked up under the wrong name and silently
    /// read as false, making every calendar-based service vanish.
    @Test("Trims padded header names")
    func paddedHeaders() throws {
        let t = try CSVTable(data: Data("service_id, monday, tuesday\nA,1,0\n".utf8), fileName: "calendar.txt")
        #expect(t.headers == ["service_id", "monday", "tuesday"])
        #expect(t.columnIndex("monday") == 1)
    }

    /// Route 18A's route_long_name begins with a literal tab in the real feed.
    @Test("Trims values including tabs")
    func trimsValues() throws {
        let t = try CSVTable(data: Data("route_id,route_long_name\n18,\tAREAL/COLON\n".utf8), fileName: "routes.txt")
        #expect(t.rows[0].csvValue(1) == "AREAL/COLON")
    }

    @Test("Handles quoted fields with commas and escaped quotes")
    func quoting() throws {
        let csv = "a,b\n\"x,y\",\"he said \"\"hi\"\"\"\n"
        let t = try CSVTable(data: Data(csv.utf8), fileName: "t.csv")
        #expect(t.rows[0][0] == "x,y")
        #expect(t.rows[0][1] == "he said \"hi\"")
    }

    @Test("Handles CRLF line endings")
    func crlf() throws {
        let t = try CSVTable(data: Data("a,b\r\n1,2\r\n3,4\r\n".utf8), fileName: "t.csv")
        #expect(t.rows.count == 2)
        #expect(t.rows[1] == ["3", "4"])
    }

    @Test("Strips a UTF-8 BOM")
    func bom() throws {
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append(Data("stop_id,stop_name\n1,A\n".utf8))
        let t = try CSVTable(data: data, fileName: "stops.txt")
        #expect(t.headers.first == "stop_id")
    }

    @Test("Preserves non-ASCII names")
    func unicode() throws {
        let t = try CSVTable(data: Data("stop_id,stop_name\n1,Praza de América  1\n".utf8), fileName: "stops.txt")
        #expect(t.rows[0][1] == "Praza de América  1")
    }

    @Test("Ignores trailing blank lines")
    func trailingBlankLines() throws {
        let t = try CSVTable(data: Data("a,b\n1,2\n\n\n".utf8), fileName: "t.csv")
        #expect(t.rows.count == 1)
    }

    @Test("A missing required column throws rather than yielding empty data")
    func missingRequiredColumn() throws {
        let t = try CSVTable(data: Data("a,b\n1,2\n".utf8), fileName: "t.csv")
        #expect(throws: CSVError.self) { try t.requiredColumnIndex("stop_id") }
    }

    @Test("Empty file throws")
    func emptyFile() {
        #expect(throws: CSVError.self) { try CSVTable(data: Data(), fileName: "t.csv") }
    }
}
