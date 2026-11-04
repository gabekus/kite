import CoreServices
import Foundation

/// Calls `onChange` on the main thread with the paths that changed under `paths` (files inside
/// subfolders included), from one FSEvents stream: nothing is polled, and changes that come close
/// together arrive as one call `latency` seconds after the first. Paths that don't exist yet are
/// watched for when they appear. Reported paths have symlinks resolved (/tmp is /private/tmp).
/// `rescan` is true when FSEvents lost track (events dropped, a folder to rescan, a watched root
/// moved): the paths then don't say everything that changed.
@MainActor
final class DirectoryWatcher {
    private final class Handler: Sendable {
        let onChange: @MainActor @Sendable (_ paths: [String], _ rescan: Bool) -> Void
        init(_ onChange: @escaping @MainActor @Sendable ([String], Bool) -> Void) { self.onChange = onChange }
    }

    private var stream: FSEventStreamRef?
    private let handler: Handler

    /// The flags that mean the reported paths aren't the whole story.
    nonisolated static let rescanFlags = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs
        | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagRootChanged)

    init?(paths: [URL], latency: TimeInterval, onChange: @escaping @MainActor @Sendable (_ paths: [String], _ rescan: Bool) -> Void) {
        handler = Handler(onChange)
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(handler).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, eventPaths, eventFlags, _ in
            guard let info else { return }
            let handler = Unmanaged<Handler>.fromOpaque(info).takeUnretainedValue()
            // With kFSEventStreamCreateFlagUseCFTypes the paths come as a CFArray of CFStrings.
            let array = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as NSArray
            let changed = (array as? [String]) ?? []
            let rescan = UnsafeBufferPointer(start: eventFlags, count: count).contains { $0 & DirectoryWatcher.rescanFlags != 0 }
            MainActor.assumeIsolated { handler.onChange(changed, rescan) }
        }
        // WatchRoot: a watched folder moved or deleted comes as RootChanged (a rescan).
        let flags = kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagWatchRoot
        guard let stream = FSEventStreamCreate(nil, callback, &context, paths.map(Self.resolved) as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency,
                                               FSEventStreamCreateFlags(flags)) else { return nil }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
    }

    /// The path with symlinks resolved on its nearest existing ancestor: FSEvents reports real
    /// paths, and a not-yet-existing path under /tmp would otherwise never match /private/tmp.
    nonisolated static func resolved(_ url: URL) -> String {
        var existing = url.standardizedFileURL
        var rest: [String] = []
        while !FileManager.default.fileExists(atPath: existing.path), existing.pathComponents.count > 1 {
            rest.insert(existing.lastPathComponent, at: 0)
            existing.deleteLastPathComponent()
        }
        // realpath, not resolvingSymlinksInPath, which maps /private/tmp back to /tmp.
        var result = existing
        if let real = realpath(existing.path, nil) {
            result = URL(fileURLWithPath: String(cString: real))
            free(real)
        }
        for component in rest { result.appendPathComponent(component) }
        return result.path
    }

    /// Stops the stream; no calls come after this.
    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    isolated deinit { stop() }
}
