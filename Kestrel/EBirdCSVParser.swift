import Foundation

nonisolated enum EBirdCSVError: LocalizedError {
    case missingColumns([String])
    case unreadable

    var errorDescription: String? {
        switch self {
        case .missingColumns(let cols):
            return "CSV is missing required column(s): \(cols.joined(separator: ", "))"
        case .unreadable:
            return "Could not read the CSV file."
        }
    }
}

nonisolated struct EBirdRawRow {
    let scientificName: String
    let commonName: String
    let date: Date
    let location: String?
    let latitude: Double?
    let longitude: Double?
}

nonisolated enum EBirdCSVParser {
    /// Parses an eBird "My eBird Data" CSV. Skips rows with unparseable dates,
    /// empty scientific names, and anything that isn't a single species — spuhs,
    /// hybrids, slash forms — see `isNonSpecies`, which filters them here so the
    /// store doesn't have to.
    ///
    /// Domestic and feral forms are deliberately *not* skipped. Their
    /// parenthetical is stripped ("Mallard (Domestic type)" → "Mallard", "Rock
    /// Pigeon (Feral Pigeon)" → "Rock Pigeon") and the row is filed under the
    /// nominate species, which is the useful outcome: eBird doesn't count them as
    /// separate species either, and anyone with a domestic Mallard on their list
    /// has a wild one too.
    static func parse(_ data: Data) throws -> [EBirdRawRow] {
        guard let text = String(data: data, encoding: .utf8)
                      ?? String(data: data, encoding: .isoLatin1) else {
            throw EBirdCSVError.unreadable
        }

        let rows = parseCSV(text)
        guard let header = rows.first else { return [] }

        func column(_ name: String) -> Int? {
            header.firstIndex { $0.caseInsensitiveCompare(name) == .orderedSame }
        }

        guard let sciIdx = column("Scientific Name"),
              let comIdx = column("Common Name"),
              let dateIdx = column("Date") else {
            var missing: [String] = []
            if column("Scientific Name") == nil { missing.append("Scientific Name") }
            if column("Common Name") == nil { missing.append("Common Name") }
            if column("Date") == nil { missing.append("Date") }
            throw EBirdCSVError.missingColumns(missing)
        }
        let locIdx = column("Location")
        let latIdx = column("Latitude")
        let lonIdx = column("Longitude")

        // eBird's "My eBird Data" export uses ISO `yyyy-MM-dd`. Older / region-specific
        // exports sometimes use `MM/dd/yyyy`. Try ISO first, fall back to US.
        //
        // Parsed **in UTC**, so a bare day in the CSV becomes midnight UTC on that
        // day — the form every stored sighting takes (see `ObservationDate`).
        // Parsing in the device's zone instead made an import's dates depend on
        // where the phone was when the file was opened.
        let isoFormatter = DateFormatter()
        isoFormatter.locale = Locale(identifier: "en_US_POSIX")
        isoFormatter.calendar = Calendar(identifier: .gregorian)
        isoFormatter.timeZone = ObservationDate.utc
        isoFormatter.dateFormat = "yyyy-MM-dd"

        let usFormatter = DateFormatter()
        usFormatter.locale = Locale(identifier: "en_US_POSIX")
        usFormatter.calendar = Calendar(identifier: .gregorian)
        usFormatter.timeZone = ObservationDate.utc
        usFormatter.dateFormat = "MM/dd/yyyy"

        func parseDate(_ s: String) -> Date? {
            isoFormatter.date(from: s) ?? usFormatter.date(from: s)
        }

        var result: [EBirdRawRow] = []
        result.reserveCapacity(rows.count)

        for row in rows.dropFirst() {
            guard row.count > max(sciIdx, comIdx, dateIdx) else { continue }
            // Whether this row describes one species is decided **before** either
            // transform below, on the columns as eBird wrote them — see
            // `isNonSpecies`, and the note there on why asking afterwards
            // couldn't work.
            if isNonSpecies(rawScientific: row[sciIdx], rawCommon: row[comIdx]) { continue }
            // Strip parenthesized clarifiers ("Rock Pigeon (Feral Pigeon)" → "Rock Pigeon").
            // Then collapse trinomials to the binomial so eBird's subspecies-group splits
            // ("Hairy Woodpecker (Eastern)" + "(Pacific)") merge into one species entry
            // — both BirdNET and the rest of the app key off the species-level binomial.
            // Alias before binomial collapse: aliases are written as binomials
            // already, and applying first means a remap target (e.g.
            // "Setophaga petechia") flows through the rest of the pipeline as
            // the canonical name.
            let sci = TaxonomyAliases.canonical(
                TaxonomyAliases.speciesBinomial(stripParens(row[sciIdx]))
            )
            let com = stripParens(row[comIdx])
            let dateStr = row[dateIdx].trimmingCharacters(in: .whitespacesAndNewlines)
            if sci.isEmpty { continue }
            guard let date = parseDate(dateStr) else {
                continue
            }
            let loc: String? = locIdx.flatMap { idx in
                guard idx < row.count else { return nil }
                let v = row[idx].trimmingCharacters(in: .whitespacesAndNewlines)
                return v.isEmpty ? nil : v
            }
            func parseCoord(_ idx: Int?) -> Double? {
                guard let idx, idx < row.count else { return nil }
                let v = row[idx].trimmingCharacters(in: .whitespacesAndNewlines)
                return v.isEmpty ? nil : Double(v)
            }
            result.append(EBirdRawRow(
                scientificName: sci,
                commonName: com.isEmpty ? sci : com,
                date: date,
                location: loc,
                latitude: parseCoord(latIdx),
                longitude: parseCoord(lonIdx)
            ))
        }
        return result
    }

    /// Whether a row describes something other than a single species — a spuh
    /// ("Buteo sp."), a cross between two species ("Brewster’s Warbler"), or a
    /// record that couldn’t be narrowed past a pair ("Greater/Lesser Scaup").
    /// None of those belongs on a life list.
    ///
    /// **Asked of the raw columns, before `stripParens` and `speciesBinomial`
    /// run**, because both of those destroy the evidence:
    ///
    ///   • `speciesBinomial` collapses `"Vermivora chrysoptera x cyanoptera"` to
    ///     `"Vermivora chrysoptera"`, so a `" x "` test downstream sees a clean
    ///     binomial.
    ///   • `stripParens` removes the parenthetical eBird puts the marker in —
    ///     `"Brewster’s Warbler (Golden-winged x Blue-winged)"` and
    ///     `"Lawrence’s Warbler (hybrid)"` both fold to a plain-looking name.
    ///
    /// With both halves blind, such a row was imported *as its first parent
    /// species*, and — because `LifeListStore.computeMergedEntries` takes the
    /// earliest row’s common name — an early-dated hybrid could rename the
    /// user’s existing Golden-winged Warbler entry to "Brewster’s Warbler".
    static func isNonSpecies(rawScientific: String, rawCommon: String) -> Bool {
        if !namesOneSpecies(stripParens(rawScientific)) { return true }
        // The common name is tested *stripped*, which is deliberate and is why
        // the scientific rule above has to carry the weight: eBird writes
        // legitimate subspecies-level ambiguity in parentheses too
        // ("Yellow-rumped Warbler (Myrtle/Audubon’s)"), and that bird is a
        // Yellow-rumped Warbler whatever race it was. Testing the raw common
        // name would throw those away.
        if isUnidentified(stripParens(rawCommon)) { return true }
        // The one keyword worth reading through a parenthetical: no real bird is
        // called a hybrid. A free second net, in case eBird ever labels one
        // without also crossing its scientific name.
        if rawCommon.lowercased().contains("hybrid") { return true }
        return false
    }

    /// Whether a scientific name names one *species*, rather than a cross
    /// between two or an uncertainty about which it was.
    ///
    /// **Position is the whole rule**, because the same token means opposite
    /// things at different ranks — which is exactly why this can’t be a plain
    /// substring test:
    ///
    ///   • `"Vermivora chrysoptera x cyanoptera"` — the `x` joins two *epithets*,
    ///     so this is a cross between two species and belongs on no life list.
    ///   • `"Setophaga coronata auduboni x coronata"` — the `x` joins two
    ///     *subspecies* of one species. That bird is a Yellow-rumped Warbler and
    ///     does belong; `speciesBinomial` collapses it to one.
    ///   • `"Aythya marila/affinis"` — the slash is in the epithet, so which
    ///     species it was is unknown.
    ///   • `"Setophaga coronata coronata/auduboni"` — the slash is below the
    ///     binomial, so the species is known.
    ///
    /// So only the genus, the epithet, and a third token of exactly `x` are
    /// examined. Everything past that describes a subspecies and is collapsed
    /// away by `speciesBinomial`, as it always was.
    static func namesOneSpecies(_ scientificName: String) -> Bool {
        let parts = scientificName.split(whereSeparator: { $0.isWhitespace })
        // No genus at all: the row names nothing. (`parse` also drops these on
        // the empty-name check; answering here keeps this function total.)
        guard let genus = parts.first else { return false }
        if genus.contains("/") { return false }
        // A bare genus is as far as the name goes; nothing here contradicts it.
        guard parts.count >= 2 else { return true }
        let epithet = parts[1]
        if epithet.contains("/") { return false }
        if epithet.lowercased().hasPrefix("sp.") { return false }
        // "Genus epithet x otherEpithet" — two species crossed.
        if parts.count >= 3, parts[2].lowercased() == "x" { return false }
        return true
    }

    /// Skip spuhs ("Gull sp."), hybrids ("Mallard x American Black Duck"),
    /// and slash forms ("Greater/Lesser Scaup"). Applied to the *common* name,
    /// stripped of its parenthetical — see `isNonSpecies` for why that is the
    /// right input for this half and the wrong one for the scientific half.
    private static func isUnidentified(_ name: String) -> Bool {
        let lower = name.lowercased()
        if lower.contains(" sp.") { return true }
        if lower.contains("hybrid") { return true }
        if lower.contains(" x ") { return true }
        if name.contains("/") { return true }
        return false
    }

    /// Removes `(...)` segments, then collapses the whitespace removing them
    /// leaves behind.
    ///
    /// Split + join rather than a `"  "` → `" "` replacement, which only closed
    /// gaps of exactly two: `replacingOccurrences` doesn't rescan what it has
    /// written, so a run of three came out as two. Three is what two
    /// space-separated clarifiers mid-name leave behind — `"A (x) (y) B"` →
    /// `"A   B"` → `"A  B"` — and that doubled space was then stored, and
    /// displayed, as part of the common name.
    private static func stripParens(_ s: String) -> String {
        var result = ""
        var depth = 0
        for ch in s {
            if ch == "(" { depth += 1; continue }
            if ch == ")" { depth = max(0, depth - 1); continue }
            if depth == 0 { result.append(ch) }
        }
        return result.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    // MARK: CSV state machine

    /// Returns an array of rows; each row is an array of fields. Handles double-quoted
    /// fields containing commas, newlines, and escaped quotes (`""`). RFC 4180-ish.
    private static func parseCSV(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false

        // Normalize line endings up front. Swift iterates `String` by grapheme
        // cluster, and CRLF ("\r\n") is a *single* Character that equals neither
        // "\n" nor "\r" — so a Windows/Numbers-saved export (CRLF) would otherwise
        // fall through to `default`, embed the break as field content, and collapse
        // the entire file into one row. eBird's own export uses bare "\n". Fold
        // CRLF and lone CR down to "\n" so the scan below sees real row breaks.
        //
        // Between them these two cover every carriage return there can be, so the
        // scan below never sees one and has no case for it — a "\r" arm in either
        // branch would be dead code claiming to handle something that cannot
        // arrive. A break *inside* a quoted field is folded the same way and kept
        // as field content, which is what RFC 4180 asks for.
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        var iter = normalized.makeIterator()
        while let c = iter.next() {
            if inQuotes {
                if c == "\"" {
                    // peek next character
                    if let next = iter.next() {
                        if next == "\"" {
                            field.append("\"")
                        } else {
                            inQuotes = false
                            // process `next` as a normal character
                            if next == "," {
                                row.append(field); field = ""
                            } else if next == "\n" {
                                row.append(field); rows.append(row); row = []; field = ""
                            } else {
                                field.append(next)
                            }
                        }
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(c)
                }
            } else {
                switch c {
                case "\"":
                    inQuotes = true
                case ",":
                    row.append(field); field = ""
                case "\n":
                    row.append(field); rows.append(row); row = []; field = ""
                default:
                    field.append(c)
                }
            }
        }
        // trailing field / row
        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            rows.append(row)
        }
        // strip trailing all-empty rows
        while let last = rows.last, last.allSatisfy({ $0.isEmpty }) {
            rows.removeLast()
        }
        return rows
    }
}
