import Foundation

public enum TextNormalization {
    /// Folds a stop or line name into a form suitable for matching user input:
    /// diacritics and case removed, punctuation replaced by whitespace, runs of
    /// whitespace collapsed.
    ///
    /// Needed because the feed ships names with double spaces (`Praza de América  1`),
    /// abbreviations with a trailing dot (`Avda. da Florida`), hyphens and quotes
    /// (`Urzáiz - Príncipe`, `Beiramar "Porto Pesqueiro"`) — and because nobody types any
    /// of that into a search field on a phone. Digits are kept: a portal number is part of
    /// what the user searches by.
    public static func searchFolded(_ text: String) -> String {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive],
                                  locale: Locale(identifier: "es_ES"))
        let lettersAndDigits = folded.map { $0.isLetter || $0.isNumber ? $0 : " " }
        return String(lettersAndDigits).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Escapes SQLite `LIKE` metacharacters in text that is about to become part of a
    /// pattern, so a literal `%` or `_` typed by the user cannot act as a wildcard.
    ///
    /// Pair with `LIKE ... ESCAPE '\\'` in the SQL. Takes already-folded text: `searchFolded`
    /// strips punctuation, including `%` and `_`, so in practice a value that reaches here
    /// through it never contains one — this is the defence for call sites that build a
    /// pattern from text that has not been through that fold.
    public static func likePattern(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
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
