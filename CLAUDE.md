# flow-bar

A lightweight native macOS **menubar app** for the [flow](https://github.com/Facets-cloud/flow)
dashboard + task switcher. Click the menubar icon → search/filter your
in-progress tasks → press Enter (or click) to switch to one. A Team tab
shows org-wide activity from flow-workspace.

## Build & run

The host has the **Swift toolchain via Command Line Tools only — no full
Xcode** (`xcodebuild` is unavailable). Everything is driven by SwiftPM.

```sh
swift build                 # debug build of all targets
swift run flowbar-smoke     # prints decoded in-progress tasks (data-path check)
./build-app.sh              # assemble flow-bar.app (release + ad-hoc sign)
./build-app.sh --run        # ...and launch it
```

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
  - `Models.swift` — `FlowTask` (Codable, matches the JSON), `TeamMember`/
    `TeamActivityTask`.
  - `FlowClient.swift` — binary discovery (+ a generous PATH so GUI launches
    find `flow`/`flow-workspace`/`claude`), `Process` runner, `inProgressTasks`,
    `teamActivity` (text parser — `flow-workspace activity` has no JSON mode),
    `doTask`.
- **`flow-bar`** (executable): the SwiftUI app.
  - `FlowBarApp.swift` — `@main` + `MenuBarExtra` (`.window` style; `.accessory`
    activation policy / `LSUIElement` = menubar agent, no dock icon).
  - `Store.swift` — `@MainActor ObservableObject` (macOS 13 compatible, not the
    macOS 14 `@Observable` macro). Polls tasks every 20s; loads team on demand.
  - `Views/` — `MenuContentView` (header, Tasks/Team toggle, search, footer),
    `TaskRow`, `TeamView`.
- **`flowbar-smoke`** (executable): data-path verification.

## How "switch to a task" works

The Tasks list is in-progress only, and every in-progress task has a
`session_id` (flow schema invariant). Selecting a row shells out to
`flow do <slug>`, which **focuses the task's existing tab if its session is
live, or spawns a new one**. flow's terminal backend needs a one-time macOS
**Accessibility** grant; that's expected. We deliberately do NOT reimplement
the spawn (hand-rolling a resume can't focus a specific existing tab).

## Gotchas

- macOS 13+ only (`MenuBarExtra`). Keep `Store` on `ObservableObject` (not
  `@Observable`) to preserve the v13 floor.
- The app bundle is **ad-hoc signed**; on first run you may need
  `xattr -d com.apple.quarantine flow-bar.app`. Signing/notarization is a
  later concern.
- `flow-workspace activity` is **text, not JSON** — parsed by
  `FlowClient.parseActivity`. If its output format changes, update that
  parser. It also makes a network call; the Team tab degrades to a
  "Workspace unavailable" state on failure.
- flow binaries live at `~/.local/bin/flow` and `~/go/bin/flow-workspace`;
  `FlowClient.searchPATH` lists the dirs we probe.

## Status

v1 phases 1–6 complete: data layer, menubar shell, search switcher, polling +
due badge + dynamic icon, team view, docs. Tracked in flow as task `flow-bar`
(project `side-quests`, `#flow`).
