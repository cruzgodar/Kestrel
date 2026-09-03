import CoreLocation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct LifeListView: View {
    @Environment(LifeListStore.self) private var store
    /// Drives the full-screen viewer. Life-list rows open it over the whole
    /// ordered list so the user can swipe between birds.
    @Environment(SpeciesPhotoPresenter.self) private var photoPresenter: SpeciesPhotoPresenter?

    @State private var isImporting = false
    /// Drives the explanatory import modal opened from the toolbar button. The
    /// actual file picker (`isImporting`) is launched from its bottom button.
    @State private var showImportInfo = false
    @State private var importMessage: String?
    @State private var showImportResult = false
    /// Drives the explanatory export modal opened from the toolbar button. The
    /// system save panel (`ExportSession.isSaving`) is launched from its bottom
    /// button, mirroring the import flow.
    @State private var showExportInfo = false
    /// Everything one trip through the export sheet is partway through: the
    /// finished CSV, the scope it was built for, whether the save panel is up,
    /// and the run token that lets a render outlive its sheet without leaving
    /// any of that behind. See `ExportSession`.
    @State private var export = ExportSession()
    @State private var exportMessage: String?
    @State private var showExportResult = false
    /// Title for the export result alert. The same alert reports a finished
    /// save and a "there was nothing new to write" no-op, which want different
    /// headings.
    @State private var exportResultTitle = "Export Complete"
    /// Progress of an in-flight CSV render, shared with the export sheet so it
    /// can show a determinate bar over its own content.
    @State private var exportProgress = ExportProgress()
    /// Drives the "clear all entries" confirmation dialog.
    @State private var showClearAllConfirmation = false
    @State private var showStarredOnly = false
    /// Frozen set of scientific names captured when the starred-only filter
    /// is switched on. While filtering, membership is driven by this snapshot
    /// rather than live star state, so unstarring a bird leaves it on screen
    /// until the filter is toggled off and back on. See `displayedEntries`.
    @State private var starredSnapshot: Set<String> = []
    @State private var searchText = ""
    /// The list's scroll offset, so editing the query can send it back to the
    /// top — see the `searchText` change handler.
    @State private var scrollPosition = ScrollPosition()
    /// Global-space Y of the top edge of the bottom search field, measured so
    /// the tap-swallowing overlay (see `body`) knows where the list content
    /// stops being directly tappable.
    @State private var searchFieldTop: CGFloat = 0
    /// Cached geo range-filter allowed-index set, loaded once on appear. Used
    /// to split search results into in-range / out-of-range groups. `nil`
    /// when no location filter has been computed yet (no grouping then).
    @State private var allowedIndices: Set<Int>?
    /// Catalog suggestions for the current `searchText`. Computed off the
    /// main actor by a debounced `.task(id: searchText)`; reads here go
    /// straight into the rendered list. Empty while the user is still
    /// typing or when the query is too short to bother scanning 6,500
    /// species.
    @State private var asyncSuggestions: [SearchRow] = []
    /// Everything the rows' add / edit / delete affordances can be partway
    /// through — the date → map → name flow, the "which sighting?" chooser, and
    /// the delete confirmation. See `observationActions`.
    @State private var actions = ObservationActions()

    /// Row item rendered by the list. Life-list entries are sorted ahead
    /// of catalog suggestions so adding a missing species feels like a
    /// continuation of the list, not a different mode.
    enum SearchRow: Identifiable, Hashable {
        case existing(LifeListEntry)
        case suggestion(scientificName: String, commonName: String)
        /// Section divider inserted between in-range and out-of-range
        /// matches while searching.
        case header(String)

        var id: String {
            switch self {
            case .existing(let e):       return "e-" + e.scientificName
            case .suggestion(let s, _):  return "s-" + s
            case .header(let title):     return "h-" + title
            }
        }
    }

    /// The search query with surrounding whitespace stripped. Used both to
    /// decide whether the empty-state placeholder shows and to drive row
    /// filtering.
    private var trimmedSearch: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Life-list entries to display, honoring the starred filter via the
    /// frozen `starredSnapshot` so unstarring doesn't immediately drop a row.
    private var displayedEntries: [LifeListEntry] {
        guard showStarredOnly else { return store.entries }
        return store.entries.filter { starredSnapshot.contains($0.scientificName) }
    }

    /// `displayedEntries` narrowed by the search query — i.e. exactly the
    /// life-list rows on screen right now.
    ///
    /// Split out of `visibleRows` so the subtitle can count the same thing the
    /// list renders. It used to count `displayedEntries`, which ignores the query,
    /// under a comment claiming it matched the rows on screen — true with the
    /// filter alone, and wrong the moment anything was typed, which is the one
    /// case where the two differ.
    private var matchingEntries: [LifeListEntry] {
        Self.matchingEntries(displayedEntries, query: trimmedSearch)
    }

    /// The entries of `entries` that `query` matches, in their original order —
    /// an empty query matching everything.
    ///
    /// `nonisolated static`, like `partitionByRange` and `computeSuggestions`
    /// beside it, so the row set and the count that describes it can be checked
    /// against each other without a view.
    nonisolated static func matchingEntries(
        _ entries: [LifeListEntry],
        query: String
    ) -> [LifeListEntry] {
        guard !query.isEmpty else { return entries }
        let needle = query.lowercased()
        return entries.filter { entry in
            let hay = "\(entry.commonName) \(entry.scientificName)".lowercased()
            return scoreMatch(hay, needle: needle, allowFuzzy: needle.count >= 3) != nil
        }
    }

    /// The rows on screen: life-list entries (narrowed by the starred filter and
    /// the query) followed by catalog suggestions for the query.
    ///
    /// The starred filter and search deliberately do *not* compose. `base` is
    /// filtered to the starred snapshot, but `asyncSuggestions` isn't touched —
    /// so searching with the filter on surfaces catalog species that aren't
    /// starred (they can't be; a bird off the life list has nothing to star)
    /// while hiding life-list birds that aren't. Those birds fall out of
    /// `lifeMatches` here and are excluded from the suggestion scan by
    /// `lifeNames`, so they appear nowhere, under a subtitle still reading
    /// "Filtered to N starred species".
    ///
    /// Left as is on purpose: the filter's job is to narrow *your list*, and
    /// searching is how you add a bird that isn't on it yet — suppressing
    /// suggestions while filtering would make the filter a mode you had to leave
    /// before you could add anything. Worth knowing about before reading the
    /// subtitle as a description of everything below it.
    private var visibleRows: [SearchRow] {
        let lifeMatches = matchingEntries
        let q = trimmedSearch
        guard !q.isEmpty else { return lifeMatches.map { .existing($0) } }

        // Drop any suggestion the life list has since caught up with. The
        // background scan already excludes life-list species, but it runs behind
        // a debounce — without this filter a bird added mid-search renders twice
        // (as its new life-list row *and* as the stale suggestion) until the
        // rescan lands. Filtering here makes the swap happen on the same frame
        // the observation is written.
        let onList = store.speciesNames
        let fresh = asyncSuggestions.filter { row in
            guard case .suggestion(let sci, _) = row else { return true }
            return !onList.contains(sci)
        }
        let rows = lifeMatches.map { SearchRow.existing($0) } + fresh
        return Self.partitionByRange(rows, allowed: allowedIndices)
    }

    /// The species currently rendered, in screen order — the swipe list the
    /// full-screen photo viewer is opened over. This is `visibleRows` rather
    /// than the whole life list on purpose: whatever the user is looking at
    /// (a search's results, the starred-only filter's rows) is exactly what
    /// they can swipe between, so a viewer opened from a filtered list never
    /// pages into birds that weren't on screen.
    private var visibleNames: [String] {
        visibleRows.compactMap { row in
            switch row {
            case .existing(let entry):      return entry.scientificName
            case .suggestion(let sci, _):   return sci
            case .header:                   return nil
            }
        }
    }

    /// Opens the full-screen viewer on `scientificName` over the currently
    /// displayed list. Falls back to a lone-bird presentation if the row has
    /// somehow dropped out of the visible set between render and tap.
    private func presentPhoto(_ scientificName: String) {
        let names = visibleNames
        guard let idx = names.firstIndex(of: scientificName) else {
            photoPresenter?.present(scientificName)
            return
        }
        photoPresenter?.present(names: names, index: idx)
    }

    /// Splits search-result rows into in-range and out-of-range groups,
    /// putting the out-of-range matches below a "Birds not found in this
    /// area" header. When no location filter is cached (`allowed == nil`)
    /// the rows are returned unchanged. The relative order within each group
    /// is preserved.
    ///
    /// Lifers (existing life-list entries) are always treated as in-range so
    /// they group above the header regardless of where they were seen — a bird
    /// you've already recorded should surface instantly when searching, not get
    /// buried under "not found in this area." Only catalog suggestions
    /// (non-lifers) are range-tested, so that section contains non-lifers only.
    static func partitionByRange(_ rows: [SearchRow], allowed: Set<Int>?) -> [SearchRow] {
        guard let allowed else { return rows }
        let index = SpeciesCatalog.shared.indexByScientificName
        func inRange(_ row: SearchRow) -> Bool {
            switch row {
            case .existing:              return true
            case .header:                return true
            case .suggestion(let s, _):
                guard let i = index[s] else { return false }
                return allowed.contains(i)
            }
        }
        let here = rows.filter(inRange)
        let notHere = rows.filter { !inRange($0) }
        guard !notHere.isEmpty else { return here }
        return here + [.header("Birds not found in this area")] + notHere
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
    /// `allowed` is the geo range filter's allowed-index set (catalog indices).
    /// In-range species are ranked ahead of out-of-range ones *before* the
    /// 20-row cap, so a nearby bird always beats a closer name match that
    /// isn't found in the area — otherwise the truncation could drop every
    /// in-range suggestion before the view ever groups them.
    nonisolated static func computeSuggestions(
        needle: String,
        excluding lifeNames: Set<String>,
        lifeCommonNames: Set<String>,
        allowed: Set<Int>?
    ) -> [SearchRow] {
        let allowFuzzy = needle.count >= 3
        var scored: [(inRange: Bool, score: Int, scientific: String, common: String)] = []
        scored.reserveCapacity(64)
        for (idx, sp) in SpeciesCatalog.shared.all.enumerated() {
            if lifeNames.contains(sp.scientificName) { continue }
            if lifeCommonNames.contains(sp.commonName.lowercased()) { continue }
            guard let s = scoreMatch(sp.searchHay, needle: needle, allowFuzzy: allowFuzzy) else { continue }
            let inRange = allowed?.contains(idx) ?? false
            scored.append((inRange, s, sp.scientificName, sp.commonName))
        }
        return scored
            .sorted { a, b in
                // No location cached → rank by name score alone.
                if allowed != nil && a.inRange != b.inRange { return a.inRange }
                if a.score != b.score { return a.score < b.score }
                // Alphabetical past the score, so the cap below always keeps the
                // same twenty. Equal-scoring matches are the common case, not the
                // exception — a substring hit scores 0 for every species that
                // contains the query — and `Array.sorted` can return either
                // arrangement of equal elements, so without this the *contents*
                // of the truncated list, not merely its order, could change
                // between two scans of an unchanged catalog.
                if a.common != b.common { return a.common < b.common }
                return a.scientific < b.scientific
            }
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

    /// A few points of breathing room kept between the bottom search field and
    /// the screen edge, roughly matching the trailing `ToolbarSpacer` that nudges
    /// the heading buttons in (see the `.toolbar`). Not a pixel-perfect match —
    /// the toolbar spacer's width isn't queryable — just enough that the field and
    /// the buttons sit in from the edge by a similar amount.
    private static let headingButtonNudge: CGFloat = 6
    /// Symmetric horizontal inset of the bottom search field: the system toolbar
    /// margin (≈16pt) plus the small nudge above so the field stays centered while
    /// its right edge sits in from the edge like the heading buttons.
    private static let searchFieldHorizontalInset: CGFloat = 16 + headingButtonNudge

    var body: some View {
        // The List is always rendered (with the empty placeholder shown as an
        // overlay) rather than swapped out via if/else. Swapping the subtree
        // tears down and rebuilds the view tree the moment the first character
        // is typed into an empty-list search, which dropped the bottom search
        // field's focus as soon as results loaded. Keeping the List mounted
        // keeps that focus stable.
        List {
            ForEach(visibleRows) { row in
                switch row {
                case .existing(let entry):
                    existingRow(entry: entry)
                case .suggestion(let sci, let com):
                    suggestionRow(scientificName: sci, commonName: com)
                case .header(let title):
                    headerRow(title)
                }
            }

            // Sits at the very bottom of the list. Hidden while searching or
            // filtering so it doesn't interrupt the rows; only shown when
            // viewing the full, unfiltered list.
            if trimmedSearch.isEmpty && !store.entries.isEmpty && !showStarredOnly {
                HStack {
                    Spacer()
                    Button {
                        showClearAllConfirmation = true
                    } label: {
                        // Styled to match the record button but without the
                        // press scale/opacity feedback — this is a deliberate,
                        // confirmed-destructive action, not a tactile control.
                        Text("Delete All Entries")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(height: 26)
                            .padding(.horizontal, 28)
                            .padding(.vertical, 16)
                            .frame(minHeight: 50)
                            .background { Capsule(style: .continuous).fill(Color.red) }
                            .clipShape(Capsule(style: .continuous))
                    }
                    .buttonStyle(NoDimButtonStyle())
                    Spacer()
                }
                // Top gap kept in line with the inter-row spacing (rows use 4pt
                // vertical padding) so the button doesn't float; extra room is
                // left below it above the search field.
                .padding(.top, 4)
                .padding(.bottom, 16)
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .scrollBounceBehavior(.basedOnSize)
        .scrollPosition($scrollPosition)
        // Editing the search field resets the scroll to the top of the list.
        //
        // Addressed as an *edge* rather than as a row id. Scrolling to
        // `visibleRows.first?.id` used whichever id the list happened to hold at
        // that moment — and while the catalog scan is still behind its debounce
        // that is a stale suggestion, which the rescan then removes, leaving the
        // id pointing at nothing and the scroll silently not happening. The top
        // edge is always there, whatever the rows are doing.
        .onChange(of: searchText) { _, _ in
            withAnimation(.easeOut(duration: 0.2)) {
                scrollPosition.scrollTo(edge: .top)
            }
        }
        .overlay {
            // Empty-state placeholder — only when there's nothing to search
            // through *and* no active query. With a query present the List
            // still shows catalog suggestions so the user can build a life
            // list from scratch via search.
            if store.entries.isEmpty && trimmedSearch.isEmpty {
                ContentUnavailableView {
                    Label("Your life list is empty", systemImage: "bird")
                } description: {
                    Text("Search to add species manually, or tap the import button above to load a CSV export of your eBird life list.")
                }
            }
        }
        .navigationTitle("Life List")
        .navigationSubtitle(speciesCountText)
        // Keep the title big and leading-aligned on its own line (inlineLarge),
        // sitting level with the filter/import toolbar buttons.
        .toolbarTitleDisplayMode(.inlineLarge)
        // Switching away from the Life List tab clears the starred-only filter, so
        // returning always lands on the full list rather than a stale filtered view.
        // Fires on tab switches (the photo viewer is presented from the app root,
        // not here, so opening a photo doesn't trip this).
        .onDisappear {
            if showStarredOnly { showStarredOnly = false }
        }
        // Swallow taps in the bottom strip — the glass search field plus the
        // gap up to 4pt above its top — so taps meant for the search field or
        // tab bar don't fall through to the list rows scrolling beneath the
        // glass and errantly hit a row's star button or species thumbnail.
        // Placed *before* `safeAreaInset` so it sits above the list but below
        // the search field (which the inset renders on top); the tab bar lives
        // above this view entirely, so both stay tappable.
        .overlay {
            GeometryReader { geo in
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { }
                    .frame(height: max(geo.frame(in: .global).maxY - (searchFieldTop - 4), 0))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }
            // Without this the `safeAreaInset` below squeezes this overlay into
            // the region *above* the search field, so `geo…maxY` lands at the
            // field's top and the swallowing strip collapses to ~4pt (the bug).
            // Ignoring the bottom inset lets the GeometryReader reach the true
            // screen bottom, so the strip actually covers the field's footprint.
            // The overlay still sits below the field in z-order (the inset is
            // applied after), so the field's controls stay tappable.
            .ignoresSafeArea(.container, edges: .bottom)
            .allowsHitTesting(searchFieldTop > 0)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            BottomSearchField(
                text: $searchText,
                prompt: "Search or add species",
                horizontalInset: Self.searchFieldHorizontalInset,
                // The chooser counts too: an edit started from it runs the same
                // date → map → name flow, but out of that sheet's own draft
                // rather than this one, so watching `draft` alone would let the
                // keyboard flash back up between the steps of exactly those
                // edits. So does a pending delete — its confirmation is an alert
                // rather than a sheet, so it doesn't take first responder itself,
                // and a swipe-delete from a focused search left the keyboard
                // standing under the question.
                addFlowActive: actions.draft != nil
                    || actions.choice != nil
                    || actions.pendingDelete != nil
            )
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.frame(in: .global).minY
                } action: { searchFieldTop = $0 }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    // Re-snapshot the currently-starred species each time the
                    // filter is switched on. This frozen set drives which rows
                    // show while filtering, so unstarring leaves a bird visible
                    // until the filter is toggled off and on again.
                    if !showStarredOnly {
                        starredSnapshot = Set(
                            store.entries.lazy.filter(\.isStarred).map(\.scientificName)
                        )
                    }
                    showStarredOnly.toggle()
                } label: {
                    Image(systemName: "line.3.horizontal.decrease")
                        .foregroundStyle(showStarredOnly ? .white : .primary)
                        .frame(width: 28, height: 28)
                        .background {
                            // The star blue, not the app accent: the filter
                            // shows starred species, so it takes the color of
                            // the stars it filters to.
                            Circle()
                                .fill(Self.starButtonTint)
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
                    showImportInfo = true
                } label: {
                    Image(systemName: "square.and.arrow.down")
                }
                .accessibilityLabel("Import eBird CSV")
            }
            // No `ToolbarSpacer` between import and export: a spacer is what
            // breaks the Liquid Glass capsule, so leaving it out is what joins
            // the two into one. They are the same operation in two directions,
            // and they read as a pair rather than as two unrelated controls.
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showExportInfo = true
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .accessibilityLabel("Export eBird CSV")
            }
            // Trailing spacer to nudge the whole pair in from the screen edge.
            // An `.offset` on the buttons themselves only slid the glyphs inside
            // their fixed Liquid Glass capsules (the capsules are positioned by
            // the toolbar, not the button content); a `ToolbarSpacer` sits
            // outside the glass, so it moves the capsules as whole units.
            ToolbarSpacer(.fixed, placement: .topBarTrailing)
        }
        // Recompute catalog suggestions whenever the query changes, but
        // wait out a short debounce so mid-typing keystrokes don't each
        // kick off a 6,500-species scan. SwiftUI cancels the previous
        // task automatically when the id changes, so only the latest
        // query's scan ever publishes results. The id also tracks whether
        // the range filter has loaded, so suggestions re-rank for proximity
        // once the cached set arrives mid-search.
        //
        // The life-list size is in the id too, so the scan re-runs after an add
        // and tops the list back up to a full twenty suggestions. It is *not*
        // what stops the added bird from rendering twice — that's handled on the
        // same frame by the filter in `visibleRows`, since this scan only lands
        // after the debounce.
        .task(id: "\(searchText)|\(allowedIndices != nil)|\(store.entries.count)") {
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
            // The store's maintained membership set — the same one `visibleRows`
            // reads — rather than a fresh one built per scan.
            let lifeNames = store.speciesNames
            let lifeCommonNames = Set(store.entries.map { $0.commonName.lowercased() })
            let allowed = allowedIndices
            let result = await Task.detached(priority: .userInitiated) {
                Self.computeSuggestions(
                    needle: needle,
                    excluding: lifeNames,
                    lifeCommonNames: lifeCommonNames,
                    allowed: allowed
                )
            }.value
            guard !Task.isCancelled else { return }
            asyncSuggestions = result
        }
        // Load the cached geo range filter once so search results can be
        // grouped into in-range / out-of-range birds. Reads straight off
        // disk — no ORT session is constructed.
        .task {
            let allowed = await Task.detached(priority: .utility) {
                SpeciesRangeFilter.cachedAllowedIndices()
            }.value
            allowedIndices = allowed
        }
        // The add / edit / delete presentations, bundled into one modifier
        // rather than chained inline: this body's modifier chain is already long
        // enough that three more push the type-checker past its budget.
        .observationActions(actions, store: store)
        .sheet(isPresented: $showImportInfo) {
            ImportInfoSheet {
                // Dismiss the modal, then launch the system file picker on the
                // next runloop so the two presentations don't collide.
                showImportInfo = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    isImporting = true
                }
            }
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
        // Bundled into one modifier for the same reason `observationActions`
        // is: this body's chain is already at the type-checker's budget, and
        // three more presentations inline push it over.
        .modifier(ExportPresentations(
            showInfo: $showExportInfo,
            session: export,
            showResult: $showExportResult,
            resultTitle: $exportResultTitle,
            message: $exportMessage,
            progress: exportProgress,
            onExport: { scope in Task { await beginExport(scope: scope) } },
            onExported: handleExport(_:)
        ))
        .alert(
            "Delete your entire life list?",
            isPresented: $showClearAllConfirmation
        ) {
            Button("Delete All", role: .destructive) {
                store.removeAll()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text(clearAllMessage)
        }
    }

    // Blue used by the "alert me" star toggle when on, and by the filter button
    // that shows only starred species. Deliberately a stronger blue than the
    // Identify tab's starred-row wash and spectrogram band (hue 215, saturation
    // 0.5 — see `ContentView.starredTint`): those tint a whole row behind text
    // and have to stay pale to keep it readable, whereas this fills a small
    // glyph and needs the saturation to register at that size. Same family, two
    // jobs — they are not, and should not be, the same value.
    private static let starButtonTint = Color(hue: 220.0 / 360.0, saturation: 0.7, brightness: 1.0)
    /// Height of the trailing thumbnail on life-list and catalog-suggestion
    /// rows. Width follows at 4:3.
    private static let rowThumbnailHeight: CGFloat = 72

    @ViewBuilder
    private func existingRow(entry: LifeListEntry) -> some View {
        HStack(spacing: 12) {
            // Plain text, not a button: the row's actions are reached by
            // haptic touch anywhere on the row (see `.contextMenu` below), so
            // the name has no tap action of its own. The star and the
            // thumbnail keep theirs.
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.commonName)
                    .font(.headline)
                HStack(spacing: 4) {
                    // The CSV's Location column for the earliest sighting, shown
                    // in place of the scientific name. Falls back to a dash when
                    // an entry has no recorded location (e.g. manually added
                    // before a fix resolved).
                    if let location = entry.firstLocation, !location.isEmpty {
                        // Show the full place name, wrapping to as many lines as
                        // it needs rather than truncating with an ellipsis.
                        Text(location)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("•")
                    }
                    Text(entry.firstSeen, format: ObservationDate.dayStyle)
                        .monospacedDigit()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            // Stretch to the full row height (set by the trailing thumbnail)
            // so a haptic touch beside the text still lands on the row.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .foregroundStyle(.primary)
            Button {
                // A single short tap to confirm the star toggled.
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
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
            SpeciesThumbnail(scientificName: entry.scientificName, height: Self.rowThumbnailHeight, onTap: {
                // Open the viewer over the rows currently on screen, in screen
                // order, so swipes stay inside the active search / filter.
                presentPhoto(entry.scientificName)
            })
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        // The whole row opens the bird, not just its thumbnail. The star button
        // sits inside this shape but is a `Button`, so it claims its own taps
        // before they reach here.
        .contentShape(Rectangle())
        .onTapGesture { presentPhoto(entry.scientificName) }
        .listRowInsets(EdgeInsets())
        .listRowSeparator(.hidden)
        // Swiping the other way logs another sighting of a bird already on the
        // list, through the same date → map → name flow the plus button uses.
        // Full swipe is on here (and deliberately off for delete): running the
        // whole gesture just opens the add flow, which is undoable by backing
        // out, whereas a full-swipe delete would be a destructive action taken
        // without ever touching the button.
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                beginAdd(
                    scientificName: entry.scientificName,
                    commonName: entry.commonName
                )
            } label: {
                Label("Add Observation", systemImage: "plus")
            }
            .tint(Color.kestrelPurple)
        }
        // Trailing actions are laid out from the trailing edge inward in
        // declaration order, so Delete goes first to leave Edit sitting on its
        // left.
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            // No `role: .destructive` — that role makes SwiftUI
            // pre-animate the row removal as soon as the button
            // is tapped, which is what causes the rows below to
            // slide up before the user has even confirmed.
            Button {
                requestDelete(entry)
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .tint(.red)
            Button {
                requestEdit(entry)
            } label: {
                Label("Edit", systemImage: "pencil")
            }
            .tint(.kestrelEditGreen)
        }
        // Haptic touch anywhere on the row raises its actions — over the
        // thumbnail and star as well as the name.
        .contextMenu {
            SpeciesRowMenu(
                onEdit: { requestEdit(entry) },
                onAddObservation: {
                    beginAdd(
                        scientificName: entry.scientificName,
                        commonName: entry.commonName
                    )
                },
                star: (entry.isStarred, {
                    // The same single short tap the row's star button gives.
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    store.setStarred(
                        scientificName: entry.scientificName,
                        isStarred: !entry.isStarred
                    )
                }),
                onViewImage: { presentPhoto(entry.scientificName) },
                // Routed through the same chooser / confirmation as the swipe.
                onDelete: { requestDelete(entry) }
            )
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
            // Always a plus, never a checkmark: a suggestion row is by
            // definition a bird that isn't on the list yet, and confirming the
            // add flow puts it there — at which point the row is replaced by the
            // species' real life-list row on the same frame (see `visibleRows`).
            // There is no in-between state for a checkmark to describe.
            AddGlyphButton(isAdded: false) {
                // A Life List add is a bird the user is recalling, so it asks
                // when, then where, before writing anything. See `beginAdd`.
                beginAdd(scientificName: scientificName, commonName: commonName)
            }
            .accessibilityLabel("Add \(commonName) to Life List")
            SpeciesThumbnail(scientificName: scientificName, height: Self.rowThumbnailHeight, onTap: {
                // Suggestions are part of what's on screen, so they're part of
                // the swipe list too (see `presentPhoto`).
                presentPhoto(scientificName)
            })
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Same whole-row tap the life-list rows carry; the add button claims
        // its own taps.
        .contentShape(Rectangle())
        .onTapGesture { presentPhoto(scientificName) }
        .listRowInsets(EdgeInsets())
        .listRowSeparator(.hidden)
        // Redundant with the plus button sitting right there, but every other
        // row in the app adds by swiping and muscle memory shouldn't stop at
        // the search results.
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                beginAdd(scientificName: scientificName, commonName: commonName)
            } label: {
                Label("Add Observation", systemImage: "plus")
            }
            .tint(Color.kestrelPurple)
        }
        // Same haptic-touch menu the life-list rows carry, minus the two
        // actions a suggestion has nothing to apply them to: there is no entry
        // to delete, and no bird on the list yet to be alerted about.
        .contextMenu {
            SpeciesRowMenu(
                onAddObservation: {
                    beginAdd(scientificName: scientificName, commonName: commonName)
                },
                onViewImage: { presentPhoto(scientificName) }
            )
        }
    }

    // MARK: - Add / edit / delete

    /// Starts the add flow for a species: ask when the bird was seen, then
    /// where. Nothing is written to the store until the naming step is
    /// confirmed. The same flow serves both entry points — a catalog
    /// suggestion's plus creates the entry, while Add Observation files another
    /// sighting under a species that's already on the list.
    private func beginAdd(scientificName: String, commonName: String) {
        actions.add(scientificName: scientificName, commonName: commonName)
    }

    /// Edit, from a row that stands for the whole species. A bird seen once has
    /// only one sighting the row could mean, so that one is edited outright;
    /// with several on record the user is asked which.
    private func requestEdit(_ entry: LifeListEntry) {
        actions.edit(
            scientificName: entry.scientificName,
            commonName: entry.commonName,
            in: store
        )
    }

    /// Delete, the mirror of `requestEdit` — and never a "remove this bird"
    /// either way: what it deletes is one sighting, after a confirmation.
    private func requestDelete(_ entry: LifeListEntry) {
        actions.delete(
            scientificName: entry.scientificName,
            commonName: entry.commonName,
            in: store
        )
    }

    /// Section divider between in-range and out-of-range search matches.
    @ViewBuilder
    private func headerRow(_ title: String) -> some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 4)
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
    }

    /// The wording behind "Delete All Entries". The observation count is
    /// pluralized — the export result alert two modifiers up already does it, and
    /// "all 1 observations" reads as a bug in the middle of a confirmation the
    /// user is being asked to trust. ("Species" is its own plural, so the second
    /// count needs nothing.)
    private var clearAllMessage: String {
        let observations = store.totalObservationCount
        let noun = observations == 1 ? "observation" : "observations"
        return "Are you sure you want to permanently remove all "
            + "\(observations) \(noun) of \(store.entries.count) species from your "
            + "life list? This cannot be undone. Your stars will be preserved if "
            + "you re-add the species later."
    }

    private var speciesCountText: String {
        if showStarredOnly {
            // `matchingEntries`, so the subtitle counts the life-list rows
            // actually on screen: the frozen snapshot (unstarred-but-still-showing
            // birds included) *and* the search query, which the filter composes
            // with even though the suggestions below don't. Counting
            // `displayedEntries` named a number nothing on screen added up to as
            // soon as anything was typed.
            let n = matchingEntries.count
            return "Filtered to \(n) starred species"
        }
        let n = store.entries.count
        return "\(n) species"
    }

    /// Builds the CSV for `scope` and raises the system save panel over the
    /// export sheet, which stays up underneath while the picker is running.
    ///
    /// An export that turns out to have nothing to write never reaches the save
    /// panel — a headerless empty .csv is a file eBird rejects, and the reason
    /// it's empty is worth saying out loud. That is decided *here*, from the
    /// finished payload, rather than by asking the store to count the rows first:
    /// counting is the same walk as building them (see `LifeListStore.exportRows`)
    /// and the pre-check made every tap pay for it twice, on the main actor,
    /// before anything could be shown.
    ///
    /// The sheet does not survive the picker, however it ends: `handleExport`
    /// drops it on every path, cancellation included.
    ///
    /// **The render outlives the sheet, and is allowed to.** This is an
    /// unstructured task with no tie to the sheet's lifetime, and the sheet is
    /// swipe-dismissable throughout — so on the large life list the progress
    /// card exists for, the user can perfectly well swipe it away mid-render.
    /// Everything below the `applies` check writes state that sheet owns, and
    /// once it is gone nothing would ever read or clear it again: the save panel
    /// would be armed with nowhere to present, and the next visit to Export would
    /// open onto the previous run's file (or its "Nothing to Export" alert). So
    /// the run is tagged on the way in and the result is dropped if the sheet it
    /// belonged to has since been dismissed. See `ExportSession`.
    private func beginExport(scope: LifeListStore.ExportScope) async {
        let run = export.begin()
        exportProgress.fraction = 0
        // Reveal the progress card only if the render is still going a beat
        // later. A short life list finishes inside a frame or two, and flashing
        // a progress bar for one frame reads as a glitch.
        //
        // Raised through `setProgressVisible`, not written directly: cancellation
        // alone doesn't say whether this run is still the sheet's. This fires
        // 180 ms in, long before the render it belongs to finishes and cancels it,
        // so an export abandoned inside that window would otherwise leave the card
        // up with no sheet mounted to draw it.
        let reveal = Task {
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            export.setProgressVisible(true, run: run, on: exportProgress)
        }
        let payload = await store.makeEBirdExport(scope: scope, progress: exportProgress)
        reveal.cancel()
        // Everything below belongs to the sheet this run started from.
        guard export.applies(run) else { return }
        if exportProgress.isVisible {
            // It got far enough to appear, so hold it long enough to read
            // rather than blinking out the instant the last row renders. The
            // sheet can go away across that sleep, which is why the hide is
            // gated too rather than trusting the guard above.
            try? await Task.sleep(for: .milliseconds(320))
            export.setProgressVisible(false, run: run, on: exportProgress)
        }

        // Nothing to hand eBird. Reported over the still-standing sheet, so the
        // other button is one tap away.
        guard payload.observationCount > 0 else {
            export.reportEmpty(scope: scope)
            return
        }

        // The sheet stays up and the save panel comes up over it, rather than
        // the sheet leaving first and the picker following it a beat later.
        // `.fileExporter` is attached to the sheet's own content for exactly
        // that reason — see `ExportInfoSheet`. The sheet is then dropped by
        // `handleExport` whichever way the picker ends.
        export.present(payload: payload, scope: scope)
    }

    private func handleExport(_ result: Result<URL, Error>) {
        // Read before the `defer` clears them.
        let payload = export.payload
        let scope = export.scope
        // Cleared by the cancellation path below, which has nothing to report.
        var shouldReportResult = true
        defer {
            export.finish()
            // The picker was presented from the export sheet, so the sheet is
            // still standing underneath. Drop it, then let it finish leaving
            // before the alert goes up — an alert raised from a view that's on
            // its way out never appears.
            showExportInfo = false
            if shouldReportResult {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    showExportResult = true
                }
            }
        }
        switch result {
        case .success:
            guard let payload else {
                shouldReportResult = false
                return
            }
            exportResultTitle = "Export Complete"
            // Only a saved file eBird can actually take counts as handing
            // observations over — see `LifeListStore.recordsHandover`. The save
            // having happened at all is this branch; the rest is that call.
            if let scope,
               LifeListStore.recordsHandover(
                   scope: scope, exceedsSizeLimit: payload.exceedsEBirdSizeLimit
               ) {
                store.markExported(payload.exportedKeys)
            }
            var parts = [
                "Saved \(payload.observationCount) "
                    + (payload.observationCount == 1 ? "observation" : "observations")
                    + " of \(payload.speciesCount) species."
            ]
            if payload.unplaceableCount > 0 {
                parts.append(
                    "\(payload.unplaceableCount) had no location recorded at all and will need one picked during eBird\u{2019}s import cleanup."
                )
            }
            if payload.exceedsEBirdSizeLimit {
                parts.append(
                    "Heads up: the file is over eBird\u{2019}s 1 MB import limit, so you\u{2019}ll need to split it before uploading."
                )
                // Say so explicitly. These observations are deliberately *not*
                // marked as handed over (see `LifeListStore.recordsHandover`),
                // and a user who splits and uploads this file by hand needs to
                // know the next Export New will offer them again rather than
                // come back empty.
                if scope == .newOnly {
                    parts.append(
                        "They\u{2019}re still counted as new, so Export New Observations will include them again."
                    )
                }
            }
            exportMessage = parts.joined(separator: " ")
        case .failure(let error):
            // Backing out of the save panel arrives here as `userCancelled`,
            // not as a real error. Reporting it would pop an "Export Failed"
            // alert carrying a raw Cocoa error string for what was a deliberate
            // choice, so it's swallowed and the sheet simply closes.
            guard !Self.isUserCancellation(error) else {
                shouldReportResult = false
                return
            }
            exportResultTitle = "Export Failed"
            exportMessage = error.localizedDescription
        }
    }

    /// Whether a file-picker error is really the user backing out. Both pickers
    /// report a cancel through their failure path rather than a separate
    /// callback, so both have to tell the two apart.
    private static func isUserCancellation(_ error: Error) -> Bool {
        if (error as? CocoaError)?.code == .userCancelled { return true }
        // Domain checked as well as code: 3072 means "cancelled" only in Cocoa's
        // domain, and a bare code comparison would swallow an unrelated failure
        // that happened to share the number.
        let nsError = error as NSError
        return nsError.domain == NSCocoaErrorDomain && nsError.code == NSUserCancelledError
    }

    private func handleImport(_ result: Result<[URL], Error>) async {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            do {
                let summary = try await store.importEBird(from: url)
                // Only surface non-zero clauses so the result never reads
                // "0 already known" or similar.
                var parts: [String] = []
                if summary.newObservations > 0 {
                    parts.append(
                        "Added \(summary.newObservations) "
                            + (summary.newObservations == 1 ? "observation" : "observations")
                            + " of \(summary.speciesWithNewObservations) species."
                    )
                }
                if summary.added > 0 { parts.append("\(summary.added) new to your life list.") }
                // Its own clause rather than folded into the count above: these
                // species gained no sightings, so counting them there overstated
                // the import — and when they were *all* the import did, the whole
                // summary collapsed to "Nothing new to import" over a list whose
                // first-seen dates had just moved.
                if summary.revised > 0 {
                    parts.append(
                        summary.revised == 1
                            ? "1 now has an earlier first sighting."
                            : "\(summary.revised) now have earlier first sightings."
                    )
                }
                if summary.skipped > 0 { parts.append("\(summary.skipped) already known.") }
                importMessage = parts.isEmpty
                    ? "Nothing new to import."
                    : parts.joined(separator: " ")
            } catch {
                importMessage = "Import failed: \(error.localizedDescription)"
            }
            showImportResult = true
        case .failure(let error):
            // A cancelled picker is a choice, not an error — say nothing.
            guard !Self.isUserCancellation(error) else { return }
            importMessage = "File picker error: \(error.localizedDescription)"
            showImportResult = true
        }
    }
}

/// ButtonStyle that doesn't dim or scale on press — used for the row
/// star buttons so taps don't darken them.
struct NoDimButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}


/// The export flow's three presentations — the explanatory sheet, the system
/// save panel, and the result alert — lifted out of `LifeListView.body` to keep
/// its modifier chain inside the type-checker's budget.
private struct ExportPresentations: ViewModifier {
    @Binding var showInfo: Bool
    /// Everything the sheet is partway through. Held as the object rather than
    /// as a fistful of bindings so dismissing the sheet can put *all* of it back
    /// — see `ExportSession.abandon`.
    @Bindable var session: ExportSession
    @Binding var showResult: Bool
    @Binding var resultTitle: String
    @Binding var message: String?
    let progress: ExportProgress
    let onExport: (LifeListStore.ExportScope) -> Void
    let onExported: (Result<URL, Error>) -> Void

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $showInfo, onDismiss: {
                // Everything the export sheet owns goes with the export sheet.
                // Its render is not tied to its lifetime and routinely outlives
                // it (see `LifeListView.beginExport`), so anything left set here
                // is state nothing on screen can show, clear, or answer for —
                // an armed save panel with nowhere to present, or a "Nothing to
                // Export" alert about an attempt the user already abandoned.
                session.abandon()
                progress.isVisible = false
            }) {
                ExportInfoSheet(
                    progress: progress,
                    session: session,
                    onExport: onExport,
                    onExported: onExported
                )
            }
            .alert(resultTitle, isPresented: $showResult, presenting: message) { _ in
                Button("OK", role: .cancel) { }
            } message: { message in
                Text(message)
            }
    }
}


/// Explanatory modal shown before importing. Describes the eBird/Merlin
/// workflow (with an inline link to download the data) and offers an import
/// button at the bottom that hands off to the system file picker via `onImport`.
private struct ImportInfoSheet: View {
    /// Invoked when the user taps the bottom Import button. The caller dismisses
    /// the sheet and launches the file picker.
    let onImport: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 16) {
                Image(systemName: "square.and.arrow.down")
                    .font(.system(size: 44, weight: .regular))
                    .foregroundStyle(Color.accentColor)
                    .padding(.top, 8)
                Text("Import Your Life List")
                    .font(.title2.weight(.bold))
                    .multilineTextAlignment(.center)
                // Markdown so "download your eBird data" renders as an inline
                // tappable link to eBird's data-download page.
                Text(.init("If you track the birds you\u{2019}ve seen with eBird or Merlin, you can import them to Kestrel. First [download your eBird data](https://ebird.org/downloadMyData), then import the CSV file here."))
                    .font(.body)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .tint(.accentColor)
            }
            .padding(.horizontal, 28)

            Spacer(minLength: 0)

            Button {
                onImport()
            } label: {
                Text("Import CSV File")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(height: 26)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background { Capsule(style: .continuous).fill(Color.accentColor) }
            }
            .buttonStyle(NoDimButtonStyle())
            .padding(.horizontal, 28)
            .padding(.bottom, 12)
        }
        .padding(.top, 32)
        // Fill the full sheet width at the outermost level. The content is
        // otherwise intrinsically narrower than the sheet, so the sheet centers
        // it — and that centering resolves from leading→center *during* the
        // present, which is the horizontal "slide-in". Pinning it to full width
        // here (outside all padding) removes the alignment ambiguity.
        .frame(maxWidth: .infinity)
        // The grab handle is hidden here as on every sheet in the app, so this
        // is what keeps the only way out from being a swipe nobody is told
        // about — the same rule `ObservationPickerSheet` states.
        .overlay(alignment: .topLeading) { SheetCloseButton { dismiss() } }
        .presentationDetents([.medium])
        // Hidden grab handle to match the map's settings card (MapCardSheet).
        .presentationDragIndicator(.hidden)
    }
}

/// The small close control both explanatory sheets carry.
///
/// Every other sheet in the app hides its grab handle and puts a cancel button
/// in a `NavigationStack` toolbar instead. These two have no navigation bar —
/// their layout is tuned around a fixed detent and a bottom action button — so
/// the same affordance is drawn directly, in the same top-leading corner, as an
/// overlay that takes no part in the layout it sits over.
private struct SheetCloseButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 30, height: 30)
                .background(Color.primary.opacity(0.08), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(NoDimButtonStyle())
        .padding(.top, 12)
        .padding(.leading, 16)
        .accessibilityLabel("Close")
    }
}

/// Explanatory modal shown before exporting, the mirror of `ImportInfoSheet`.
///
/// It carries a warning the import side doesn't need: eBird's import tool does
/// no deduplication whatsoever, so re-uploading records it already has creates a
/// second copy of every one of them. Kestrel keeps a ledger of what it has
/// already handed over (`LifeListStore.exportedObservationKeys`), which is what
/// makes the "new observations only" choice below possible — and what lets
/// someone top up their eBird account every few months without duplicating
/// their history.
private struct ExportInfoSheet: View {
    let progress: ExportProgress
    /// What this trip through the sheet is partway through. The save panel is
    /// presented from *this* sheet rather than from the Life List, so it layers
    /// over the buttons instead of making them leave first — cancelling the
    /// picker lands back here — and the "Nothing to Export" alert is raised here
    /// for the same reason, leaving the other button one tap away.
    @Bindable var session: ExportSession
    /// Invoked with the scope of whichever button was tapped.
    let onExport: (LifeListStore.ExportScope) -> Void
    let onExported: (Result<URL, Error>) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 16) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 44, weight: .regular))
                    .foregroundStyle(Color.accentColor)
                    .padding(.top, 8)
                Text("Export Your Life List")
                    .font(.title2.weight(.bold))
                    .multilineTextAlignment(.center)
                // Markdown so the import-tool phrase renders as an inline
                // tappable link, matching the import sheet's treatment.
                Text(.init("You can export all your observations as a backup or to [import to eBird](https://ebird.org/import/upload.form). Since eBird doesn\u{2019}t check for duplicates, choose Export New Observations to include only the observations made since your last export."))
                    .font(.body)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .tint(.accentColor)
            }
            .padding(.horizontal, 28)

            Spacer(minLength: 0)

            // Two destinations rather than a picker plus one button, so each
            // tap is a single decision. The recommended option takes the
            // accent-colored bottom slot — the one the thumb lands on and the
            // one the import sheet trained the eye to look for — and the
            // duplicate-risking one is deliberately the quieter button above.
            VStack(spacing: 12) {
                Button {
                    onExport(.everything)
                } label: {
                    Text("Export All Observations")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.primary)
                        .frame(height: 26)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background {
                            Capsule(style: .continuous).fill(Color.primary.opacity(0.08))
                        }
                }
                .buttonStyle(NoDimButtonStyle())

                Button {
                    onExport(.newOnly)
                } label: {
                    Text("Export New Observations")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(height: 26)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background { Capsule(style: .continuous).fill(Color.accentColor) }
                }
                .buttonStyle(NoDimButtonStyle())
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 12)
        }
        .padding(.top, 32)
        // Full sheet width at the outermost level, for the same reason the
        // import sheet pins it — see the comment there.
        .frame(maxWidth: .infinity)
        // A disclosed way out, for the reason the import sheet carries one.
        .overlay(alignment: .topLeading) { SheetCloseButton { dismiss() } }
        // Taller than the import sheet's `.medium`: this one carries a second
        // button and a longer explanation, and at `.medium` the last line of
        // copy gets truncated rather than wrapped.
        .presentationDetents([.fraction(0.62)])
        .presentationDragIndicator(.hidden)
        .fileExporter(
            isPresented: $session.isSaving,
            document: session.document,
            contentType: .commaSeparatedText,
            defaultFilename: EBirdCSVExporter.defaultFilename()
        ) { result in
            onExported(result)
        }
        // Dim + card over the sheet's own content while the CSV renders, rather
        // than a second presentation on top of this one. Only ever on screen
        // for a list big enough to take a moment (see `beginExport`).
        .overlay {
            if progress.isVisible {
                ExportProgressCard(fraction: progress.fraction)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: progress.isVisible)
        // Attached to the sheet, not the Life List behind it, so reporting an
        // empty result leaves the sheet standing and the other button one tap
        // away.
        .alert(
            "Nothing to Export",
            isPresented: Binding(
                get: { session.emptyScope != nil },
                set: { if !$0 { session.emptyScope = nil } }
            ),
            presenting: session.emptyScope
        ) { _ in
            Button("OK", role: .cancel) { session.emptyScope = nil }
        } message: { scope in
            Text(emptyMessage(for: scope))
        }
    }

    private func emptyMessage(for scope: LifeListStore.ExportScope) -> String {
        switch scope {
        case .newOnly:
            return "Every sighting on your life list either came from an eBird import or has already been exported. Tap \u{201C}Export All Observations\u{201D} to include them anyway."
        case .everything:
            return "Your life list is empty, so there is nothing to export."
        }
    }
}

/// Everything one trip through the export sheet is partway through, and the run
/// token that keeps a render from outliving it.
///
/// **Why this is one object rather than five `@State` flags.** The CSV render is
/// an unstructured task started from a button in the sheet, and nothing ties it
/// to the sheet's lifetime — the sheet is swipe-dismissable for the whole of it,
/// and on the large life list the progress card exists for that is seconds of
/// opportunity. Every field here is written *after* the render finishes, and
/// every one of them is read only by the sheet, so a result that lands after the
/// sheet has gone leaves state nothing can show, clear, or answer for:
///
///   • `isSaving` arms a `.fileExporter` attached to the unmounted sheet. It
///     never presents, and SwiftUI only clears an `isPresented` binding when the
///     presentation it drives actually dismisses — so it stays armed, and the
///     *next* visit to Export opens straight into a save panel for the previous
///     run's file, still carrying `payload` and `scope` to mark exported.
///   • `emptyScope` pops "Nothing to Export" on that next visit, about an attempt
///     the user abandoned. (Clearing it from the sheet's `onDismiss` alone did
///     not fix this: dismissal completes in a third of a second and the render it
///     is racing runs for seconds, so the clear happens *first* and the stale
///     write lands after it.)
///
/// So a run is tagged on the way in (`begin`), checked on the way out
/// (`applies`), and `abandon` — which the sheet's `onDismiss` calls — retires the
/// token along with everything else. A run whose token has been retired drops its
/// result on the floor, which is the only correct thing left to do with it.
///
/// A reference type for the same reason `ExportProgress` is: it is handed to a
/// `ViewModifier` and a sheet that both need the live value, and it is
/// main-actor isolated by the project's default.
@Observable
final class ExportSession {
    /// Names the run in flight. Monotonic; `abandon` bumps it to retire whatever
    /// was outstanding, so a stale run can never be mistaken for the current one.
    private(set) var run = 0
    /// Whether the system save panel is up.
    var isSaving = false
    /// The CSV the save panel is writing.
    private(set) var document: EBirdCSVDocument?
    /// The payload behind `document`, kept so a successful save can mark exactly
    /// the observations in *this* file as exported.
    private(set) var payload: EBirdCSVExporter.Payload?
    /// The scope `payload` was built for. Only a `.newOnly` save marks its
    /// observations as exported — see `LifeListView.handleExport`.
    private(set) var scope: LifeListStore.ExportScope?
    /// The scope whose export turned out to have nothing to write, driving the
    /// sheet's "Nothing to Export" alert.
    ///
    /// Decided out here rather than by the sheet, because the sheet can no longer
    /// tell: it used to ask `LifeListStore.observationCount(for:)` before handing
    /// off, which walked (and key-built) the whole life list on the main actor a
    /// second time for every tap. The answer now comes from the payload the
    /// export already produced — see `LifeListView.beginExport`.
    var emptyScope: LifeListStore.ExportScope?

    /// Starts a run and returns its token. Also retires any earlier run, so two
    /// taps in quick succession can't both land.
    @discardableResult
    func begin() -> Int {
        run &+= 1
        return run
    }

    /// Whether a finished run is still the one the sheet is waiting on.
    func applies(_ token: Int) -> Bool { token == run }

    /// Shows or hides the render's progress card on behalf of `token` — and does
    /// nothing if that run is no longer the sheet's.
    ///
    /// The card is the one piece of a run's state that is *shared*, so it needs a
    /// gate of its own rather than relying on the caller's. Two renders can be in
    /// flight against one sheet — Export All and then Export New, tapped inside
    /// the 180 ms before the card appears and starts swallowing taps — and the
    /// card on screen belongs to whichever started last. A superseded run hiding
    /// it left that render running behind a blank sheet, with its own reveal
    /// already fired and no second one coming. A run whose sheet has since been
    /// dismissed must not raise it either, or `isVisible` stays true with nothing
    /// mounted to draw it and the next visit to Export opens onto a progress card
    /// over nothing.
    ///
    /// Returns whether the write landed, so a caller can tell the two apart.
    @discardableResult
    func setProgressVisible(
        _ visible: Bool,
        run token: Int,
        on progress: ExportProgress
    ) -> Bool {
        guard applies(token) else { return false }
        progress.isVisible = visible
        return true
    }

    /// The run produced a file; arm the save panel over it.
    func present(payload: EBirdCSVExporter.Payload, scope: LifeListStore.ExportScope) {
        self.payload = payload
        self.scope = scope
        document = EBirdCSVDocument(data: payload.csv)
        isSaving = true
    }

    /// The run produced nothing; say so over the sheet.
    func reportEmpty(scope: LifeListStore.ExportScope) {
        emptyScope = scope
    }

    /// The save panel closed, however it closed. Drops the file but leaves the
    /// run token alone — nothing is outstanding at this point.
    func finish() {
        payload = nil
        scope = nil
        document = nil
    }

    /// The sheet went away. Retires the run in flight and clears everything it
    /// could still have written.
    func abandon() {
        run &+= 1
        isSaving = false
        payload = nil
        scope = nil
        document = nil
        emptyScope = nil
    }
}

/// Progress of an in-flight CSV render. A shared reference type rather than
/// plain `@State` so the value can be handed to `LifeListStore` and updated
/// from the render's detached task (this class is main-actor isolated by the
/// project's default, which is what makes it safe to pass across).
@Observable
final class ExportProgress {
    /// 0...1.
    var fraction: Double = 0
    /// Whether the card is on screen. Raised on a delay so a short life list —
    /// which renders in a frame or two — never flashes one.
    var isVisible = false
}

/// The card shown over the export sheet while its CSV renders.
private struct ExportProgressCard: View {
    let fraction: Double

    var body: some View {
        ZStack {
            Color.black.opacity(0.18)
                .ignoresSafeArea()
            VStack(spacing: 14) {
                Text("Preparing Export\u{2026}")
                    .font(.headline)
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                    .tint(Color.accentColor)
                Text("\(Int((fraction * 100).rounded()))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 22)
            .frame(maxWidth: 260)
            .background(.regularMaterial, in: .rect(cornerRadius: 20, style: .continuous))
        }
    }
}

/// Minimal `FileDocument` wrapper so `.fileExporter` can hand the already-built
/// CSV bytes to the system save panel. Write-only in practice — the read
/// initializer exists solely to satisfy the protocol; importing goes through
/// `EBirdCSVParser` instead.
nonisolated struct EBirdCSVDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.commaSeparatedText] }

    var data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        guard let contents = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        data = contents
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

/// Liquid-glass search field that sits in the bottom safe-area inset, just
/// above the tab bar. Always expanded; tapping anywhere on the capsule focuses
/// the text field.
private struct BottomSearchField: View {
    @Binding var text: String
    let prompt: String
    /// Symmetric horizontal inset, set by the parent so the field stays centered
    /// while its right edge lines up with the rightmost heading button.
    var horizontalInset: CGFloat = 10
    /// True while the add flow (date sheet → map picker) owns the screen. Focus
    /// is dropped when it goes up: SwiftUI restores first responder every time
    /// one of the flow's presentations dismisses, so without this the keyboard
    /// slides back up and straight down again between each step.
    var addFlowActive: Bool = false
    @FocusState private var focused: Bool
    /// The capsule's own bounds, used to decide whether a lifted finger counts
    /// as a tap on it. See the gesture in `body`.
    @State private var capsuleBounds: CGRect = .zero
    /// Drives the full-screen photo viewer. When a species photo opens (e.g. the
    /// user taps a row's thumbnail while searching), we drop focus so the
    /// keyboard doesn't pop back up when the viewer is dismissed.
    @Environment(SpeciesPhotoPresenter.self) private var photoPresenter: SpeciesPhotoPresenter?

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
            .glassEffect(.regular.interactive(), in: .capsule)
            // The whole capsule is the hit target, not just the text field's own
            // bounds. Without this, only a direct hit on the (often narrow, and
            // when empty, zero-width) `TextField` focused the field — taps on the
            // magnifying glass, the padding, or the empty space right of a short
            // query fell through and did nothing. `.contentShape` also keeps the
            // gesture from claiming the corners outside the capsule.
            .contentShape(.capsule)
            // Focus when the finger lifts inside the capsule. Attached
            // *simultaneously* so it recognizes alongside the text field's own
            // recognizers rather than pre-empting them — as a plain `.gesture` it
            // swallowed taps that landed on the field itself, which would leave the
            // caret pinned to the end of the text instead of where the user tapped.
            // A zero-distance drag rather than a tap so the touch is claimed on
            // touch-down, which is when the interactive glass lights up.
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onEnded { value in
                        // Only a lift inside the capsule counts; one that wandered
                        // off is a cancel, matching how a system control behaves.
                        guard capsuleBounds.contains(value.location) else { return }
                        focused = true
                    }
            )
            // The capsule's own bounds, so the drag above can tell a lift inside it
            // from one that wandered off.
            .onGeometryChange(for: CGRect.self) { proxy in
                CGRect(origin: .zero, size: proxy.size)
            } action: { capsuleBounds = $0 }

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
        .padding(.horizontal, horizontalInset)
        .padding(.bottom, 8)
        .animation(.spring(response: 0.28, dampingFraction: 0.85), value: showCancel)
        // Opening a species photo resigns focus permanently — without this the
        // keyboard slides back up when the full-screen viewer is dismissed.
        .onChange(of: photoPresenter?.presented) { _, presented in
            if presented != nil { focused = false }
        }
        // Same idea for the add flow, but held for its whole duration: focus is
        // dropped the moment the plus is tapped and stays dropped across the
        // date-sheet ⇄ map hand-offs, so no step is preceded by the keyboard
        // flashing up and back down.
        .onChange(of: addFlowActive) { _, active in
            if active { focused = false }
        }
    }
}

#Preview {
    NavigationStack {
        LifeListView()
    }
    .environment(LifeListStore())
}
