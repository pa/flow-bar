# Changelog

All notable changes to flow-bar, newest first. The top section is published as
the GitHub release notes when a version is tagged.

## Unreleased

### Added

- **Pick your work source: `flow` or the praxis harness (`prx`)** — behind an
  experiment flag, because the praxis path is not GA:
  `defaults write cloud.facets.flow-bar experimentalPraxisBackend -bool true`.
  Without it nothing changes: the picker is hidden and the app is `flow`, even
  if a praxis selection is already stored. Clearing the flag is therefore a
  complete way back rather than a half-migration. With it, Settings gains
  a **Work source** section. On praxis, tasks, projects, briefs, notes and tags
  come from `prx work … -json`, and flow's owners are replaced by praxis
  schedules (`prx schedule … -json`) — same pane, named the way your CLI names
  it. What praxis has no equivalent of is hidden rather than faked: no Playbooks
  rail item, no runs tile, no AI-memory card. Existing installs are untouched —
  an absent setting still means `flow`.
- **Switching to a task under praxis** opens your terminal on a `prx` session
  already bound to the task, rooted in its work directory, so notes written
  there are attributed. It goes through `open` rather than AppleScript, so
  unlike the flow path it needs no Automation grant.
- **Session alerts fire for praxis sessions.** The hook that makes a permission
  prompt detectable at all — the transcript shows nothing until it is answered
  — is now installed into the praxis harness's `settings.json` as well as
  Claude Code's. praxis maps `Notification` onto its `attention_needed` event,
  which fires exactly when the runtime starts blocking on you and cannot block
  or delay it, so a wedged flow-bar still cannot get in the way of a prompt.
  Rows read the harness's own wording where there is any: the question a
  session stopped on, or “Bash needs approval”.
- **Live sessions work under praxis too.** flow-bar reads praxis session
  transcripts (`~/.praxis/agent/sessions/<id>/session.jsonl`) alongside Claude
  Code and Codex, so the menubar alert and the Needs-you list behave the same
  whichever harness is running.
- **A Check button** next to the work source reports which binary answered and
  whether it has the commands the app needs. It exists because a `prx` too old
  to have `work` otherwise looks exactly like having no tasks.

### Fixed

- **Every pane showing zero, and a spinner that never stopped.** The dashboard
  fires ~16 CLI reads at once from `Task.detached`, which runs on Swift's
  cooperative thread pool — capped near the core count. Draining each child's
  two pipes on their own queues needed three threads per call, so at that
  concurrency the pool starved and the reads that would release each caller
  could never be scheduled; an unbounded wait on the cleanup path then lost the
  thread for good, and the app degraded until every call timed out. Both pipes
  are now drained on the caller's own thread with `poll(2)` and a deadline: no
  extra threads, no unbounded wait. The 16-call reproduction went from hanging
  indefinitely to 634ms.
- **A wedged CLI can no longer hang the app.** Every read is bounded and the
  child is killed if it overruns. Found the hard way: `prx` treats arguments it
  does not recognise as a *prompt* and tries to become an interactive session,
  so asking an older `prx` for tasks hung forever with the popover spinning.
- **Large CLI output can no longer deadlock a read.** Both streams are watched
  together; reading them in sequence stalls as soon as the child fills the
  other pipe's buffer, which a task list with long briefs comfortably exceeds.

### Changed

- **Opening a task under praxis goes to the tab it is already in**, the way
  `flow do` does, instead of opening a second tab onto the same session. The
  running session is found in `ps` by the id its own process carries, its
  controlling tty identifies the tab, and AppleScript selects it; a session
  started by hand — which carries nothing in argv — is found through the
  harness's ownership record instead, with the pid checked against `ps` so a
  recycled one cannot focus a stranger's window. Only iTerm2 and Terminal
  expose a tty per tab, so the other picks open a new tab rather than a wrong
  one, and the first focus asks for Automation permission.
- **Opening a task under praxis resumes its session** instead of starting a
  blank one: flow-bar moves to the task's work directory and reopens the most
  recent session that actually has a conversation in it (`prx -resume`). A task
  with no such session still gets a fresh one bound to it.

  The selection deliberately ignores two things that look relevant and are not.
  A segment's "open" flag is not liveness — it only clears on a clean exit, so
  abandoned sessions stay open forever; treating it as in-use made every
  session unresumable, so each click opened a blank one and left another open
  segment behind for the next click to trip over. And a session that IS live is
  not skipped: `prx -resume` already falls through to following a session whose
  live writer refuses the resume, which beats opening an empty session beside
  the one you asked for.

## v0.4.3 — 2026-09-17

### Fixed

- **The session that lit the menubar icon no longer vanishes as you open the
  popover.** Finished turns were marked "seen" in the same breath as showing the
  panel, so the rows were retired before it was drawn and you arrived at
  "Nothing needs you" having just clicked an orange icon. Sessions genuinely
  blocked on a prompt were never affected, which is why it looked intermittent.
- **Back from a brief returns where you were.** Reading a playbook's brief and
  pressing Back dropped you on the playbooks list instead of the playbook you
  had open; the same happened in Projects, Tags and Owners. The brief was
  replacing the section rather than covering it, which threw away where you
  were standing.
- **A playbook run stopped on a prompt now raises an alert.** It never did.
  `flow list tasks` leaves playbook runs out unless asked for them, so the
  watcher's candidate list could not contain one, and a run waiting on you sat
  there while the menubar said everything was fine. Owner-dispatched tasks were
  always covered, since they are ordinary tasks carrying an `owner:` tag.

### Added

- **Right-click a task to choose how it opens.** "Open" or "Open, skipping
  permission prompts" — the second is disabled on a task whose tab is still
  running, with the reason, because a session's permission mode is fixed when
  its process starts. ⌥-click still does the same thing for anyone who prefers
  the modifier.

### Changed

- **Session alerts now mean one thing: something is waiting for you to answer
  it.** A permission prompt, a question Claude asked, a plan waiting for
  approval, a Codex approval request. A finished turn no longer counts, in the
  icon or in the list — every turn ends, so it was firing constantly and the
  icon was orange nearly all day. You keep the "you left this one hanging"
  nudge: when Claude Code itself decides a session has been waiting, it says so
  through the hook, and that still alerts, in Claude's own words.
- **Needs-you rows lead with the task slug.** The slug is what you type, what
  you search on, and the only thing that opens a task, so it now sits on the
  first line and the task name moves below it. The name is dropped when it says
  nothing the slug does not, which is what keeps a playbook run at two lines
  instead of printing its own slug twice.
- **Opening a playbook shows its runs first.** Its brief moved to a button in
  the header, next to Run, and each run already had its own. The two levels are
  now reachable from the rows they describe instead of from one block of
  markdown that pushed the runs off the bottom.
- **Headless `flow do --auto` runs are no longer watched.** They are live and
  they write transcripts, but there is no tab to jump to and they cannot prompt,
  so the only alert they could produce is one nobody can act on.

## v0.4.2 — 2026-09-15

### Fixed

- **Clicking the menubar icon closes the popover again.** It had become
  impossible to dismiss from the icon: the popover closes on mouse-down, but the
  button's action arrives on mouse-up and read that dismissal as a request to
  open, so every closing click immediately reopened it. A click that lands
  within a moment of a dismissal is now treated as the back half of the same
  click. Opening and closing with the keyboard shortcut was never affected.

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
