import Foundation
import MetricKit

/// Saves MetricKit's diagnostic reports (hangs, crashes, CPU and disk-write
/// exceptions, with call stacks) as JSON under the profile's Diagnostics folder.
/// macOS delivers these at most once a day, about the previous day, and only
/// diagnostics: the metric payloads (launch time, energy) are iOS-only.
final class DiagnosticsRecorder: NSObject, MXMetricManagerSubscriber {
    private let directory: URL

    init(directory: URL) {
        self.directory = directory
        super.init()
    }

    func start() {
        MXMetricManager.shared.add(self)
        save(MXMetricManager.shared.pastDiagnosticPayloads)
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        save(payloads)
    }

    private func save(_ payloads: [MXDiagnosticPayload]) {
        guard !payloads.isEmpty else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate, .withTime]
        for payload in payloads {
            // Named by the period it covers, so a report delivered twice overwrites itself.
            let name = "diagnostics-\(formatter.string(from: payload.timeStampBegin)).json"
            try? payload.jsonRepresentation().write(to: directory.appendingPathComponent(name), options: .atomic)
        }
    }
}
