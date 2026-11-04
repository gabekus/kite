import CoreServices
import Foundation

/// Calls `onChange` on the main thread when anything under `paths` changes (files inside
/// subfolders included), from one FSEvents stream: nothing is polled, and changes that come close
/// together arrive as one call `latency` seconds after the first. Paths that don't exist yet are
/// watched for when they appear.
@MainActor
final class DirectoryWatcher {
    private final class Handler: Sendable {
        let onChange: @MainActor @Sendable () -> Void
        init(_ onChange: @escaping @MainActor @Sendable () -> Void) { self.onChange = onChange }
    }

    private var stream: FSEventStreamRef?
    private let handler: Handler

    init?(paths: [URL], latency: TimeInterval, onChange: @escaping @MainActor @Sendable () -> Void) {
        handler = Handler(onChange)
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(handler).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let handler = Unmanaged<Handler>.fromOpaque(info).takeUnretainedValue()
            MainActor.assumeIsolated { handler.onChange() }
        }
        guard let stream = FSEventStreamCreate(nil, callback, &context, paths.map(\.path) as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency,
                                               FSEventStreamCreateFlags(kFSEventStreamCreateFlagNone)) else { return nil }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
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
