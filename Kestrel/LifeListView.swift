import SwiftUI
import UniformTypeIdentifiers

struct LifeListView: View {
    @Environment(LifeListStore.self) private var store

    @State private var isImporting = false
    @State private var importMessage: String?
    @State private var showImportResult = false

    var body: some View {
        Group {
            if store.entries.isEmpty {
                ContentUnavailableView {
                    Label("Your life list is empty", systemImage: "bird")
                } description: {
                    Text("Tap the import button to load an eBird CSV export.")
                }
            } else {
                List(store.entries) { entry in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.commonName)
                                .font(.headline)
                            Text(entry.firstSeen, format: .dateTime.year().month(.abbreviated).day())
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        SpeciesThumbnail(scientificName: entry.scientificName)
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("Life List")
        .navigationSubtitle(speciesCountText)
        .toolbarTitleDisplayMode(.inlineLarge)
        .toolbar {
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

#Preview {
    NavigationStack {
        LifeListView()
    }
    .environment(LifeListStore())
}
