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
the drill-in list flags/split, the session watcher's transcript parsers
(Claude + Codex), locator and session-id parser, the `--kind`/`--auto` coverage
rules, and the slug-first row label. Run `swift run flowbar-tests`.

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
    and `sessionInfo`/`parseSessionInfo` (a task's harness session binding plus
    the state of any `flow do --auto` run on it).
  - `SessionTranscript.swift` — `TranscriptParser` folds Claude Code session
    JSONL into a `SessionActivity`, plus `TranscriptTime` (a hand-rolled
    ISO-8601 scanner). Pure and incremental, so the harness covers it.
  - `SessionTail.swift` — `SessionLocator` (session id → transcript file) and
    `TranscriptTail` (delta reads over one transcript).
  - `RelativeAge.swift` — compact `4s` / `2m` / `1h` ages for session rows.
  - `SessionRowLabel.swift` — decides whether a task name earns its own line
    under the slug on a session row.
  - `SessionAttention.swift` — `isBlocked`: the single predicate behind the
    icon and the Needs-you session list.
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

Hold ⌥ while clicking (or pressing Enter) to add
`--dangerously-skip-permissions`. It only reaches the harness when `flow do`
actually spawns, so it is a no-op on a task whose tab is already open. See
"Session alerts" for why this is a modifier and not a preference.

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
  **A finished turn is not an alert** (`SessionAttention.isBlocked`). The
  transcript's `awaitingPrompt` only says the assistant stopped talking, which
  is how every turn ends: measured on this machine, 8 of 12 live sessions were
  sitting at one, so reporting them kept both the icon and the list permanently
  full. The alert means "a human has to answer this" and nothing else. The
  genuinely-waiting case is not lost, it just arrives by the other route -
  Claude Code raises `idle_prompt` / `agent_needs_input` through the hook when
  *it* judges a session is waiting, and those become `waitingOnYou` with
  Claude's own wording.
  An earlier design badged finished turns and tracked which ones you had seen
  (`seenTurnEnds` / `markTurnEndsSeen`) so the icon could clear itself. Both are
  gone, and the bug they produced is worth remembering: marking seen ran in the
  same runloop turn as `popover.show`, so the rows were retired before SwiftUI
  laid the panel out and you clicked an orange icon to arrive at "Nothing needs
  you". Only hard blocks survived it, which made it look intermittent. Once a
  finished turn is not reported at all, there is nothing left to clear.
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
- **The watched set is "live sessions a human can reach", which is not the same
  as "in-progress tasks".** Four kinds of work carry a session, and they do not
  all qualify.
  - *Regular tasks* qualify. This was the whole candidate set until v0.4.3.
  - *Playbook runs* qualify, and used to be invisible.
    `flow list tasks` defaults to `--kind regular`, and a run is not hidden
    behind a flag the way a done task is, it is absent. So `inProgressTasks()`
    could never return one, and a run stopped on a permission prompt sat there
    while the icon said all clear. A run is a task: it has a session flow
    reports `live`, and `flow do <run-slug>` switches to it exactly like any
    other. `inProgressTasksIncludingRuns()` passes `--kind all`, and falls back
    to the plain list if an older flow rejects the flag, because a watcher that
    goes permanently dark is worse than one that misses runs.
  - *Owner-managed tasks* need no special case. An owner dispatches ordinary
    `kind=regular` tasks tagged `owner:<slug>`, so they were already in the set.
  - *Headless runs are excluded on purpose.* `flow do --auto` is live and writes
    a transcript, but there is no tab to focus and `--auto` implies
    `--dangerously-skip-permissions`, so it cannot raise a prompt. The only
    state it can reach that looks like attention is a finished turn, and nobody
    can type into it. `parseSessionInfo` reads the `auto_run:` line from
    `flow show task` and the watcher drops anything `running`. Owner ticks are
    the same shape: headless, no tab, and no task of their own to jump to.
- **⌥-click reopens with permission prompts skipped, and that is deliberately
  not a setting.** A persistent "always skip permissions" toggle is a dangerous
  mode whose state lives in a window you are not looking at when you click, and
  what it suppresses is the prompt that stops a command you did not mean to run.
  A modifier applies to one open and nothing else. It is also safe to read on
  every click path, Enter included, because `flow do` returns as soon as it
  focuses an existing tab: the flag never reaches `claude` for a live task, so
  on most of this list holding ⌥ changes nothing at all. Where it does matter is
  an in-progress task whose session has died, which `flow do` resumes by
  spawning `claude --resume <id>`.
- **Skipping permissions makes detection sharper, not blinder.** In
  `bypassPermissions`, `TranscriptParser.mayPrompt` goes false and the inferred
  debounce stops firing, which is right: there is no prompt for a slow tool to
  be waiting on. Everything exact survives. `AskUserQuestion` and `ExitPlanMode`
  still block with no debounce, Codex still emits `*_approval_request`, and the
  hook's matcher still covers `idle_prompt` and `agent_needs_input`. Only
  `permission_prompt` disappears, which is the point of the mode.
- **Rows lead with the slug.** The name went where it belongs, on a second line,
  and only when it earns one. The slug is what you type, what you search on, and
  the only string `flow do` takes, so a row titled by task name made you
  translate before you could act. `SessionRowLabel.secondary` drops a name that
  contributes no word the slug does not already carry, which covers a task named
  after its own slug and every playbook run, whose name is "<playbook> run
  <run-slug>". Sorting moved to the slug for the same reason: sorting on a
  string the eye never reads first looks unsorted. Cost is about 13pt on rows
  that do show a subtitle (43pt to 56pt), so roughly eight fit the Needs-you
  pane instead of ten, and the list already scrolls.
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
- `Updater.swift` **never self-installs the released zip** on the
  `homebrew-source` channel. It would break three things, two silently:
  1. **The Automation grant dies.** TCC keys the grant to the bundle's
     Designated Requirement. Source installs are signed with a *per-machine*
     identity (`create-signing-cert.sh`); the zip carries CI's own persistent
     cert. Swapping them changes the DR, so `flow do` starts failing with
     -1743 and no message — and it would thrash, since the next `brew upgrade`
     signs locally again.
  2. **The UI stops being native.** CI builds on `macos-15`, so the zip links
     against that SDK, and SwiftUI takes its appearance from the linked SDK.
  3. **Homebrew's receipt goes stale**, so brew and the app disagree.
- **Instead the Update button delegates to brew** (`BrewUpgrade`,
  `BrewUpgradeRunner`) — still one click. The app writes a script, launches it
  with `POSIX_SPAWN_SETSID` so it **outlives the app** (the cask's
  `uninstall quit:` kills it partway), quits itself, and the script pulls the
  tap, runs `brew upgrade`, records `ok`/`failed` in a marker file and
  relaunches the app. The relaunch is the progress signal; the marker is read at
  the next launch (`reportLastUpgradeResult`), since nothing is running when the
  result is known. flow-bar quitting *itself* first is deliberate: it leaves
  brew's AppleScript `quit` with nothing to do, which keeps the whole upgrade
  off the Automation grant.
- **The tap refresh is not optional.** flow-bar is in a third-party tap, and
  `brew upgrade` can't see a new version until that tap's checkout is pulled —
  which auto-update skips within `HOMEBREW_AUTO_UPDATE_SECS` or under
  `HOMEBREW_NO_AUTO_UPDATE`. Verified: with a stale tap `brew outdated --cask
  flow-bar` printed nothing while 0.4.0 was already published; after pulling it
  printed `flow-bar (0.3.1) != 0.4.0`.
- **`FBBuildSDK` must not be guessed from `xcrun --show-sdk-version` alone.**
  With Xcode selected it can still resolve to the Command Line Tools SDK path
  and fail outright, which used to stamp `unknown` and silently disable the
  rebuild nudge that exists to catch a non-native build. `build-app.sh` now asks
  for the `macosx` SDK explicitly, falls back to the OS version, and finally
  prefers what the linked binary actually records in `LC_BUILD_VERSION`.
- The prebuilt `.dmg`/`.zip` on releases exist only for people who won't install
  a toolchain, and for the in-app updater that serves them.
- `.github/workflows/verify-install.yml` asserts the acceptance test: the
  installed binary's `LC_BUILD_VERSION` sdk major must equal the runner's OS
  major. If that regresses, the app still works — it just silently stops being
  native, which is exactly the failure nobody notices.

## Panes and overlays

**The section pane stays in the view hierarchy while the brief peek or the
intake form covers it** (`MenuContentView.pane` is a `ZStack`, not an
if/else). Replacing it destroys the section view and every `@State` it owns.
The symptom was that reading a playbook's brief and pressing Back returned you
to the playbooks list rather than to the playbook you were in — `selected` had
gone with the view. Projects, Tags and Owners each had it too.

The covered pane is hidden with `opacity(0)` and `.disabled`, not removed, so
it keeps its state but cannot take clicks or hold the text cursor underneath
whatever is on top of it.

## Playbooks

Opening a playbook leads with its **runs**. Its own brief is a button in the
header beside Run, and each run row already carried one — so both levels are
reachable from the row they describe. The brief used to render inline above the
runs, which pushed them off the bottom of a 560pt popover.

`Store.peekBrief(_:kind:)` takes the entity kind because a task and a playbook
render identically in the peek but are read with different `flow show`
subcommands.

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
