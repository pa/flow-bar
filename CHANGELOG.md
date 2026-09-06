# Changelog

All notable changes to flow-bar, newest first. The top section is published as
the GitHub release notes when a version is tagged.

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
