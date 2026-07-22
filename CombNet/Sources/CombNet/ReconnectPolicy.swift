import Foundation

/// Exponential backoff with full jitter.
///
/// A pure value with no clock of its own, so the schedule can be asserted in
/// tests without waiting for real time to pass.
public struct ReconnectPolicy: Sendable, Equatable {
    public let base: Duration
    public let cap: Duration
    /// A connection that stays up this long is considered healthy, and the next
    /// failure starts counting from zero again. Without this, a client that
    /// reconnects successfully every hour would still be waiting the maximum
    /// delay after a week of uptime.
    public let resetAfter: Duration

    public init(
        base: Duration = .seconds(1),
        cap: Duration = .seconds(30),
        resetAfter: Duration = .seconds(30)
    ) {
        self.base = base
        self.cap = cap
        self.resetAfter = resetAfter
    }

    public static let `default` = ReconnectPolicy()

    /// Delay before attempt `attempt`, counting from 1.
    ///
    /// Full jitter (a uniform value between zero and the ceiling) rather than a
    /// fixed backoff, so a relay restart does not bring every client back in the
    /// same instant.
    public func delay(forAttempt attempt: Int, random: (ClosedRange<Double>) -> Double) -> Duration {
        guard attempt > 0 else { return .zero }

        let exponent = min(attempt - 1, 16) // guards against overflow on long outages
        let ceiling = min(base * pow(2.0, Double(exponent)), cap)
        return ceiling * random(0...1)
    }

    public func delay(forAttempt attempt: Int) -> Duration {
        delay(forAttempt: attempt) { Double.random(in: $0) }
    }
}
