import Foundation

/// Where the CoreML execution provider parks the `.mlmodelc` it compiles from
/// our ONNX models — and the cleanup for the temp copies earlier builds leaked.
///
/// **The leak.** Without the EP's `ModelCacheDirectory` option, ORT compiles the
/// model into a fresh `NSTemporaryDirectory()/onnxruntime-<uuid>-<pid>-<hex>.model.mlmodelc`
/// on every `ORTSession` creation and removes it only when the session is
/// *closed*. Kestrel listens in the background, so the process is routinely
/// killed outright — jetsam, force-quit, the end of a background-audio stint —
/// and that cleanup never runs. Measured on a device after four days: 3,355
/// orphaned directories, 4.9 GB, against a 40 MB photo cache. Every launch and
/// every session start added more.
///
/// **The fix.** Point both sessions at a directory we own, so the compile
/// happens once and is reused instead of re-done and abandoned. The header is
/// explicit that this hands us the lifetime ("User should manage to delete the
/// model"), which `prepareRoot` does via the install stamp below.
///
/// The cache lives in Caches — recompiling is cheap and correct if iOS purges it
/// under storage pressure, whereas Application Support would be backed up and
/// restored onto a device where the compiled model may not even be valid.
nonisolated enum CoreMLModelCache {
    private static let folderName = "CoreMLModelCache"
    /// Identifies the install whose compiled models the cache holds.
    private static let stampKey = "CoreMLModelCacheInstallStamp"
    /// Prefix of the temp entries the pre-fix builds leaked. ORT names them
    /// `onnxruntime-<uuid>-<pid>-<hex>.model.mlmodel[c]`, and one *session*
    /// leaves hundreds — the CoreML EP splits the model into subgraphs and
    /// compiles each one separately.
    private static let legacyTempPrefix = "onnxruntime-"
    /// Position of the pid in a leaked entry's hyphen-separated name: the
    /// prefix, then the five parts of a UUID, then the pid.
    private static let legacyTempPIDComponent = 6

    private static let lock = NSLock()
    /// Root of the cache, resolved and validated on first use. Double-optional:
    /// the outer layer is "not prepared yet", the inner one "unavailable".
    private nonisolated(unsafe) static var preparedRoot: URL??

    /// Directory to hand the CoreML EP for one model, created on demand, or nil
    /// if the cache is unavailable (in which case the caller simply omits the
    /// option and gets the old temp-directory behavior for that session).
    ///
    /// `name` only has to be stable and distinct per model — ORT derives its own
    /// cache key from the model inside the directory we give it.
    static func directory(forModel name: String) -> String? {
        guard let root = prepareRoot() else { return nil }
        let dir = root.appendingPathComponent(name, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            Log.warning("CoreMLModelCache: couldn't create \(name) — \(error)")
            return nil
        }
        return dir.path
    }

    /// Resolves the cache root once per launch, wiping it first if it belongs to
    /// a different install.
    ///
    /// ORT keys its cache on a hash of the model's path, and the app bundle's
    /// container UUID changes on every install and update — so after an update
    /// the old entries are unreachable dead weight, and the same is true of a
    /// reinstall at an unchanged version number. Stamping the bundle path
    /// alongside the version catches both, and keeps the cache at exactly the
    /// entries this install can actually hit.
    private static func prepareRoot() -> URL? {
        lock.lock()
        defer { lock.unlock() }
        if let preparedRoot { return preparedRoot }

        let root: URL? = {
            guard let caches = try? FileManager.default.url(
                for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true
            ) else { return nil }
            let root = caches.appendingPathComponent(folderName, isDirectory: true)

            let stamp = installStamp()
            if UserDefaults.standard.string(forKey: stampKey) != stamp {
                try? FileManager.default.removeItem(at: root)
                UserDefaults.standard.set(stamp, forKey: stampKey)
            }
            do {
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            } catch {
                Log.warning("CoreMLModelCache: couldn't create root — \(error)")
                return nil
            }
            return root
        }()

        preparedRoot = .some(root)
        return root
    }

    private static func installStamp() -> String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        // The bundle path carries the per-install container UUID, which is what
        // ORT's model-path cache key ultimately turns on.
        return "\(version)|\(build)|\(Bundle.main.bundlePath)"
    }

    /// Deletes the `onnxruntime-*` compiled models that pre-fix builds abandoned
    /// in the temp directory. Safe to call on every launch: once the backlog is
    /// gone there is nothing left to match, since sessions now compile into the
    /// managed cache instead. Call off the main thread — it stats every entry in
    /// tmp, and the first run on an affected device removes thousands.
    static func purgeLegacyTempModels() {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory
        guard let entries = try? fm.contentsOfDirectory(
            at: tmp, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return }

        var removed = 0
        var reclaimed: Int64 = 0
        for entry in entries where entry.lastPathComponent.hasPrefix(legacyTempPrefix) {
            // Skip anything this process owns. Nothing in the current build
            // should be writing here at all — the sessions compile into the
            // managed cache — but if the cache were ever unavailable the EP
            // would fall back to tmp, and pulling a live model out from under a
            // running session is not a risk worth taking for a few MB. Age is
            // deliberately *not* the filter: it left the most recent leak (the
            // largest one) sitting for an hour after the user updated.
            guard !isOwnedByThisProcess(entry) else { continue }
            let size = directorySize(at: entry)
            guard (try? fm.removeItem(at: entry)) != nil else { continue }
            removed += 1
            reclaimed += size
        }
        if removed > 0 {
            let mb = Double(reclaimed) / (1024 * 1024)
            Log.info("CoreMLModelCache: removed \(removed) leaked temp models (\(Int(mb)) MB)")
        }
    }

    /// Whether a leaked temp entry carries this process's pid — see the note in
    /// `purgeLegacyTempModels`. Unparseable names are treated as *ours*, so an
    /// unrecognized naming scheme is left alone rather than deleted blind.
    private static func isOwnedByThisProcess(_ url: URL) -> Bool {
        let parts = url.lastPathComponent.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count > legacyTempPIDComponent,
              let pid = Int32(parts[legacyTempPIDComponent]) else { return true }
        return pid == ProcessInfo.processInfo.processIdentifier
    }

    /// Bytes on disk under `url`, for the reclaimed-space log line only; a failed
    /// walk just under-reports.
    private static func directorySize(at url: URL) -> Int64 {
        guard let walker = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in walker {
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            total += Int64(size)
        }
        return total
    }
}
