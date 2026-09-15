# Changelog

All notable changes to flow-bar, newest first. The top section is published as
the GitHub release notes when a version is tagged.

## v0.4.1 — 2026-09-15

### Fixed

- **Updating from the app works again on a Homebrew install.** It used to hand
  you a command to paste; now it's one click. flow-bar quits, Homebrew rebuilds
  it for your macOS, and it reopens when it's done. It deliberately does *not*
  install the prebuilt download over a source install — that would change the
  code signature and silently cost you the macOS Automation grant that `flow do`
  needs, and link the app against an older SDK so the UI stopped looking native.
  Delegating to `brew` avoids all of it and keeps Homebrew's own records honest.
- **The offered upgrade command could find nothing.** flow-bar lives in a
  third-party tap, and `brew upgrade` only sees a new version once that tap has
  been refreshed — which Homebrew skips if it auto-updated recently. So the app
  would tell you an update existed and then hand you a command that reported
  you were up to date. It now refreshes the tap first.
- **"Built for macOS … SDK" said nothing useful.** The build stamped `unknown`
  whenever `xcrun --show-sdk-version` failed, which it does on a machine where
  Xcode is selected but the Command Line Tools SDK is absent. That silently
  disabled the nudge that tells you a rebuild is due after a macOS upgrade —
  the one warning that a build has stopped being native to your OS.

## v0.4.0 — 2026-09-15

### Added — flow-bar tells you when a session is stuck

- **The menubar icon turns orange when a session is waiting on you.** flow-bar
  now watches the Claude Code and Codex sessions behind your in-progress tasks,
  and says so when one has stopped and needs a human. Click the icon to land
  straight on Needs-you, where blocked sessions are listed above everything
  else, and click one to jump into its terminal. **Opt-in** — Settings ›
  Session alerts — because it is the only part of flow-bar that observes
  anything while the popover is closed.
- **It only fires when you are genuinely blocked.** A permission prompt, a
  question Claude asked you, a plan waiting for approval, a Codex approval
  request, or a turn that finished and is waiting for your next message. A slow
  build is not an alert. Getting this right needed real measurement: in a live
  session `AskUserQuestion` sat unanswered for 62 minutes while every `Bash`
  call finished in a 0.1s median — so the two are told apart by *what* is
  outstanding, not by how long it has been.
- **Codex sessions too.** flow can bootstrap a task under either harness, and
  `flow show task` doesn't say which, so flow-bar works it out from where the
  transcript turns up. Codex is the more forthcoming of the two: it states
  outright when it is asking for approval and when a turn has ended.
- **A finished turn behaves like an unread badge** — it counts until you have
  actually looked, then goes quiet, and the next turn re-arms it. No arbitrary
  timer deciding you have stopped caring.
- **The pulse can be switched off.** The icon breathes so it catches your eye
  in a row of small coloured glyphs; if that grates, turn it off in Settings
  and it stays orange without moving.

### Fixed

- **`brew upgrade` no longer prints a deprecation warning** on every run. The
  cask's `url` stanza carried Homebrew's retired `verified:` parameter, which
  only ever vouched for a download host that differs from the homepage — ours
  don't differ, so the default verification already covered it.

### Notes

- Switching session alerts on adds **one entry** to `~/.claude/settings.json`,
  under the `Notification` hook. It is the only exact way to see a permission
  prompt: Claude Code's transcript records nothing between asking and being
  answered. `Notification` is informational and cannot allow, deny or delay
  anything. Your existing hooks are left untouched, the original file is copied
  to `settings.json.flow-bar.bak`, and switching alerts off removes the entry
  again.
- Hooks are read when a session starts, so sessions already running when you
  enable alerts fall back to a timing heuristic until they restart.

## v0.3.1 — 2026-09-06

### Fixed — things that looked like they worked

- **Briefs and notes render as real markdown.** Code fences, tables,
  blockquotes, ordered lists, nested lists and links all used to be dropped or
  flattened; paragraphs came out ragged because each hard-wrapped source line
  was laid out as its own line. flow's briefs *are* markdown, and reading them
  is what flow-bar is for.
- **You can select text across a whole brief.** Selection previously stopped at
  the end of whichever line you started on — a drag can now run from the first
  paragraph, through a code block, and out the other side. Links are clickable,
  and copying keeps the formatting.
- **Badge tooltips actually appear.** The hourglass and the stale triangle have
  declared tooltips for months without ever showing one, and the tooltips now
  say more: who you're waiting on, and how long a task has been sitting. They
  also show after a third of a second instead of two seconds.
- **The green "live" dot means what it says** — that the task's session is
  genuinely still running, not merely that the task is in progress.
- **Project and tag drill-ins no longer hide finished work.** A project that
  reported "1 done" and then showed nothing when you opened it was actively
  misleading. Done and archived tasks now appear below a labelled separator,
  underneath the active ones.

### Added

- **Playbooks show their brief and their notes**, rendered exactly like a
  task's, instead of only a list of runs.
- **A playbook run opens a real detail view** — its snapshotted brief and its
  own progress notes — rather than only offering "open in terminal".
- **Reminders can be set on a playbook run**, the same way as on any task.
- **A copy button next to the slug** in the task detail header. The slug is the
  one string you retype constantly.

## v0.3.0 — 2026-09-04

### Changed — how flow-bar is installed

- **The Homebrew cask now compiles on your machine** instead of downloading a
  prebuilt binary. SwiftUI takes its appearance from the macOS SDK a binary was
  *linked against*, not the OS it runs on, so a CI-built binary renders in
  compatibility mode on any newer macOS — permanently. Building locally is what
  makes the app look native on whatever you run. (`brew install --cask flow-bar`
  now needs Xcode or the Command Line Tools and takes about a minute.)
- **Updates come from Homebrew** on that channel: `brew upgrade --cask flow-bar`.
  The in-app updater deliberately stands down there — self-installing a CI-built
  zip would replace your natively-compiled binary with an SDK-mismatched one. It
  shows the command instead. The prebuilt `.dmg`/`.zip` still self-update as before.
- **flow-bar signs itself with a per-machine certificate** so its code identity
  stays stable. macOS keys the "control your terminal" permission to that
  identity, so it now survives every update instead of being dropped on each one.
  Settings shows this as "Permissions survive updates".
- flow-bar tells you when a macOS upgrade has left it built against an older SDK,
  and offers `brew reinstall --cask flow-bar` to rebuild natively.

### Added

- **Multi-select** in the task list: tick several tasks and open them together.
  Ticks survive re-searching — the bar reports how many are hidden by the current
  filter, so narrowing the search doesn't look like it lost your selection.
  Tasks open one at a time, because `flow do` returns when the terminal tab is
  created rather than when the session inside it has started, so opening them at
  once made the tabs race.
- **Liquid Glass on macOS 26.** Surfaces use real window material rather than the
  flat fills that previously made the app look the same on every OS. A scrim keeps
  text legible over light wallpapers. macOS 15 keeps the previous appearance.

### Fixed

- Completing a reminder didn't visibly mark it until the popover was closed and
  reopened, and future reminders could render under the "Completed" heading. The
  list is now one flat sequence instead of four separate lists sharing a cell pool.
- The reminder compose form silently refused to save once its carried-over time
  had passed — the Add button just greyed out with no explanation. It now resets
  the time and says why it can't save.
- Notification and launch-at-login failures were discarded, so both could fail
  invisibly. Both now report what went wrong, and the launch-at-login toggle
  re-syncs with System Settings instead of going stale.
- With no owners or tags, `flow owner list` and `flow list tags` print a sentence
  rather than an empty table, which the parsers turned into a bogus owner named
  "No" and a tag named "(no". Rows are now validated structurally, and tags use
  `--format json` where available.

### Breaking

- **Requires macOS 15 or newer** (was 13). Swift 6 ships only in Xcode/Command
  Line Tools 16, which need macOS 14.5+, so older systems cannot compile flow-bar
  at all. macOS 13 and 14 users should stay on v0.2.1.
- Installing or upgrading via Homebrew now requires a Swift toolchain
  (`xcode-select --install`).
- **macOS will ask once more for permission to control your terminal.** The
  signing identity changes from the release certificate to your per-machine one,
  which macOS sees as a different app. It only happens on this upgrade.

## v0.2.1 — 2026-07-13

### Fixed

- Launch crash on the notarized/release build: the notification-permission
  check ran its completion on a background queue while inheriting main-actor
  isolation, tripping a Swift concurrency assertion. (v0.2.0 crashed on start.)

## v0.2.0 — 2026-07-09

### Added

- **Reminders.** A new Reminders section (bell icon in the left rail) that fires
  native macOS notifications at a time you choose.
  - Standalone reminders, or reminders **linked to one or more tasks**.
  - Compose form with a date & time picker, quick-fill presets (In 1h / This
    evening / Tomorrow 9am), an optional multi-line note, and a searchable,
    multi-select task picker with **status (in-progress / backlog) and tag**
    filters.
  - Tapping a notification returns you to the reminder inside flow-bar; each
    linked task is one click to open (switching flow root first if needed).
  - **Snooze** and **Mark complete** actions on the notification banner and in
    the list; reminders grouped into Overdue / Today / Upcoming / Completed,
    with a rail badge for due + overdue counts.
  - The flow-bar logo shows on the notification.
  - The only permission required is **Notifications** (a one-time prompt);
    reminders still save if it's denied.

## v0.1.0 – v0.1.14

Foundation and expansion: menubar task switcher, Overview metrics, Needs-you
inbox, Projects, Playbooks, Owners, and Tags; task/project intake; inline brief
peek; a global hotkey and Settings window; multiple flow roots and a terminal
backend picker; persistent-grant code signing, in-app self-update, and a
drag-to-Applications DMG.
