# Changelog

All notable changes to flow-bar, newest first. The top section is published as
the GitHub release notes when a version is tagged.

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
