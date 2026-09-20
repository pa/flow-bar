# Security policy

## Reporting a vulnerability

Please report privately through GitHub's
[security advisories](https://github.com/pa/flow-bar/security/advisories/new)
rather than opening a public issue. I'll acknowledge within a few days.

## What is worth reporting

flow-bar is a local menubar app with no server, no account and no telemetry, but
it does three things that are worth scrutiny:

- **It spawns terminal sessions.** Selecting a task shells out to
  `flow do <slug>`, which opens a terminal and can run a coding agent. Anything
  that lets untrusted input reach that command line is a real finding.
- **It holds a macOS Automation (TCC) grant.** flow's terminal backends are
  driven by AppleScript, and flow-bar owns that grant rather than disclaiming it.
  Anything that lets another process borrow it matters.
- **It edits `~/.claude/settings.json`.** With session alerts enabled it splices
  a `Notification` hook into a file the user owns and other tools also write to.
  Bugs that corrupt or over-write that file are in scope.

Findings in the [flow CLI](https://github.com/Facets-cloud/flow) itself should
go to that project.
