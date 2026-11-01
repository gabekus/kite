import Foundation

/// Arc's Help › Troubleshooting › Record Trace, without the AppKit and Chromium parts: the
/// durations, the countdown and the bundle's file names. Evidence is in docs/arc-visual-spec.md
/// ("Record Trace"). Arc uploads the bundle to its team; Kite never sends it anywhere and keeps
/// it in the Kite data folder instead.
public enum TraceRecording {
    /// "How long should the trace last?" Arc's four choices, in its order.
    public enum Duration: Int, CaseIterable, Sendable {
        case fiveSeconds, fifteenSeconds, thirtySeconds, oneMinute

        public var seconds: Int {
            switch self {
            case .fiveSeconds: 5
            case .fifteenSeconds: 15
            case .thirtySeconds: 30
            case .oneMinute: 60
            }
        }

        public var title: String {
            switch self {
            case .fiveSeconds: "5 seconds"
            case .fifteenSeconds: "15 seconds"
            case .thirtySeconds: "30 seconds"
            case .oneMinute: "1 minute"
            }
        }
    }

    public static let windowTitle = "Record Trace"
    public static let descriptionPrompt = "What's the issue you've been seeing?"
    public static let durationPrompt = "How long should the trace last?"
    public static let startTitle = "Start Tracing"
    /// Arc's warning is about sharing the trace with its team; Kite's trace stays on this Mac,
    /// so it says what the file holds instead.
    public static let privacyNote = "The trace stays on this Mac. It can include the URLs of\nyour open tabs, so check it before you share it."
    /// Arc's window: 360 × 400 points.
    public static let windowSize = (width: 360.0, height: 400.0)

    /// The countdown under the trace: Arc's " second remaining" / " seconds remaining".
    public static func remainingLabel(seconds: Double) -> String {
        let whole = Int(seconds.rounded(.up))
        return whole <= 1 ? "1 second remaining" : "\(whole) seconds remaining"
    }

    /// The bundle's folder: Arc's "arc_trace_bundle_" plus "yyy-MM-dd_HH-mm-ss".
    public static func bundleName(date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return "kite_trace_bundle_" + formatter.string(from: date)
    }

    /// Chromium's trace (JSON, which chrome://tracing and ui.perfetto.dev open).
    public static let traceFilename = "trace.json"
    /// The browser process sampled with /usr/bin/sample for the trace's length, as Arc does.
    public static let sampleFilename = "sample.txt"
    /// What the user typed, with the app and macOS versions.
    public static let descriptionFilename = "description.txt"

    public static func descriptionText(issue: String, duration: Duration, kiteVersion: String, engine: String,
                                       macOS: String, date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss ZZZZZ"
        let issue = issue.trimmingCharacters(in: .whitespacesAndNewlines)
        return """
            Issue: \(issue.isEmpty ? "(none given)" : issue)
            Duration: \(duration.title)
            Started: \(formatter.string(from: date))
            Kite \(kiteVersion)
            Engine: \(engine)
            macOS \(macOS)

            """
    }
}
