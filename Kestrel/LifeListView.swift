import SwiftUI
import UniformTypeIdentifiers

struct LifeListView: View {
    @Environment(LifeListStore.self) private var store

    @State private var isImporting = false
    @State private var importMessage: String?
    @State private var showImportResult = false
    /// The species the user just swiped to delete — drives the confirmation
    /// dialog. Cleared on Cancel; the actual remove happens on confirm.
    @State private var pendingDeletion: LifeListEntry?
    @State private var showStarredOnly = false
    @State private var searchText = ""
    /// Catalog suggestions for the current `searchText`. Computed off the
    /// main actor by a debounced `.task(id: searchText)`; reads here go
    /// straight into the rendered list. Empty while the user is still
    /// typing or when the query is too short to bother scanning 6,500
    /// species.
    @State private var asyncSuggestions: [SearchRow] = []

    /// Row item rendered by the list. Life-list entries are sorted ahead
    /// of catalog suggestions so adding a missing species feels like a
    /// continuation of the list, not a different mode.
    enum SearchRow: Identifiable, Hashable {
        case existing(LifeListEntry)
        case suggestion(scientificName: String, commonName: String)

        var id: String {
            switch self {
            case .existing(let e):       return "e-" + e.scientificName
            case .suggestion(let s, _):  return "s-" + s
            }
        }
    }

    /// Drives the List. Life-list matches are filtered synchronously (the
    /// list is small), and catalog suggestions come from the async pipeline
    /// in `asyncSuggestions` — already sorted, capped at 20, and ordered
    /// after the life-list section.
    private var visibleRows: [SearchRow] {
        let base = showStarredOnly ? store.entries.filter(\.isStarred) : store.entries
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return base.map { .existing($0) } }
        let needle = q.lowercased()

        let lifeMatches = base.filter { entry in
            let hay = "\(entry.commonName) \(entry.scientificName)".lowercased()
            return Self.scoreMatch(hay, needle: needle, allowFuzzy: needle.count >= 3) != nil
        }

        return lifeMatches.map { .existing($0) } + asyncSuggestions
    }

    /// Returns `nil` if `hay` doesn't match `needle`, otherwise a score
    /// where lower = closer match. Substring matches score 0; the fuzzy
    /// prefix-Levenshtein fallback is skipped for very short queries
    /// (`allowFuzzy == false`) since substring already catches everything
    /// useful and the per-keystroke cost adds up at 6,500 species.
    nonisolated static func scoreMatch(_ hay: String, needle: String, allowFuzzy: Bool) -> Int? {
        if hay.contains(needle) { return 0 }
        guard allowFuzzy else { return nil }
        var best = Int.max
        for word in hay.split(whereSeparator: { !$0.isLetter }) {
            let prefix = String(word.prefix(needle.count))
            let d = Self.levenshtein(prefix, needle)
            if d <= 1 && d < best { best = d }
        }
        return best == Int.max ? nil : best
    }

    /// Background scan that produces the catalog suggestion rows. Called
    /// from a detached task after the debounce window, never on main.
    /// `lifeCommonNames` is matched case-insensitively so taxonomic revisions
    /// (a life-list entry under an older genus like "Leuconotopicus villosus"
    /// vs. the catalog's "Dryobates villosus") don't surface as a duplicate
    /// suggestion sharing the same common name.
    nonisolated static func computeSuggestions(
        needle: String,
        excluding lifeNames: Set<String>,
        lifeCommonNames: Set<String>
    ) -> [SearchRow] {
        let allowFuzzy = needle.count >= 3
        var scored: [(score: Int, scientific: String, common: String)] = []
        scored.reserveCapacity(64)
        for sp in SpeciesCatalog.shared.all {
            if lifeNames.contains(sp.scientificName) { continue }
            if lifeCommonNames.contains(sp.commonName.lowercased()) { continue }
            guard let s = scoreMatch(sp.searchHay, needle: needle, allowFuzzy: allowFuzzy) else { continue }
            scored.append((s, sp.scientificName, sp.commonName))
        }
        return scored
            .sorted { $0.score < $1.score }
            .prefix(20)
            .map { .suggestion(scientificName: $0.scientific, commonName: $0.common) }
    }

    /// Iterative DP Levenshtein. Two rows, O(min(a,b)) memory.
    nonisolated static func levenshtein(_ a: String, _ b: String) -> Int {
        let aChars = Array(a), bChars = Array(b)
        if aChars.isEmpty { return bChars.count }
        if bChars.isEmpty { return aChars.count }
        var prev = Array(0...bChars.count)
        var curr = Array(repeating: 0, count: bChars.count + 1)
        for i in 1...aChars.count {
            curr[0] = i
            for j in 1...bChars.count {
                let cost = aChars[i - 1] == bChars[j - 1] ? 0 : 1
                curr[j] = min(prev[j] + 1, curr[j - 1] + 1, prev[j - 1] + cost)
            }
            swap(&prev, &curr)
        }
        return prev[bChars.count]
    }

    var body: some View {
        Group {
            if store.entries.isEmpty {
                ContentUnavailableView {
                    Label("Your life list is empty", systemImage: "bird")
                } description: {
                    Text("Tap the import button to load an eBird CSV export.")
                }
            } else {
                List {
                    ForEach(visibleRows) { row in
                        switch row {
                        case .existing(let entry):
                            existingRow(entry: entry)
                        case .suggestion(let sci, let com):
                            suggestionRow(scientificName: sci, commonName: com)
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .scrollBounceBehavior(.basedOnSize)
            }
        }
        .navigationTitle("Life List")
        .navigationSubtitle(speciesCountText)
        .toolbarTitleDisplayMode(.inlineLarge)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            BottomSearchField(text: $searchText, prompt: "Search species")
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showStarredOnly.toggle()
                } label: {
                    Image(systemName: "line.3.horizontal.decrease")
                        .foregroundStyle(showStarredOnly ? .white : .primary)
                        .frame(width: 28, height: 28)
                        .background {
                            Circle()
                                .fill(Color.accentColor)
                                .frame(
                                    width: showStarredOnly ? 36 : 28,
                                    height: showStarredOnly ? 36 : 28
                                )
                                .opacity(showStarredOnly ? 1 : 0)
                        }
                        .animation(.spring(response: 0.28, dampingFraction: 0.78), value: showStarredOnly)
                }
                .accessibilityLabel(showStarredOnly ? "Show all species" : "Show starred only")
            }
            ToolbarSpacer(.fixed, placement: .topBarTrailing)
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    isImporting = true
                } label: {
                    Image(systemName: "square.and.arrow.down")
                }
                .accessibilityLabel("Import eBird CSV")
            }
        }
        // Recompute catalog suggestions whenever the query changes, but
        // wait out a short debounce so mid-typing keystrokes don't each
        // kick off a 6,500-species scan. SwiftUI cancels the previous
        // task automatically when the id changes, so only the latest
        // query's scan ever publishes results.
        .task(id: searchText) {
            let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !q.isEmpty else {
                if !asyncSuggestions.isEmpty { asyncSuggestions = [] }
                return
            }
            do {
                try await Task.sleep(for: .milliseconds(160))
            } catch {
                return
            }
            let needle = q.lowercased()
            let lifeNames = Set(store.entries.map(\.scientificName))
            let lifeCommonNames = Set(store.entries.map { $0.commonName.lowercased() })
            let result = await Task.detached(priority: .userInitiated) {
                Self.computeSuggestions(
                    needle: needle,
                    excluding: lifeNames,
                    lifeCommonNames: lifeCommonNames
                )
            }.value
            guard !Task.isCancelled else { return }
            asyncSuggestions = result
        }
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [.commaSeparatedText, .plainText, .text],
            allowsMultipleSelection: false
        ) { result in
            Task { await handleImport(result) }
        }
        .alert("Import Complete", isPresented: $showImportResult, presenting: importMessage) { _ in
            Button("OK", role: .cancel) { }
        } message: { message in
            Text(message)
        }
        .alert(
            pendingDeletion.map { "Remove \($0.commonName) from your life list?" } ?? "",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            presenting: pendingDeletion
        ) { entry in
            Button("Delete", role: .destructive) {
                store.remove(scientificName: entry.scientificName)
                pendingDeletion = nil
            }
            Button("Cancel", role: .cancel) {
                pendingDeletion = nil
            }
        }
    }

    // Blue used by the "alert me" star toggle when on. Matches the blue
    // tint used for starred-species spectrogram bands + row highlights in
    // the Identify tab.
    private static let starButtonTint = Color(hue: 220.0 / 360.0, saturation: 0.7, brightness: 1.0)
    /// Purple used for the Identify-tab record button and the add-to-life
    /// -list circle on detection rows. Matched here so catalog suggestions
    /// feel like a continuation of that "you can add me" affordance.
    private static let addButtonTint = Color(hue: 252.0 / 360.0, saturation: 0.65, brightness: 1.0)

    @ViewBuilder
    private func existingRow(entry: LifeListEntry) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.commonName)
                    .font(.headline)
                HStack(spacing: 4) {
                    Text(entry.scientificName)
                        .italic()
                    Text("•")
                    Text(entry.firstSeen, format: .dateTime.year().month(.abbreviated).day())
                        .monospacedDigit()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                store.setStarred(
                    scientificName: entry.scientificName,
                    isStarred: !entry.isStarred
                )
            } label: {
                Group {
                    if entry.isStarred {
                        Image(systemName: "star.fill")
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundStyle(Self.starButtonTint)
                    } else {
                        Image(systemName: "star")
                            .font(.system(size: 24, weight: .regular))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 32, height: 32)
            }
            .buttonStyle(NoDimButtonStyle())
            .accessibilityLabel(
                entry.isStarred
                    ? "Turn off alerts for \(entry.commonName)"
                    : "Alert me when \(entry.commonName) is heard"
            )
            SpeciesThumbnail(scientificName: entry.scientificName)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .listRowInsets(EdgeInsets())
        .listRowSeparator(.hidden)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            // No `role: .destructive` — that role makes SwiftUI
            // pre-animate the row removal as soon as the button
            // is tapped, which is what causes the rows below to
            // slide up before the user has even confirmed.
            Button {
                pendingDeletion = entry
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .tint(.red)
        }
    }

    /// Catalog suggestion — species not yet on the life list. Trailing
    /// edge gets the purple add-to-life-list button instead of a star,
    /// so the tap is "I've seen this" rather than "alert me on this."
    @ViewBuilder
    private func suggestionRow(scientificName: String, commonName: String) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(commonName)
                    .font(.headline)
                Text(scientificName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .italic()
            }
            Spacer()
            Button {
                store.add(scientificName: scientificName, commonName: commonName)
            } label: {
                Image(systemName: "plus")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 32, height: 32)
                    .background(Self.addButtonTint, in: Circle())
            }
            .buttonStyle(NoDimButtonStyle())
            .accessibilityLabel("Add \(commonName) to Life List")
            SpeciesThumbnail(scientificName: scientificName)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .listRowInsets(EdgeInsets())
        .listRowSeparator(.hidden)
    }

    private var speciesCountText: String {
        let n = store.entries.count
        return "\(n) \(n == 1 ? "species" : "species")"
    }

    private func handleImport(_ result: Result<[URL], Error>) async {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            do {
                let summary = try await store.importEBird(from: url)
                importMessage = "Added \(summary.added) species. \(summary.updated) updated, \(summary.skipped) already known."
            } catch {
                importMessage = "Import failed: \(error.localizedDescription)"
            }
            showImportResult = true
        case .failure(let error):
            importMessage = "File picker error: \(error.localizedDescription)"
            showImportResult = true
        }
    }
}

/// ButtonStyle that doesn't dim or scale on press — used for the row
/// star + add buttons so taps don't darken them.
struct NoDimButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}

/// Liquid-glass search field that sits in the bottom safe-area inset, just
/// above the tab bar. Always expanded; tapping focuses the text field.
private struct BottomSearchField: View {
    @Binding var text: String
    let prompt: String
    @FocusState private var focused: Bool

    private var showCancel: Bool { focused || !text.isEmpty }

    var body: some View {
        HStack(spacing: 8) {
            // The search capsule itself — magnifying glass + text field.
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                ZStack(alignment: .leading) {
                    // Custom placeholder — the native prompt renders quite
                    // faint over glass; this one matches the icon's contrast.
                    if text.isEmpty {
                        Text(prompt)
                            .foregroundStyle(Color.primary.opacity(0.55))
                    }
                    TextField("", text: $text)
                        .textFieldStyle(.plain)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .focused($focused)
                        .submitLabel(.search)
                }
                // Standard inline clear button — appears only while there's
                // text. Clears the field without dropping focus, matching the
                // system search-field behavior.
                if !text.isEmpty {
                    Button {
                        text = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 17))
                            .foregroundStyle(.secondary)
                            // Hit target is a 44pt square (HIG minimum). The
                            // negative vertical padding below pulls the
                            // button's *reported* height back down to icon
                            // size so the capsule doesn't grow when the clear
                            // button appears.
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(NoDimButtonStyle())
                    // Negative padding pulls the 44pt hit-area's reported
                    // size back down so the capsule doesn't grow vertically
                    // and the icon sits flush with the capsule's right edge
                    // (otherwise the extra 12pt of frame to the right of the
                    // glyph creates visible asymmetric padding).
                    .padding(.vertical, -12)
                    .padding(.trailing, -12)
                    .accessibilityLabel("Clear search")
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
            .glassEffect(.regular, in: .capsule)

            // Standalone cancel-style button to the right of the capsule.
            // Action: clear text, drop focus, dismiss the keyboard.
            if showCancel {
                Button {
                    text = ""
                    focused = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 22, weight: .regular))
                        .foregroundStyle(.primary)
                        // Keep the outer circle the same height as the
                        // capsule (≈48pt). The icon grows inside the fixed
                        // 22pt frame; padding(13) keeps the glass circle
                        // sized to match the capsule.
                        .frame(width: 22, height: 22)
                        .padding(13)
                        .glassEffect(.regular.interactive(), in: .circle)
                        .contentShape(Circle())
                }
                .buttonStyle(NoDimButtonStyle())
                .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
        .animation(.spring(response: 0.28, dampingFraction: 0.85), value: showCancel)
    }
}

#Preview {
    NavigationStack {
        LifeListView()
    }
    .environment(LifeListStore())
}
