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

    private var visibleEntries: [LifeListEntry] {
        let base = showStarredOnly ? store.entries.filter(\.isStarred) : store.entries
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return base }
        let needle = q.lowercased()
        return base.filter { entry in
            let hay = "\(entry.commonName) \(entry.scientificName)".lowercased()
            // Cheap exact substring path first — handles the common case
            // without paying the Levenshtein cost per row.
            if hay.contains(needle) { return true }
            // Fuzzy fallback: any whitespace-separated word whose first
            // `needle.count` characters are within edit distance 1 of the
            // query counts as a match. Keeps the comparison tight so
            // "Sparow" still finds "Sparrow" but unrelated species don't
            // light up on every keystroke.
            for word in hay.split(whereSeparator: { !$0.isLetter }) {
                let prefix = String(word.prefix(needle.count))
                if levenshtein(prefix, needle) <= 1 { return true }
            }
            return false
        }
    }

    /// Iterative DP Levenshtein. Two rows, O(min(a,b)) memory.
    private func levenshtein(_ a: String, _ b: String) -> Int {
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
                List(visibleEntries) { entry in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.commonName)
                                .font(.headline)
                            Text(entry.firstSeen, format: .dateTime.year().month(.abbreviated).day())
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            store.setStarred(
                                scientificName: entry.scientificName,
                                isStarred: !entry.isStarred
                            )
                        } label: {
                            // Instant swap — no crossfade.
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
                        .font(.system(size: 22, weight: .medium))
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
