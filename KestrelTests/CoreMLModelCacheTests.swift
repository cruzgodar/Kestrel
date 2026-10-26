import Foundation
import Testing
@testable import Kestrel

/// The leaked-temp-model sweep. It deletes directories in the app's own tmp, so
/// the guard that decides what *not* to delete is worth pinning precisely.
@Suite("CoreMLModelCache temp sweep")
struct CoreMLModelCacheTests {

    private let pid = ProcessInfo.processInfo.processIdentifier

    /// ORT names them `onnxruntime-<uuid>-<pid>-<hex>.model.mlmodelc`, with the
    /// pid in the seventh hyphen-separated position.
    @Test("an entry carrying this process's pid is left alone")
    func ownEntryIsSkipped() {
        let url = URL(fileURLWithPath:
            "/tmp/onnxruntime-AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE-\(pid)-abc.model.mlmodelc")
        #expect(CoreMLModelCache.isOwnedByThisProcess(url),
                "pulling a live model out from under a running session is not worth a few MB")
    }

    @Test("an entry from another process is eligible for deletion")
    func foreignEntryIsSweepable() {
        let other = pid == 1 ? 2 : 1
        let url = URL(fileURLWithPath:
            "/tmp/onnxruntime-AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE-\(other)-abc.model.mlmodelc")
        #expect(!CoreMLModelCache.isOwnedByThisProcess(url))
    }

    /// Unparseable names are treated as *ours*, so an unrecognized naming scheme
    /// is left alone rather than deleted blind.
    @Test(
        "an unrecognized name is treated as ours and left alone",
        arguments: [
            "onnxruntime-too-few-parts",
            "onnxruntime-AAAA-BBBB-CCCC-DDDD-EEEE-notanumber-abc.model.mlmodelc",
            "onnxruntime",
            "something-else-entirely",
        ]
    )
    func unparseableIsProtected(name: String) {
        #expect(CoreMLModelCache.isOwnedByThisProcess(URL(fileURLWithPath: "/tmp/\(name)")),
                "\(name) should not be deleted on a guess")
    }

    /// Age is deliberately *not* the filter: it left the most recent leak — the
    /// largest one — sitting for an hour after the user updated.
    @Test("the sweep runs without throwing on a real temp directory")
    func sweepIsSafe() {
        CoreMLModelCache.purgeLegacyTempModels()
    }
}

/// ORT reuses a cached model without validating it, so one truncated write
/// fails every later load with "Error reading protobuf spec" — what a v1.2 user
/// hit on one phone, through restarts, until the cache was rebuilt.
///
/// Goes through `BirdNETClassifier` rather than building ORT objects here: this
/// target only has search paths, so importing `onnxruntime_objc` would autolink
/// a second, category-less copy of the static framework into the test bundle.
@Suite("CoreMLModelCache corrupt-cache recovery", .serialized)
struct CoreMLModelCacheRecoveryTests {

    private static let garbage = Data("not a protobuf".utf8)

    @Test("a corrupted cache is cleared and recompiled rather than failing the load")
    func corruptCacheIsRebuilt() throws {
        let dir = URL(fileURLWithPath: try #require(CoreMLModelCache.directory(forModel: "birdnet")))

        _ = try BirdNETClassifier()
        let cached = files(in: dir)
        try #require(!cached.isEmpty, "the first load should populate the cache")
        for file in cached { try Self.garbage.write(to: file) }

        _ = try BirdNETClassifier()
        let rebuilt = files(in: dir)
        #expect(!rebuilt.isEmpty)
        #expect(rebuilt.allSatisfy { (try? Data(contentsOf: $0)) != Self.garbage },
                "the corrupt entries should have been replaced by a fresh compile")
    }

    private func files(in dir: URL) -> [URL] {
        let walker = FileManager.default.enumerator(
            at: dir, includingPropertiesForKeys: [.isRegularFileKey]
        )
        return (walker?.allObjects as? [URL] ?? []).filter {
            (try? $0.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
        }
    }
}
