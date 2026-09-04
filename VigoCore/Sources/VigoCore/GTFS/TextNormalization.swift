import Foundation

public enum TextNormalization {
    /// Folds a stop or line name into a form suitable for matching user input:
    /// diacritics and case removed, runs of whitespace collapsed.
    ///
    /// Needed because the feed ships names with double spaces (`Praza de América  1`)
    /// and because nobody types accents into a search field on a phone.
    public static func searchFolded(_ text: String) -> String {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive],
                                  locale: Locale(identifier: "es_ES"))
        return folded.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Cleans a line/route label coming from either the feed or the realtime API so the
    /// two can be compared.
    ///
    /// The realtime API returns `PSA` where the feed has `PSA1`/`PSA4`, and the feed
    /// carries variant names with a trailing dot (`11.`, `4A.`, `6.`). Matching has to
    /// be forgiving — see `DATA-SOURCES.md` §3.6.
    public static func normalizedLineName(_ text: String) -> String {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        s = s.split(whereSeparator: \.isWhitespace).joined()
        while s.hasSuffix(".") || s.hasSuffix("-") { s.removeLast() }
        return s.uppercased()
    }

    /// Cleans the `ruta` (destination) string returned by the realtime API.
    ///
    /// Observed values carry a trailing asterisk and stray leading spaces:
    /// `"XESTOSO *"`, `"  COIA por CAMELIAS*"`.
    public static func cleanedDestination(_ text: String) -> String {
        var s = text
        s = s.replacingOccurrences(of: "*", with: "")
        s = s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
