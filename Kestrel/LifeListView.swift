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
    /// The species the user just swiped to delete — drives the confirmation
    /// dialog. Cleared on Cancel; the actual remove happens on confirm.
    @State private var pendingDeletion: LifeListEntry?
    /// Drives the "clear all entries" confirmation dialog.
    @State private var showClearAllConfirmation = false
    @State private var showStarredOnly = false
    /// Frozen set of scientific names captured when the starred-only filter
    /// is switched on. While filtering, membership is driven by this snapshot
    /// rather than live star state, so unstarring a bird leaves it on screen
    /// until the filter is toggled off and back on. See `displayedEntries`.
    @State private var starredSnapshot: Set<String> = []
    @State private var searchText = ""
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
    /// The species partway through the add flow (pick a date, then a location),
    /// along with the date chosen so far. Non-nil for as long as the flow is on
    /// screen; the map is presented *over* the date sheet rather than in place
    /// of it, so both are torn down together when the flow ends.
    @State private var pendingAdd: PendingAdd?
    @State private var showAddDate = false
    @State private var showAddLocation = false

    /// A species awaiting its observation date and location before it's written
    /// to the life list. Nothing is stored until the location is confirmed, so
    /// abandoning either step leaves the list untouched.
    private struct PendingAdd {
        let scientificName: String
        let commonName: String
        var date: Date
    }

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

    private var visibleRows: [SearchRow] {
        let base = displayedEntries
        let q = trimmedSearch
        guard !q.isEmpty else { return base.map { .existing($0) } }
        let needle = q.lowercased()

        let lifeMatches = base.filter { entry in
            let hay = "\(entry.commonName) \(entry.scientificName)".lowercased()
            return Self.scoreMatch(hay, needle: needle, allowFuzzy: needle.count >= 3) != nil
        }

        let rows = lifeMatches.map { SearchRow.existing($0) } + asyncSuggestions
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
    private static func partitionByRange(_ rows: [SearchRow], allowed: Set<Int>?) -> [SearchRow] {
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
                return a.score < b.score
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
        ScrollViewReader { proxy in
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
        // Editing the search field resets the scroll to the top of the list.
        .onChange(of: searchText) { _, _ in
            if let topID = visibleRows.first?.id {
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(topID, anchor: .top)
                }
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
                addFlowActive: pendingAdd != nil
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
        // The life-list size is in the id too: `computeSuggestions` excludes
        // birds already on the list, so adding one mid-search has to drop its
        // suggestion row — otherwise the bird renders twice, once as the stale
        // suggestion and once as the new life-list match.
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
            let lifeNames = Set(store.entries.map(\.scientificName))
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
        // The two-step add flow's presentations. Bundled into one modifier
        // rather than chained inline: this body's modifier chain is already
        // long enough that two more presentations push the type-checker past
        // its budget.
        .modifier(AddFlowPresentations(
            showDate: $showAddDate,
            showLocation: $showAddLocation,
            date: Binding(
                get: { pendingAdd?.date ?? Date() },
                set: { pendingAdd?.date = $0 }
            ),
            store: store,
            onDismissed: { pendingAdd = nil },
            onSave: commitPendingAdd(at:name:)
        ))
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
        .alert(
            "Delete your entire life list?",
            isPresented: $showClearAllConfirmation
        ) {
            Button("Delete All", role: .destructive) {
                store.removeAll()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Are you sure you want to permanently remove all \(store.entries.count) species from your life list? This cannot be undone. Your stars will be preserved if you re-add the species later.")
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

    /// Height of the trailing thumbnail on life-list and catalog-suggestion
    /// rows. Width follows at 4:3.
    private static let rowThumbnailHeight: CGFloat = 72

    @ViewBuilder
    private func existingRow(entry: LifeListEntry) -> some View {
        HStack(spacing: 12) {
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
                    Text(entry.firstSeen, format: .dateTime.year().month(.abbreviated).day())
                        .monospacedDigit()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
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
        .listRowInsets(EdgeInsets())
        .listRowSeparator(.hidden)
        // Swiping the other way logs another sighting of a bird already on the
        // list, through the same date → map → name flow the plus button uses.
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            Button {
                beginAdd(
                    scientificName: entry.scientificName,
                    commonName: entry.commonName
                )
            } label: {
                Label("Add Again", systemImage: "plus")
            }
            .tint(Self.addButtonTint)
        }
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
        // Haptic-touch menu: the same four things the row can do, gathered in
        // one place for people who don't discover the swipes.
        .contextMenu {
            Button {
                beginAdd(
                    scientificName: entry.scientificName,
                    commonName: entry.commonName
                )
            } label: {
                Label("Add Again", systemImage: "plus")
            }
            Button {
                store.setStarred(
                    scientificName: entry.scientificName,
                    isStarred: !entry.isStarred
                )
            } label: {
                // Mirrors the row's own star button, which is a toggle.
                Label(
                    entry.isStarred ? "Unstar" : "Star",
                    systemImage: entry.isStarred ? "star.slash" : "star"
                )
            }
            Button {
                presentPhoto(entry.scientificName)
            } label: {
                Label("View Image", systemImage: "photo")
            }
            // Routed through the same confirmation alert as the swipe.
            Button(role: .destructive) {
                pendingDeletion = entry
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    /// Catalog suggestion — species not yet on the life list. Trailing
    /// edge gets the purple add-to-life-list button instead of a star,
    /// so the tap is "I've seen this" rather than "alert me on this."
    @ViewBuilder
    private func suggestionRow(scientificName: String, commonName: String) -> some View {
        // Once added this session the row keeps its place but swaps the plus for
        // a checkmark, mirroring the Identify tab's add affordance.
        let alreadyAdded = store.contains(scientificName: scientificName)
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
                // Tapping the checkmark undoes the add; the symbol-replace
                // transition reverse-animates back to a plus.
                if alreadyAdded {
                    store.remove(scientificName: scientificName)
                    return
                }
                // Unlike the Identify tab's plus (which logs here and now, from
                // a live detection), a Life List add is a bird the user is
                // recalling — so it asks when, then where, before writing
                // anything. See `beginAdd`.
                beginAdd(scientificName: scientificName, commonName: commonName)
            } label: {
                Image(systemName: alreadyAdded ? "checkmark" : "plus")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                    .contentTransition(.symbolEffect(.replace, options: .speed(2.6)))
                    .frame(width: 32, height: 32)
                    .background(Self.addButtonTint, in: Circle())
            }
            .buttonStyle(GrowButtonStyle())
            .accessibilityLabel(
                alreadyAdded
                    ? "Remove \(commonName) from Life List"
                    : "Add \(commonName) to Life List"
            )
            SpeciesThumbnail(scientificName: scientificName, height: Self.rowThumbnailHeight, onTap: {
                // Suggestions are part of what's on screen, so they're part of
                // the swipe list too (see `presentPhoto`).
                presentPhoto(scientificName)
            })
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .listRowInsets(EdgeInsets())
        .listRowSeparator(.hidden)
    }

    // MARK: - Two-step add flow

    /// Starts the Life List tab's add flow for a catalog suggestion: ask when
    /// the bird was seen, then where. Nothing is written to the store until the
    /// location step is confirmed.
    private func beginAdd(scientificName: String, commonName: String) {
        pendingAdd = PendingAdd(
            scientificName: scientificName,
            commonName: commonName,
            date: Date()
        )
        showAddDate = true
    }

    /// Writes the pending species to the life list at the chosen date,
    /// coordinate, and place name. Called from the naming sheet's confirm
    /// button; `pendingAdd` is cleared when the flow's presentations come down
    /// right after.
    private func commitPendingAdd(at coordinate: CLLocationCoordinate2D, name: String?) {
        guard let pending = pendingAdd else { return }
        // The same flow serves both entry points: a catalog suggestion's plus
        // creates the entry, while Add Again files another sighting under a
        // species that's already on the list.
        if store.contains(scientificName: pending.scientificName) {
            store.addObservation(
                scientificName: pending.scientificName,
                date: pending.date,
                location: name,
                latitude: coordinate.latitude,
                longitude: coordinate.longitude
            )
        } else {
            store.add(
                scientificName: pending.scientificName,
                commonName: pending.commonName,
                firstSeen: pending.date,
                location: name,
                latitude: coordinate.latitude,
                longitude: coordinate.longitude
            )
        }
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

    private var speciesCountText: String {
        if showStarredOnly {
            // Count from the frozen snapshot so the subtitle matches the rows
            // on screen (unstarred-but-still-showing birds included).
            let n = displayedEntries.count
            return "Filtered to \(n) starred species"
        }
        let n = store.entries.count
        return "\(n) species"
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
                if summary.added > 0 { parts.append("Added \(summary.added) species.") }
                if summary.updated > 0 { parts.append("\(summary.updated) updated.") }
                if summary.skipped > 0 { parts.append("\(summary.skipped) already known.") }
                importMessage = parts.isEmpty
                    ? "No new species to add."
                    : parts.joined(separator: " ")
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
/// star buttons so taps don't darken them.
struct NoDimButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}

/// Press feedback for the purple add buttons: a brief grow + lighten, both on
/// the same fast easeOut so they read as one motion. Deliberately identical to
/// the Identify tab's record button (`RecordButtonStyle`), since these are the
/// same "commit this bird" affordance at row scale.
struct GrowButtonStyle: ButtonStyle {
    /// How far the label grows while held. Defaults to the record button's 1.1;
    /// wider labels want less.
    var scale: CGFloat = 1.1

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1.0)
            .opacity(configuration.isPressed ? 0.85 : 1.0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}


/// The Life List tab's add flow, as a single modifier. Only *one* presentation
/// hangs off the list: the date sheet. The map picker is presented from inside
/// that sheet (see `ObservationDateSheet`), so it slides up over a sheet that
/// stays put — the checkmark shows the map immediately instead of waiting out a
/// sheet dismissal, and Back reveals the date sheet already sitting there rather
/// than re-animating it in. `onDismissed` therefore fires once, when the whole
/// flow ends, whichever way it ended.
private struct AddFlowPresentations: ViewModifier {
    @Binding var showDate: Bool
    @Binding var showLocation: Bool
    @Binding var date: Date
    /// Threaded down to the map: `@Observable` environment objects don't cross a
    /// `fullScreenCover` boundary, and the map reads the life list to plot its
    /// species thumbnails.
    let store: LifeListStore
    let onDismissed: () -> Void
    let onSave: (CLLocationCoordinate2D, String?) -> Void

    func body(content: Content) -> some View {
        content.sheet(isPresented: $showDate, onDismiss: {
            // The map can only outlive the sheet if something went sideways;
            // clear it so a re-entry starts on the date step.
            showLocation = false
            onDismissed()
        }) {
            ObservationDateSheet(
                date: $date,
                showLocationPicker: $showLocation,
                store: store,
                onCancel: { showDate = false },
                onSave: { coordinate, name in
                    onSave(coordinate, name)
                    // Dismissing the sheet takes its presented cover (and the
                    // naming sheet above that) with it, so the whole stack
                    // leaves in one animation rather than unwinding a step at
                    // a time.
                    showDate = false
                }
            )
        }
    }
}

/// Step one of the Life List tab's add flow: when did you see this bird?
/// Defaults to today and can't be set into the future. Dismissible by swipe or
/// by the leading Cancel button; the trailing checkmark raises the map picker
/// *over* this sheet, which stays mounted underneath for the whole detour.
private struct ObservationDateSheet: View {
    @Binding var date: Date
    @Binding var showLocationPicker: Bool
    let store: LifeListStore
    let onCancel: () -> Void
    let onSave: (CLLocationCoordinate2D, String?) -> Void

    /// The pin the user dropped on the map, held while step three asks what to
    /// call the place. Nothing is written until that sheet is confirmed.
    @State private var pickedCoordinate: CLLocationCoordinate2D?
    @State private var showNamePrompt = false

    var body: some View {
        NavigationStack {
            // A wheel rather than the graphical calendar: the calendar's month
            // grid doesn't fit a medium detent alongside the title bar.
            DatePicker(
                "Observation date",
                selection: $date,
                in: ...Date(),
                displayedComponents: .date
            )
            .datePickerStyle(.wheel)
            .labelsHidden()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("When did you see this bird?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(role: .cancel) { onCancel() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    // The system confirm role — a checkmark, tinted with the
                    // app's accent color.
                    Button(role: .confirm) { showLocationPicker = true }
                }
            }
        }
        .presentationDetents([.medium])
        // Hidden grab handle, matching the import sheet and the map's cards.
        .presentationDragIndicator(.hidden)
        // Step two, layered on top of this sheet rather than replacing it.
        .fullScreenCover(isPresented: $showLocationPicker) {
            MapView(picker: MapView.LocationPicker(
                onBack: { showLocationPicker = false },
                onConfirm: { coordinate in
                    pickedCoordinate = coordinate
                    showNamePrompt = true
                }
            ))
            .environment(store)
            // Step three sits on top of the map the same way the map sits on
            // top of the date sheet: dismissing it reveals the pin already
            // dropped, so backing out of the name doesn't restart the flow.
            .sheet(isPresented: $showNamePrompt) {
                ObservationNameSheet(
                    coordinate: pickedCoordinate ?? CLLocationCoordinate2D(),
                    onCancel: { showNamePrompt = false },
                    onSave: { name in
                        guard let coordinate = pickedCoordinate else { return }
                        onSave(coordinate, name)
                    }
                )
            }
        }
    }
}

/// Step three of the add flow: what do you call this place? Opens with the
/// keyboard already up and the field pre-filled with whatever `CLGeocoder`
/// makes of the dropped pin — a park or landmark when the coordinate has one,
/// otherwise the street or town. The suggestion is only a starting point; the
/// user is free to clear it, and an empty field saves the observation with no
/// place name at all (which is what manual adds did before this step existed).
private struct ObservationNameSheet: View {
    let coordinate: CLLocationCoordinate2D
    let onCancel: () -> Void
    let onSave: (String?) -> Void

    @State private var name = ""
    /// True while the reverse lookup is in flight, so the field can show it's
    /// still working rather than looking like it came back empty.
    @State private var isLookingUp = true
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TextField("Place name", text: $name)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($focused)
                    .submitLabel(.done)
                    .onSubmit(save)
                    .autocorrectionDisabled()
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .background(
                        Color.primary.opacity(0.06),
                        in: .rect(cornerRadius: 14, style: .continuous)
                    )
                    .overlay(alignment: .trailing) {
                        if isLookingUp && name.isEmpty {
                            ProgressView()
                                .controlSize(.small)
                                .padding(.trailing, 16)
                        }
                    }
                    .padding(.horizontal, 20)
                Spacer(minLength: 0)
            }
            .padding(.top, 24)
            .frame(maxWidth: .infinity)
            .navigationTitle("What do you call this place?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(role: .cancel) { onCancel() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .confirm) { save() }
                }
            }
        }
        .presentationDetents([.medium])
        // Hidden grab handle, matching every other sheet in this flow.
        .presentationDragIndicator(.hidden)
        .task {
            focused = true
            let suggestion = await Self.placeName(for: coordinate)
            isLookingUp = false
            // A slow lookup must never stomp on something the user has already
            // typed, so the suggestion only lands in a still-empty field.
            guard let suggestion, name.isEmpty else { return }
            name = suggestion
        }
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        onSave(trimmed.isEmpty ? nil : trimmed)
    }

    /// The shortest human name for a coordinate: a named park or landmark if
    /// the pin fell inside one, else the street, else the town. Returns `nil`
    /// when the lookup fails or the device is offline — the field just stays
    /// empty and the user types their own.
    private static func placeName(for coordinate: CLLocationCoordinate2D) async -> String? {
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        do {
            let placemarks = try await CLGeocoder().reverseGeocodeLocation(location)
            guard let placemark = placemarks.first else { return nil }
            return placemark.areasOfInterest?.first
                ?? placemark.name
                ?? placemark.locality
                ?? placemark.subAdministrativeArea
        } catch {
            Log.error("ObservationNameSheet: reverse geocode failed — \(error)")
            return nil
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
                Text(.init("If you track the birds you've seen with eBird or Merlin, you can import them to Kestrel. First [download your eBird data](https://ebird.org/downloadMyData), then import the CSV file here."))
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
        .presentationDetents([.medium])
        // Hidden grab handle to match the map's settings card (MapCardSheet).
        .presentationDragIndicator(.hidden)
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
