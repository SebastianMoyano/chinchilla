import Foundation
import AppKit
import DiskScanKit

/// Closes what the memory list is showing.
///
/// The first version asked `NSWorkspace` for running applications matching the
/// name and terminated those. That works for Safari and silently does nothing
/// for `node`: `runningApplications` lists *applications* — things with a
/// bundle, registered with Launch Services — and a command-line process is not
/// one. Pressing "Close node" sent no signal at all and then reported that it
/// had already closed.
///
/// So: applications go through AppKit, which lets them put up their own
/// "unsaved changes" dialog, and everything else gets a polite SIGTERM.
@MainActor
public enum AppTerminator {
    public struct Outcome: Sendable, Equatable {
        /// Applications asked to quit. They may still refuse — an unsaved
        /// document is a good reason to.
        public var applicationsAsked = 0
        /// Plain processes sent SIGTERM.
        public var processesSignalled = 0
        /// Processes we are not allowed to signal (another user's, or the
        /// system's).
        public var refused = 0
        /// Processes deliberately left alone because killing them would take
        /// this app — or its parent — down with them.
        public var protected = 0

        public var didSomething: Bool { applicationsAsked > 0 || processesSignalled > 0 }
        public var total: Int { applicationsAsked + processesSignalled }
    }

    /// Says what actually happened. The first version reported "\(name) had
    /// already closed" whenever it found nothing to terminate — which is the
    /// message it printed while quietly failing to close anything at all.
    public nonisolated static func describe(_ outcome: Outcome, target: String) -> String {
        if outcome.didSomething {
            let count = outcome.total
            return count == 1
                ? String(localized: "Asked \(target) to close.")
                : String(localized: "Asked \(target) to close (\(count) processes).")
        }
        if outcome.protected > 0 {
            return String(localized: "\(target) is running Chinchilla itself, so it was left alone.")
        }
        if outcome.refused > 0 {
            return String(localized: "macOS wouldn't let Chinchilla close \(target).")
        }
        return String(localized: "\(target) was already gone.")
    }

    public static func close(name: String) async -> Outcome {
        var outcome = Outcome()

        // Applications first: terminate() is a request, so the app gets to
        // save, prompt, or refuse. Killing those outright would be rude and
        // occasionally destructive.
        let applications = NSWorkspace.shared.runningApplications.filter {
            $0.localizedName == name || $0.bundleURL?.deletingPathExtension().lastPathComponent == name
        }
        for application in applications where !application.isTerminated {
            if application.processIdentifier == getpid() { continue }
            application.terminate()
            outcome.applicationsAsked += 1
        }

        // The full process-table walk (a syscall per pid, argv reads for
        // interpreters) does not belong on the main thread — it was a visible
        // stall on every press of a "Close" button. Only the AppKit part
        // above needs the main actor.
        let pids = await Blocking.run { ProcessMemory.pids(for: name) }
        let handled = Set(applications.map(\.processIdentifier))
        for pid in pids where !handled.contains(pid) {
            // Never ourselves, and never something we are descended from:
            // Chinchilla can be launched from a terminal, and a shell that
            // dies takes the app with it.
            guard !ProcessPauser.isSelfOrAncestor(pid) else {
                outcome.protected += 1
                continue
            }
            // SIGTERM, not SIGKILL: a server gets to close its sockets and a
            // build gets to remove its temporary files.
            if kill(pid, SIGTERM) == 0 {
                outcome.processesSignalled += 1
            } else {
                outcome.refused += 1
            }
        }
        return outcome
    }
}
