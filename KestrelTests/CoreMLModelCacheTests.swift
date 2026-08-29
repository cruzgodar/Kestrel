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
