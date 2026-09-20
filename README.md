# flow-bar

A lightweight, native macOS **menubar app** for [flow](https://github.com/Facets-cloud/flow) —
see what's in flight and switch between tasks without leaving the menubar.

<p align="center">
  <a href="https://pa.github.io/flow-bar/">
    <img src="docs/demo-poster.jpg" alt="flow-bar — menubar popover" width="380">
  </a>
  <br>
  <em><a href="https://pa.github.io/flow-bar/">▶ Watch the demo</a></em>
</p>

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
![Platform: macOS 15+](https://img.shields.io/badge/macOS-15%2B-black?logo=apple)
![Built with Swift](https://img.shields.io/badge/Swift-6-orange?logo=swift)

> flow-bar is a **companion** to a local work CLI. Out of the box that is
> `flow` — it reads your tasks through `flow … --format json` and switches to
> them with `flow do`. It can also be pointed at the **praxis harness**
> (`prx`), which keeps the same concepts natively; pick one under
> **Settings → Work source**. flow-bar finds `prx` at `~/.local/bin/prx`, where
> it installs itself, and otherwise looks on your `PATH`; the **prx binary**
> field overrides both when yours lives elsewhere.

## Two backends

> **The praxis backend is experimental and off by default.** Turn it on with
> `defaults write cloud.facets.flow-bar experimentalPraxisBackend -bool true`
> and the **Work source** picker appears in Settings. Turn the flag off and the
> app goes back to `flow` whatever is selected there, so it is a complete way
> out. Without the flag, flow-bar behaves exactly as it always has.

| | `flow` | praxis (`prx`) |
|---|---|---|
| Tasks, projects, tags | `flow list … --format json` | `prx work list … -json` |
| Brief + updates | `flow show task` | `prx work show -json` |
| Recurring agents | Owners (`flow owner`) | Schedules (`prx schedule`) |
| Playbooks & runs | yes | — *(pane hidden)* |
| AI-memory stats | `flow stats` | — *(card hidden)* |
| Work roots | named `FLOW_ROOT`s, switchable | — *(picker hidden; one agent dir)* |
| Sessions per task | one | many — *Open* lets you pick, or start a new one |
| Switch to a task | `flow do <slug>` | a `.command` that execs `prx -resume`/`-work` |

What praxis has no equivalent of is **hidden, not faked** — an empty pane that
can never fill is worse than no pane. The praxis path needs a `prx` that has
the `work` command; **Settings → Work source → Check** tells you which binary
answered and whether it does, instead of leaving you with a task list that is
silently empty.

## Features

- **Quick task switcher** — click the menubar "w", type to filter your
  in-progress tasks, hit Enter to jump into one (`flow do` focuses the live
  tab or opens a new one).
- **Overview dashboard** — exact, at-a-glance metrics: in-progress / backlog /
  done, overdue, stale, live, plus owners, runs, and projects. Tiles are
  clickable and route to the relevant view.
- **Session alerts** — the menubar icon turns orange when a Claude or Codex
  session is stopped waiting for you: a permission prompt, a question, a plan
  awaiting approval. Opt-in, and deliberately silent about a session that has
  merely finished a turn.
- **Needs you** — blocked sessions, owner questions, overdue, and waiting tasks
  in one list.
- **Projects** — per-project breakdown; drill in to see a project's tasks.
- **Playbooks** — run status and recent runs; open a run in the terminal or
  trigger a new run (new tab or background).
- **Owners** — status + next tick, parked questions, and safe pause/resume.
- **Create tasks & projects** — a `+` intake form with slug suggestions,
  duplicate + format validation, a searchable tag picker, and work-dir
  autocomplete; creates a new project inline if needed.
- **Tags** — browse every tag with counts and drill into a tag's tasks.
- **Brief peek** — read a task's brief + recent updates inline, and copy them —
  without switching to it.
- **Reminders** — set a reminder (standalone, or linked to one or more tasks)
  and get a native macOS notification at the time you pick. Tapping it returns
  you to the reminder in flow-bar, where linked tasks are one click to open.
- **Flow roots & terminal** — switch between multiple `FLOW_ROOT`s (personal,
  work, a demo) and choose the terminal backend (zellij / iTerm2 / Terminal.app
  / Warp / Ghostty) from the footer.
- **Global hotkey** — toggle flow-bar from anywhere (default ⌥Space, configurable
  in Settings).
- **Settings & self-update** — a Settings window for the hotkey, launch-at-login,
  and icon style; flow-bar updates itself from GitHub Releases (no re-download).
- **Live activity** — the menubar icon shows a spinner while a `flow do` /
  `flow run` is opening, then a ✓ / ⚠ on completion.
- **Lightweight** — no background polling; refreshes only while open, and
  frees its caches when closed.

## Install

### Homebrew (recommended)

```sh
brew tap pa/flow-bar https://github.com/pa/flow-bar
brew trust pa/flow-bar
brew install --cask flow-bar
```

This **compiles flow-bar on your machine** (about a minute). That's deliberate:
SwiftUI picks its appearance from the macOS SDK a binary was *linked against*,
not the OS it runs on — so a prebuilt binary renders in compatibility mode on
any newer macOS, forever. Building locally means the app looks native on
whatever you're running.

You need Xcode or the Command Line Tools (full Xcode is not required):

```sh
xcode-select --install
```

The build also creates a per-machine self-signed certificate in a dedicated
`flow-bar-signing` keychain and signs the app with it. That keeps flow-bar's
code identity stable, so the macOS permission to control your terminal survives
every upgrade. Nothing is sent anywhere; the key never leaves your Mac.

### Updating

```sh
brew upgrade --cask flow-bar
```

After a **macOS major upgrade**, rebuild so the app links against the new SDK:

```sh
brew reinstall --cask flow-bar
```

flow-bar tells you when this is worth doing — Settings shows which SDK the
running build was compiled against.

### Download (prebuilt)

If you'd rather not install a toolchain, grab `flow-bar.zip` or `flow-bar.dmg`
from the [latest release](https://github.com/pa/flow-bar/releases/latest),
unzip, and move `flow-bar.app` to `/Applications`. These are built in CI, so
they may render in compatibility mode on newer macOS. On first launch:

```sh
xattr -d com.apple.quarantine /Applications/flow-bar.app   # not notarized
```

(The Homebrew build is created locally and is never quarantined, so it doesn't
need this.)

## Build from source

Requires the Swift toolchain (Xcode or Command Line Tools). No Xcode project —
everything is SwiftPM. This is the same path `brew install --cask` takes.

```sh
swift build                 # build all targets
swift run flowbar-tests     # run the unit tests
./build-app.sh --run        # assemble flow-bar.app and launch it
```

## Usage

Click the menubar **w** (or press your global hotkey — default **⌥Space**):

- **In progress** is the home tab — search and press Enter to switch.
- The left rail switches sections: Overview, Needs you, Playbooks, Projects,
  Owners, Tags, Reminders.
- **＋** in the header opens the intake form to create a task (or a new project).
- The footer switches the active **flow root** and **terminal backend**, and the
  ⚙︎ gear opens **Settings** (hotkey, launch-at-login, icon, updates).

Opening a task runs `flow do`, which opens or focuses its session in your chosen
terminal. **zellij** needs no macOS permission; the AppleScript terminals
(**iTerm / Terminal / Warp / Ghostty**) ask once for **Automation** (Terminal
also **Accessibility**). You grant that once — flow-bar keeps a stable code
signature so the grant survives upgrades.

**Right-click a task** to choose how it opens: *Open*, or *Open, skipping
permission prompts*. The second is disabled while the task's tab is still
running, because a session's permission mode is fixed when its process starts —
close the tab and open it again to change it. Holding **⌥** while you click or
press Enter does the same thing.

## Architecture

flow-bar treats the `flow` CLI as its API — it never touches `flow.db`
directly, so it stays schema-proof and respects flow's invariants.

- `FlowBarCore` — pure data/logic: Codable models, the `flow`/JSON bridge,
  text parsers for owners/tags, and the dashboard metrics. Unit-tested.
- `flow-bar` — the SwiftUI app: an AppKit `NSStatusItem` + `NSPopover`
  hosting the menubar UI.

See [CLAUDE.md](CLAUDE.md) for build details and conventions.

## Roadmap

Planned inline task actions — all **safe** (they update flow directly, no
terminal spawn), surfaced as per-row / brief-peek actions:

- [ ] **Done** — mark a task done (`flow done`)
- [ ] **Archive / Unarchive** — from any list and the Archived tab
- [ ] **Priority** — change high / medium / low
- [ ] **Waiting on** — set/clear the `waiting_on` note (feeds the Needs-you inbox)
- [ ] **Due date** — set/clear a due date
- [ ] **Assignee** — set/clear the assignee
- [ ] **Tags** — add/remove tags on an existing task
- [ ] **Edit brief** — edit `brief.md` inline in the peek

Not planned: anything that would reimplement flow's session/spawn logic — flow-bar
delegates all of that to the `flow` CLI.

## Contributing

Issues and PRs welcome. Run `swift run flowbar-tests` before submitting.

## License

[MIT](LICENSE) © Pramodh Ayyappan
