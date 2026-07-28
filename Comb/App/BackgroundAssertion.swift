import UIKit

/// Keeps the process running long enough to reach a clean stopping point after
/// the app is backgrounded, and always gives the time back.
///
/// iOS grants a backgrounded app a few seconds and then suspends it wherever it
/// happens to be. That is fine for work that can be abandoned, and not fine for
/// work that holds something: a socket mid-close, or a database mid-write. A
/// process suspended while holding a SQLite lock is one iOS terminates rather
/// than resumes, which is why a crash nobody can reproduce shows up only on a
/// phone in a pocket.
///
/// So anything that must finish says so, for as long as it needs and no longer.
/// The expiration handler is the system calling the loan in; there is nothing to
/// do but release it, because holding past that point is itself a termination.
@MainActor
final class BackgroundAssertion {
    private var id: UIBackgroundTaskIdentifier = .invalid

    init(_ name: String) {
        id = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            // Documented to arrive on the main thread, which is where this
            // object lives, so the isolation being asserted is real.
            MainActor.assumeIsolated { self?.end() }
        }
    }

    /// Idempotent, because the expiration handler and the normal path both end
    /// it and either can be first. Ending an already-ended assertion is a
    /// programmer error iOS reports by crashing, which is precisely the failure
    /// this type exists to avoid.
    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}
