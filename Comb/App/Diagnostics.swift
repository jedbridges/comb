import Foundation
import OSLog

/// The app's logging, and the buffer behind the Diagnostics screen.
///
/// Comb ships no crash reporting and phones nothing home, which is a privacy
/// win and a support problem: a rare bug is hard to diagnose from a user's
/// description alone. The answer is a local structured log the user can read
/// and choose to copy into a GitHub issue. Nothing leaves the device unless the
/// person deliberately shares it.
enum Log {
    static let session = Logger(subsystem: subsystem, category: "session")
    static let store = Logger(subsystem: subsystem, category: "store")
    static let onboarding = Logger(subsystem: subsystem, category: "onboarding")
    static let pairing = Logger(subsystem: subsystem, category: "pairing")

    private static let subsystem = "dev.jedbridges.comb"
}

/// A bounded in-memory ring of recent events, mirrored from OSLog so the
/// Diagnostics screen has something to show without entitlements for reading
/// the system log store.
@MainActor
final class DiagnosticsBuffer {
    static let shared = DiagnosticsBuffer()

    struct Entry: Identifiable {
        let id = UUID()
        let at: Date
        let category: String
        let message: String
    }

    private(set) var entries: [Entry] = []
    /// Bounded so a long-running session cannot grow it without limit; the
    /// oldest lines fall off, which is what a diagnostic tail wants anyway.
    private let capacity = 500

    private init() {}

    func record(_ category: String, _ message: String) {
        entries.append(Entry(at: Date(), category: category, message: message))
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
    }

    /// The log as text, for the clipboard. Redaction is unnecessary because
    /// nothing here logs secrets: keys never reach this layer by construction.
    func exportText() -> String {
        let header = """
        Comb diagnostics
        \(appVersion)
        \(entries.count) entries

        """
        let formatter = ISO8601DateFormatter()
        let lines = entries.map { entry in
            "\(formatter.string(from: entry.at))  [\(entry.category)]  \(entry.message)"
        }
        return header + lines.joined(separator: "\n")
    }

    func clear() {
        entries.removeAll()
    }

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return "Version \(version) (\(build))"
    }
}

extension DiagnosticsBuffer {
    /// Records from any isolation. The buffer is MainActor-bound, so this hops.
    nonisolated static func report(_ category: String, _ message: String) {
        Task { @MainActor in shared.record(category, message) }
    }
}
