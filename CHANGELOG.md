# Changelog

## 1.0.0 · 2026-11-11

First public release.

### The basics
- Menu bar icon with a count of overdue and due-today items, four states, and a tooltip.
- Panel with `// overdue`, `// today`, `// upcoming`, `tasks/` (tasks unfold into steps) and `done/`.
- Mark done by checkbox, ⌥-click or ⌘⏎. Finishing a task finishes its steps and sets its completion date.
- Undo, reopen, move a due date, set In progress, copy link.
- Fetches on a timer, when the panel opens, on wake and unlock, at midnight and when the network returns.
- Token in the Keychain, imported from `~/.notion-menubar-token` if present. Database ids in Settings.

### Beyond the original SwiftBar plugin
- Week strip with per-day counts and a day filter.
- Time badges (`in 45m`, `2h late`, `3d late`) and `!high` for high priority.
- Type to filter; `+ …` to add a task; `$ add-step` to add a step to a task.
- Progress bar for today, and step progress on each task.
- Pin the panel open; focus countdown in the menu bar.
- Optional notifications, global shortcut, next-due countdown, and scheduling tasks by completion date.
- Offline cache with a greyed-out list; clear screens for a bad token, a missing connection and a locked Keychain.
- Diagnostics log.

### Look and motion
- Menlo throughout, light and dark, three text sizes.
- Icon animations: hourglass while fetching, rolling count, overdue pulse, done pop.
- Panel animations: staggered open, diff-style sweep on a ticked row, sync line, a small celebration when the last due item is finished.
- Everything honours the Animations setting and Reduce Motion.

### For developers
- Demo mode on sample data (`./build.sh --demo`).
- `--selftest`, a click-through UI test, a section-parity check, and a snapshot renderer.
