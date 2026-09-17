import Foundation

/// Whether a live session is asking for the user, which is the only thing the
/// session-alert feature reports.
///
/// **A finished turn does not count.** The transcript's `awaitingPrompt` only
/// says the assistant stopped talking, which is how every turn ends, so it
/// fires constantly: measured on one machine, 8 of 12 live sessions were
/// sitting at one. Reporting those made both the icon and the Needs-you list
/// permanently full, which is the state in which a signal stops being read.
///
/// The genuinely-waiting case is not lost, because it arrives by a different
/// route. Claude Code raises `idle_prompt` / `agent_needs_input` through the
/// `Notification` hook when *it* judges a session is waiting on a human, and
/// `SessionMonitor` turns any hook payload into `waitingOnYou`. So "Claude is
/// asking me for input" is reported, and "Claude finished a sentence" is not.
public enum SessionAttention {

    /// Something is stopped until a human answers it. Drives the menubar icon,
    /// the pulse, the popover landing on Needs-you, and the list itself.
    ///
    /// Reached only by the exact signals: a Claude Code `Notification` hook
    /// payload (`permission_prompt`, `idle_prompt`, `agent_needs_input`,
    /// `elicitation_dialog`), a Codex `*_approval_request`, an outstanding
    /// `AskUserQuestion` / `ExitPlanMode`, or the debounce fallback in a session
    /// the hook is not covering.
    public static func isBlocked(_ activity: SessionActivity) -> Bool {
        activity.needsAttention
    }
}
