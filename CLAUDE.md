# flow-bar

A lightweight native macOS **menubar app** for the [flow](https://github.com/Facets-cloud/flow)
dashboard + task switcher. Click the menubar icon → search/filter your
in-progress tasks → press Enter (or click) to switch to one. An icon rail
covers Overview, Needs-you, Playbooks, Projects, and Owners.

## Build & run

Everything is driven by SwiftPM — there is no Xcode project. The host does now
have full Xcode, but **keep the build Command-Line-Tools-compatible**: the
Homebrew cask compiles on the user's machine, and requiring a ~10 GB Xcode
download to install a menubar app is not acceptable.

```sh
swift build                 # debug build of all targets
swift run flowbar-tests     # unit tests (exits non-zero on failure)
swift run flowbar-smoke     # prints decoded in-progress tasks (data-path check)
./build-app.sh              # assemble flow-bar.app (release + ad-hoc sign)
./build-app.sh --sign-local # ...signed with the stable per-machine identity
./build-app.sh --run        # ...and launch it
```

**Tests:** unit tests are a plain executable harness rather than XCTest, so they
run for anyone building from source with Command Line Tools only. (Full Xcode is
present on this host now, so XCTest *would* work here — don't "fix" the harness
on that basis; it exists for the source-install path.) The harness lives in
`Sources/flowbar-tests` (see `T` in `Harness.swift`) and covers the pure
`FlowBarCore` logic: model decoding, `filtered`/`sorted` helpers, the
owners/tags text parsers, `DashboardMetrics`, the markdown block parser,
the drill-in list flags/split, and the session watcher's transcript parsers
(Claude + Codex), locator and session-id parser. Run `swift run flowbar-tests`.

`build-app.sh` produces `flow-bar.app` (gitignored). To relaunch after a
rebuild, kill the old instance first:

```sh
pkill -f 'flow-bar.app/Contents/MacOS/flow-bar'; ./build-app.sh --run
```

## Architecture

- **The flow CLI is the API.** We never read `~/.flow/flow.db` directly —
  reads go through `flow list tasks --format json`, actions through real
  subcommands. This keeps us schema-proof and respects flow's invariants.
- **`FlowBarCore`** (library): pure data/logic, no UI.
  - `Models.swift` / `EntityModels.swift` — `FlowTask`, `Project`, `Playbook`,
    `PlaybookRun`, `Owner`, `TagCount`, `DashboardMetrics`.
  - `Markdown.swift` — block-level markdown parser (headings, paragraphs,
    lists incl. ordered/nested/checkbox, fenced code, tables, blockquotes,
    rules). Pure data, no AppKit, so the harness covers it.
  - `FlowClient.swift` — binary discovery (+ a generous PATH so GUI launches
    find `flow`/`claude`), `Process` runner, entity reads (JSON; owners/tags
    via text parsers), `dashboardMetrics`, `doTask`/`runPlaybook`/owner actions,
    and `sessionInfo`/`parseSessionInfo` (a task's harness session binding).
  - `SessionTranscript.swift` — `TranscriptParser` folds Claude Code session
    JSONL into a `SessionActivity`, plus `TranscriptTime` (a hand-rolled
    ISO-8601 scanner). Pure and incremental, so the harness covers it.
  - `SessionTail.swift` — `SessionLocator` (session id → transcript file) and
    `TranscriptTail` (delta reads over one transcript).
  - `RelativeAge.swift` — compact `4s` / `2m` / `1h` ages for session rows.
- **`flow-bar`** (executable): the SwiftUI app.
  - `FlowBarApp.swift` — an AppKit `NSStatusItem` + `NSPopover` driven from an
    `AppDelegate` (NOT `MenuBarExtra`, which can't re-render the icon while the
    popover is closed). Only the `Settings` scene is SwiftUI-App-level.
    `.accessory` activation policy / `LSUIElement` = menubar agent, no dock icon.
  - `AppInfo.swift` — build-time provenance (`FBInstallChannel`, `FBBuildSDK`)
    stamped into Info.plist; decides whether the updater may self-install and
    whether the UI is running SDK-behind.
  - `SelfSign.swift` — keeps the code identity stable so the TCC Automation
    grant survives upgrades. See "Distribution" below.
  - `Store.swift` — `@MainActor ObservableObject` (deliberately not the
    `@Observable` macro — see Gotchas). Polls the in-progress list every 120s
    (instant on open + after switch); metrics/playbooks/owner-tasks load on
    demand. `refreshMetrics` runs its reads concurrently. Switching dismisses
    the popover immediately and runs `flow do` fire-and-forget.
  - `BrandIcon.swift` — flow's "w" wave (from the public repo's
    `assets/flow-logo.svg`) embedded as base64, sized ~11pt for the menubar.
  - `Views/` — `MenuContentView` is the root: left **icon rail** + content
    pane (per-section global search, header, footer). Sections: `TasksView`
    (home), `InboxView` ("Needs you": owner questions + overdue + waiting),
    `DashboardView` (metric tiles), `ProjectsView` (drill into a project's
    tasks), `PlaybooksView` (brief + notes + runs + Run), `OwnersView`
    (questions/tasks + pause/resume). Plus `TaskRow`. (A Team view existed
    but was removed.)
  - `SessionMonitor.swift` — kqueue watcher over live sessions' transcripts;
    drives the menubar alert and the Needs-you list. See "Session alerts".
  - `MarkdownText.swift` — an `NSTextView` (explicit **TextKit 1** stack)
    rendering `Markdown.parse`'s blocks. Used by task detail, playbook
    detail, and every update tile.
- **`flowbar-smoke`** (executable): data-path verification.

## How "switch to a task" works

The Tasks list is in-progress only, and every in-progress task has a
`session_id` (flow schema invariant). Selecting a row shells out to
`flow do <slug>`, which **focuses the task's existing tab if its session is
live, or spawns a new one**. flow's terminal backend needs a one-time macOS
**Accessibility** grant; that's expected. We deliberately do NOT reimplement
the spawn (hand-rolling a resume can't focus a specific existing tab).

## Session alerts

flow-bar watches the harness sessions behind your live tasks and turns the
menubar icon orange when one is **stopped waiting for you**. Clicking it opens
the popover straight on Needs-you, where the blocked sessions are listed first;
clicking one runs `flow do` and lands you in its terminal. **Opt-in**
(Settings > Session alerts): it is the only part of the app that observes
anything while the popover is closed.

What this knows that a raw session monitor can't is the *task*. Other tools can
only say "~/dev/projects/flow-bar - running"; flow-bar knows the binding, so the
row reads "flow-bar-notch - waiting on you".

- **It is a watch, not a poll**, so the "no background polling" promise survives.
  kqueue vnode sources: one per live transcript (each event reads only the
  appended bytes), plus one on the flow root **directory** - the directory,
  because SQLite in WAL mode writes `flow.db-wal` and a watch on `flow.db` alone
  would miss most mutations. The only timer is a single-shot armed while a tool
  call is outstanding: kqueue can say a file changed, never that 8 seconds passed
  with nothing happening, and that elapsed-time transition is exactly what
  "waiting on you" means (`TranscriptParser.nextTransition`). The icon pulse is a
  second timer, and it runs only while something is actually blocked.
- **"Blocked" is decided by exact signals first, inference only as a residue.**
  In order:
  0. A **Claude Code `Notification` hook** (`ClaudeHookConfig`,
     `SessionAlertHook`) - the only exact way to see a permission prompt, and it
     carries Claude's own wording ("Bash wants to run: npm test"). Chosen over
     `PermissionRequest` because `Notification` is informational: it cannot
     allow/deny, so a wedged flow-bar can never delay a prompt the user is
     waiting on. Matcher is deliberately narrow -
     `permission_prompt|idle_prompt|agent_needs_input|elicitation_dialog`,
     never `*`, so `auth_success` and `agent_completed` raise nothing.
  1. Codex `*_approval_request` - it said outright that it is asking.
  2. An outstanding tool in `SessionActivity.blockingTools`
     (`AskUserQuestion`, `ExitPlanMode`) - tools whose whole job is to stop and
     ask, so no debounce applies. This is the common case: `AskUserQuestion` is
     how Claude asks anything.
  3. Any other outstanding tool, past the debounce - **only as a fallback**.
     Requires `mayPrompt` (a mode where a prompt can appear at all; `auto` and
     `bypassPermissions` can't) AND `inferPermissionPrompts`, which is false
     whenever the hook is active. With the hook in effect a real prompt
     announces itself, so guessing can only add mistakes - a slow tool that a
     `permissions.allow` rule auto-approved raises no prompt, yet the debounce
     would fire on it. The Settings slider is therefore hidden while the hook is
     active: a control that changes nothing is worse than no control.
  Separately, a **finished turn you haven't seen** also counts (`needsYou`) -
  the session is sitting idle until you type. It behaves like an unread badge,
  cleared when the popover opens (`markTurnEndsSeen`) and re-armed by the next
  turn end, because the stored value is the turn's own timestamp. A five-minute
  window was tried first and was simply wrong: a turn that ended six minutes ago
  still wants you.
  Measured on a real transcript: `AskUserQuestion` sat unanswered for 62
  minutes while every `Bash` in the same session finished in a 0.1s median and
  a 10.3s max. The populations don't overlap, so guessing between them was
  never necessary - and a bare 8s debounce would have fired on that 10.3s Bash.
  `abandonAfter` (30 min) still stops a killed session badging forever.
- **The hook gives the start; the transcript gives the end.** A permission
  prompt leaves NO trace in the JSONL until it is answered, so only the hook can
  see it begin; an alert is retired once the transcript shows activity dated
  after it. But **Claude Code flushes its transcript at turn boundaries, not per
  entry** (measured: a mid-turn session left its JSONL untouched for minutes),
  so that retirement can lag a whole turn. Hence two more outs: clicking the row
  dismisses the alert immediately (`dismissAlert`), and `alertExpiry` (30 min)
  catches "answered it, then walked away".
- **`~/.claude/settings.json` belongs to the user and other tools write to it.**
  In the wild it already held CodeIsland's `Notification` hook and orca's
  `PermissionRequest` hook. So the splice is surgical and covered by tests on
  realistic input: unknown keys survive, other entries survive, removal deletes
  only entries carrying our marker comment, and empty `Notification`/`hooks`
  keys are pruned rather than left as `{}`. The original is copied to
  `settings.json.flow-bar.bak` before the first write. Installed when the
  Session-alerts toggle goes on, removed when it goes off.
- **Only flow-managed sessions count.** Every row goes somewhere, and `flow do`
  needs a slug; an unmanaged session has nowhere to go.
- **Both harnesses.** flow bootstraps under Claude Code *or* Codex
  (`flow do --harness`), and `flow show task` does NOT say which - so it is
  inferred from where the transcript turns up: a Claude session id is a whole
  filename under `~/.claude/projects/<mangled-cwd>/`, a Codex thread id is the
  *suffix* of `~/.codex/sessions/YYYY/MM/DD/rollout-<ts>-<id>.jsonl`. Both are
  UUIDs, so there is nothing to disambiguate. `TranscriptParser` sniffs the
  dialect per line (Claude puts substance in `message`, Codex in `payload`).
- **`flow list tasks --format json` does NOT emit `session_id`.** It's only in
  `flow show task <slug>` as text. Hence one `flow show` per *live* task.
- **A transcript's directory is keyed to the cwd the session launched from, not
  the task's `work_dir`**, and the mangled name (`-Users-p-dev-projects`) can't
  be decoded back (a real directory may contain a dash). Find transcripts by
  session-id filename; read `cwd` from inside the transcript.
- **The alert recolours the icon rather than badging it**, so the status item
  never changes width and no menubar item shifts. It deliberately overrides the
  monochrome-icon preference - that setting is about the resting appearance, and
  an alert that honoured it would be invisible.
- **The pulse is separable from the alert** (`sessionAlertPulse`, on by
  default). Motion is why the icon catches a glance in a row of small coloured
  glyphs, but it is also the part that grates, so it can be switched off and the
  orange tint remains - no information is lost, only the movement. The default
  is read via `object(forKey:) as? Bool ?? true` rather than `bool(forKey:)`,
  which cannot distinguish "absent" from "explicitly false" and would therefore
  default it off; a `register(defaults:)` would also be too late, since the
  Store is built before `applicationDidFinishLaunching`.
- Trace it with `defaults write cloud.facets.flow-bar sessionWatchVerbose -bool true`.

## Gotchas

- **macOS 15+.** The floor is set by the source-install path: Swift 6
  (`swift-tools-version:6.0`) ships only in Xcode/CLT 16+, which need macOS
  14.5+ — so a macOS 13 user cannot compile this at all. `ContentUnavailableView`
  and `.onKeyPress` are therefore available without `#available` gating. Keep
  `Store` on `ObservableObject` (not `@Observable`) anyway: it's one
  `@MainActor` object shared everywhere and converting it is a large, risky
  refactor with no user-visible benefit.
- **Signing is load-bearing, not a later concern.** `FlowClient.spawnDisclaimed`
  deliberately does *not* disclaim responsibility for the AppleScript terminal
  backends, so flow-bar itself owns the TCC Automation grant — and TCC keys that
  grant to the bundle's Designated Requirement. An ad-hoc signature's DR is the
  code hash, so it changes every build and the grant is dropped on every
  upgrade (`flow do` then fails with -1743, silently). Source installs get a
  per-machine self-signed identity (`scripts/create-signing-cert.sh`, mirrored
  in `SelfSign.certScript`); CI release builds get `flow-bar-signing`. The cert
  does **not** need to be a trusted root — trust is required to *validate* a
  signature, not to produce one.
- **Markdown selection needs one text view, not many.** SwiftUI's
  `.textSelection(.enabled)` selects within a single `Text`; a drag can never
  span two. The brief pane is therefore one `NSTextView` per block-group
  (`MarkdownText`), which is also what gives links, formatted `⌘C` and the
  Services menu. It uses an **explicit TextKit 1 stack** on purpose:
  `NSTextTable` (which draws code-block, table, quote and rule cells) and
  `NSLayoutManager.usedRect(for:)` (which `sizeThatFits` measures height with)
  are both TextKit 1 facilities — let `NSTextView` pick TextKit 2 and
  `layoutManager` is nil. The accepted trade is that a fenced code block wraps
  instead of scrolling horizontally; a text view cannot host an
  independently-scrolling sub-region.
- **`AttributedString(markdown:)` emphasis is invisible to AppKit.** It reports
  bold/italic/code as `inlinePresentationIntent`, which SwiftUI's `Text`
  understands and `NSTextView` does not. `MarkdownRenderer.inline` translates
  each run's intent into a concrete `NSFont`; drop that and every run silently
  renders at the base weight.
- **A `.help()` inside a Button's label never fires.** A plain-styled `Button`
  is one platform view, so a tooltip declared on an `Image`/`Text` within its
  label has nothing to attach to. Put anything that needs a tooltip *beside*
  the button (see `TaskRow.badges`), or fold its text into the button's own
  `.help()`. Also avoid `.help("")` — an empty tooltip owner is worse than
  none.
- **`flow list tasks` hides done tasks** unless given `--include-done`, and
  archived ones unless given `--include-archived`. Any view that shows a count
  and then a list must pass both, or it contradicts its own header — that's
  what `FlowClient.listTasksArgs` exists to make testable.
- **Liveness is flow's to report, not flow-bar's.** `flow list tasks --format
  json` emits `live` (resolved from the recorded session's pid), so the green
  dot means "the harness session is actually running", not "in progress". Do
  not reimplement local tab detection; `FlowTask.live` is the source of truth.
- `flow owner list` and `flow list tags` are **text, not JSON** — parsed by
  `FlowClient.listOwners`/`listTags`. If their output format changes, update
  those parsers.
- The flow binary lives at `~/.local/bin/flow`; `FlowClient.searchPATH` lists
  the dirs we probe.

## Distribution

**The Homebrew cask compiles from source on the user's machine. Never add a
bottle or a prebuilt payload to the brew path.** SwiftUI picks its appearance
from the macOS SDK a binary was *linked against*, not the OS it runs on, so a
CI-built binary renders in compatibility mode on any newer macOS — forever.
Building locally is the entire point.

- `build-app.sh` is the **single build entry point** for CI, brew, and local
  dev. Keep logic there, not in the cask: `installer script:` is an escape
  hatch Homebrew is gradually narrowing, and a thin cask keeps a future move
  cheap.
- A **cask**, not a formula: formula installs run in Homebrew's sandbox, which
  denies reads of `~/Library/Keychains` and writes to `/Applications` — so a
  formula could neither sign with a stable identity nor install a real `.app`.
- Cask paths include the tarball's `flow-bar-#{version}/` wrapper. Homebrew only
  flattens a single extracted child when it is *not* a directory
  (`UnpackStrategy#extract_nestedly`), so GitHub's wrapper survives staging.
- `Updater.swift` **refuses to self-install** on the `homebrew-source` channel —
  swapping in a CI-built zip would undo the native build. It offers
  `brew upgrade --cask flow-bar` instead.
- The prebuilt `.dmg`/`.zip` on releases exist only for people who won't install
  a toolchain, and for the in-app updater that serves them.
- `.github/workflows/verify-install.yml` asserts the acceptance test: the
  installed binary's `LC_BUILD_VERSION` sdk major must equal the runner's OS
  major. If that regresses, the app still works — it just silently stops being
  native, which is exactly the failure nobody notices.

## Read-mostly philosophy

The app favours rich read views + only **safe** mutations inline (owner
pause/resume). Actions that spawn a terminal — switching to a task
(`flow do`) and running a playbook (`flow run playbook`) — are explicit,
user-initiated, and need the one-time Accessibility grant.

## Status

Phases 1–12 complete. v1 (P1–6): data layer, menubar shell, search switcher,
polling + due badge, docs. Expansion (P7–11): icon-rail nav +
metrics dashboard + brand "w" icon, Needs-you inbox, Projects drill-in,
Playbooks, Owners. P12: session alerts — the menubar icon flags a harness
session that is blocked on you (task `flow-bar-notch`, uncommitted). Tracked in
flow as task `flow-bar` (project `side-quests`,
`#flow`).
