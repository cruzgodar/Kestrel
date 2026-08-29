import Foundation
import Testing
@testable import Kestrel

/// Slug derivation for photo filenames. The algorithm has to mirror `slug_for`
/// in the photo set's own build script exactly — a mismatch means the app asks
/// the CDN for a filename that isn't there and silently shows a placeholder.
@Suite("SpeciesImage.slug")
struct SpeciesImageSlugTests {

    @Test(
        "names slug to lowercase ASCII with runs of punctuation collapsed",
        arguments: [
            ("Cardinalis cardinalis", "cardinalis_cardinalis"),
            ("Dryobates villosus harrisi", "dryobates_villosus_harrisi"),
            ("CARDINALIS CARDINALIS", "cardinalis_cardinalis"),
            ("Cardinalis  cardinalis", "cardinalis_cardinalis"),
            ("Motacilla alba", "motacilla_alba"),
        ]
    )
    func slugging(name: String, expected: String) {
        #expect(SpeciesImage.slug(for: name) == expected)
    }

    /// Decomposable diacritics fold to their base letter. (Non-decomposing
    /// letters like `æ` would survive, but no scientific name contains one —
    /// see `everyCatalogNameSlugsToASCII`, which checks the real data rather
    /// than an invented input.)
    @Test("diacritics fold to their base letter")
    func diacriticsStripped() {
        #expect(SpeciesImage.slug(for: "Île d\u{2019}Orléans") == "ile_d_orleans")
        #expect(SpeciesImage.slug(for: "Ünïcödé Bïrd") == "unicode_bird")
        #expect(SpeciesImage.slug(for: "Motacilla ãlbá") == "motacilla_alba")
    }

    @Test("punctuation collapses to single underscores and never leads or trails")
    func punctuationCollapses() {
        #expect(SpeciesImage.slug(for: "A-B/C.D") == "a_b_c_d")
        #expect(SpeciesImage.slug(for: "  spaced  out  ") == "spaced_out")
        #expect(SpeciesImage.slug(for: "---A---B---") == "a_b")
        #expect(SpeciesImage.slug(for: "!!!") == "")
    }

    /// The invariant that actually protects the photo set, checked against the
    /// shipped catalog rather than a handful of invented names: every species the
    /// app can look up must produce a filename-safe ASCII slug. Anything else is
    /// a request to the CDN for a name that cannot be there, which shows as a
    /// silent placeholder.
    @Test("every species in the shipped catalog slugs to filename-safe ASCII")
    func everyCatalogNameSlugsToASCII() {
        for species in SpeciesCatalog.shared.all {
            let slug = SpeciesImage.slug(for: species.scientificName)
            #expect(!slug.isEmpty, "\(species.scientificName) slugged to nothing")
            #expect(slug.allSatisfy { ($0.isASCII && $0.isLowercase) || $0.isNumber || $0 == "_" },
                    "\(species.scientificName) slugged to \(slug.debugDescription)")
        }
    }

    /// Two species sharing a slug would share a photo file — one of them would
    /// silently show the other's bird, with the other's credit line.
    @Test("no two catalog species share a slug")
    func slugsAreUniqueAcrossTheCatalog() {
        var seen: [String: String] = [:]
        for species in SpeciesCatalog.shared.all {
            let slug = SpeciesImage.slug(for: species.scientificName)
            if let existing = seen[slug] {
                Issue.record("\(existing) and \(species.scientificName) both slug to \(slug)")
            }
            seen[slug] = species.scientificName
        }
        #expect(seen.count == SpeciesCatalog.shared.all.count)
    }

    @Test("an empty name slugs to nothing, which every read path treats as no photo")
    func emptyName() {
        #expect(SpeciesImage.slug(for: "").isEmpty)
    }

    @Test("slugging is stable")
    func slugIsStable() {
        let name = "Dryobates villosus"
        #expect(SpeciesImage.slug(for: name) == SpeciesImage.slug(for: name))
    }
}
