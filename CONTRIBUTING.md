# Contributing to flow-bar

Thanks for looking. This is a small, opinionated macOS menubar app for
[flow](https://github.com/Facets-cloud/flow); the notes below are the things
that are easy to get wrong here and hard to notice afterwards.

## Build and test

```sh
swift build              # all targets
swift run flowbar-tests  # the unit tests (exits non-zero on failure)
swift run flowbar-smoke  # decodes real `flow` output — a data-path check
./build-app.sh --run     # assemble flow-bar.app and launch it
```

There is no Xcode project, and you don't need Xcode. Command Line Tools
(`xcode-select --install`) is enough, which is deliberate — see below.

## Three constraints that shape everything

**1. The Homebrew cask compiles on the user's machine. Never add a bottle or a
prebuilt binary to that path.** SwiftUI takes its appearance from the macOS SDK
a binary was *linked against*, not the OS it runs on, so a CI-built binary
renders in compatibility mode on every newer macOS, forever. Building locally is
the whole point. `build-app.sh` is the single build entry point for CI, brew and
local development — put logic there, not in the cask.

**2. Tests are a plain executable, not XCTest.** XCTest needs Xcode, and most
people installing from brew have only the Command Line Tools; a test suite they
cannot run is a test suite that rots. The harness is `Sources/flowbar-tests`
(see `T` in `Harness.swift`). CI has a `command-line-tools` job that builds with
Xcode switched off, so this stays true.

**3. Logic that can be tested belongs in `FlowBarCore`.** It has no AppKit, no
SwiftUI and runs no `flow` commands — it takes decoded models and returns
values. Ranking, parsing, layout arithmetic and list ordering all live there, so
their behaviour is a test contract rather than something you squint at in a
running app. If you find yourself about to verify something by launching the
app, check whether the rule could move into the core first.

## Pull requests

- Branch, open a PR, let the checks run. `main` requires them.
- Add a `CHANGELOG.md` entry for anything a user would notice. The top section
  becomes the GitHub release body *and* ships inside the app, so write it for
  the person reading it in the palette, not for a diff.
- Comments should explain **why**, especially when the code looks odd. Most of
  the surprising code in this repo is surprising because the obvious version was
  tried and broke something; say what, so the next person doesn't undo it.
- Match the surrounding style. There is no formatter.

## The flow CLI is the API

flow-bar never reads `~/.flow/flow.db`. Reads go through
`flow list ... --format json`, actions through real subcommands. That keeps the
app schema-proof and respects flow's own invariants. If you need data flow does
not expose, the fix belongs upstream in flow, not in a SQLite query here.
