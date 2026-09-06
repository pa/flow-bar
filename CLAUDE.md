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
and the drill-in list flags/split. Run `swift run flowbar-tests`.

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
    via text parsers), `dashboardMetrics`, `doTask`/`runPlaybook`/owner actions.
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

Phases 1–11 complete. v1 (P1–6): data layer, menubar shell, search switcher,
polling + due badge, docs. Expansion (P7–11): icon-rail nav +
metrics dashboard + brand "w" icon, Needs-you inbox, Projects drill-in,
Playbooks, Owners. Tracked in flow as task `flow-bar` (project `side-quests`,
`#flow`).
