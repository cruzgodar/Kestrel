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
        return base.filter {
            $0.commonName.localizedCaseInsensitiveContains(q)
                || $0.scientificName.localizedCaseInsensitiveContains(q)
        }
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
                            // Fade between the hollow and filled star — no
                            // background, no symbol-replace morph.
                            ZStack {
                                Image(systemName: "star")
                                    .font(.system(size: 24, weight: .regular))
                                    .foregroundStyle(.secondary)
                                    .opacity(entry.isStarred ? 0 : 1)
                                Image(systemName: "star.fill")
                                    .font(.system(size: 24, weight: .semibold))
                                    .foregroundStyle(Self.starButtonTint)
                                    .opacity(entry.isStarred ? 1 : 0)
                            }
                            .frame(width: 32, height: 32)
                            .animation(.easeInOut(duration: 0.1), value: entry.isStarred)
                        }
                        .buttonStyle(.plain)
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
        .searchable(text: $searchText, placement: .toolbar, prompt: "Search species")
        .searchToolbarBehavior(.minimize)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showStarredOnly.toggle()
                } label: {
                    Image(systemName: showStarredOnly
                        ? "line.3.horizontal.decrease.circle.fill"
                        : "line.3.horizontal.decrease")
                }
                .accessibilityLabel(showStarredOnly ? "Show all species" : "Show starred only")
            }
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
    private static let starButtonTint = Color(hue: 215.0 / 360.0, saturation: 0.9, brightness: 1.0)

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

#Preview {
    NavigationStack {
        LifeListView()
    }
    .environment(LifeListStore())
}
