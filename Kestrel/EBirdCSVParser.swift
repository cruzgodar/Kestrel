import Foundation

enum EBirdCSVError: LocalizedError {
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

struct EBirdRawRow {
    let scientificName: String
    let commonName: String
    let date: Date
    let location: String?
}

enum EBirdCSVParser {
    /// Parses an eBird "My eBird Data" CSV. Skips rows with unparseable dates,
    /// empty scientific names, or scientific names that look like spuhs / hybrids
    /// / domestic forms (those are filtered out here so the store doesn't have to).
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

        // eBird's "My eBird Data" export uses ISO `yyyy-MM-dd`. Older / region-specific
        // exports sometimes use `MM/dd/yyyy`. Try ISO first, fall back to US.
        let isoFormatter = DateFormatter()
        isoFormatter.locale = Locale(identifier: "en_US_POSIX")
        isoFormatter.timeZone = TimeZone.current
        isoFormatter.dateFormat = "yyyy-MM-dd"

        let usFormatter = DateFormatter()
        usFormatter.locale = Locale(identifier: "en_US_POSIX")
        usFormatter.timeZone = TimeZone.current
        usFormatter.dateFormat = "MM/dd/yyyy"

        func parseDate(_ s: String) -> Date? {
            isoFormatter.date(from: s) ?? usFormatter.date(from: s)
        }

        var result: [EBirdRawRow] = []
        result.reserveCapacity(rows.count)

        for row in rows.dropFirst() {
            guard row.count > max(sciIdx, comIdx, dateIdx) else { continue }
            // Strip parenthesized clarifiers ("Rock Pigeon (Feral Pigeon)" → "Rock Pigeon").
            // Then collapse trinomials to the binomial so eBird's subspecies-group splits
            // ("Hairy Woodpecker (Eastern)" + "(Pacific)") merge into one species entry
            // — both BirdNET and the rest of the app key off the species-level binomial.
            let sci = speciesBinomial(stripParens(row[sciIdx]))
            let com = stripParens(row[comIdx])
            let dateStr = row[dateIdx].trimmingCharacters(in: .whitespacesAndNewlines)
            if sci.isEmpty { continue }
            if isUnidentified(sci) || isUnidentified(com) { continue }
            guard let date = parseDate(dateStr) else {
                continue
            }
            let loc: String? = locIdx.flatMap { idx in
                guard idx < row.count else { return nil }
                let v = row[idx].trimmingCharacters(in: .whitespacesAndNewlines)
                return v.isEmpty ? nil : v
            }
            result.append(EBirdRawRow(
                scientificName: sci,
                commonName: com.isEmpty ? sci : com,
                date: date,
                location: loc
            ))
        }
        return result
    }

    /// Skip spuhs ("Gull sp."), hybrids ("Mallard x American Black Duck"),
    /// and slash forms ("Greater/Lesser Scaup"). Parenthesized clarifiers
    /// ("Rock Pigeon (Feral Pigeon)") are *not* filtered — they're stripped instead.
    private static func isUnidentified(_ name: String) -> Bool {
        let lower = name.lowercased()
        if lower.contains(" sp.") { return true }
        if lower.contains("hybrid") { return true }
        if lower.contains(" x ") { return true }
        if name.contains("/") { return true }
        return false
    }

    /// Collapses a scientific name to its species-level binomial — `"Genus species"`.
    /// eBird exports subspecies groups as trinomials (`"Dryobates villosus harrisi"`),
    /// which would otherwise show up as duplicate species rows once the parenthetical
    /// common-name suffix is stripped. Names with fewer than two tokens pass through.
    private static func speciesBinomial(_ s: String) -> String {
        let parts = s.split(whereSeparator: { $0.isWhitespace })
        guard parts.count >= 2 else { return s }
        return "\(parts[0]) \(parts[1])"
    }

    /// Removes `(...)` segments and surrounding whitespace.
    private static func stripParens(_ s: String) -> String {
        var result = ""
        var depth = 0
        for ch in s {
            if ch == "(" { depth += 1; continue }
            if ch == ")" { depth = max(0, depth - 1); continue }
            if depth == 0 { result.append(ch) }
        }
        return result
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: CSV state machine

    /// Returns an array of rows; each row is an array of fields. Handles double-quoted
    /// fields containing commas, newlines, and escaped quotes (`""`). RFC 4180-ish.
    private static func parseCSV(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false

        var iter = text.makeIterator()
        while let c = iter.next() {
            if inQuotes {
                if c == "\"" {
                    // peek next character
                    let saved = field
                    if let next = iter.next() {
                        if next == "\"" {
                            field.append("\"")
                        } else {
                            inQuotes = false
                            // process `next` as a normal character
                            field = saved
                            if next == "," {
                                row.append(field); field = ""
                            } else if next == "\n" {
                                row.append(field); rows.append(row); row = []; field = ""
                            } else if next == "\r" {
                                // swallow; \n handled on next iter if present
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
                case "\r":
                    break
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
