# Contributing to NotionBar

Thanks for taking a look. Bug reports, ideas and pull requests are all welcome.

## Getting set up

You need macOS 14 or later and the Xcode Command Line Tools (`xcode-select --install`). Xcode is optional.

```bash
git clone https://github.com/cyrus514/NotionBar.git
cd NotionBar
./build.sh --demo
```

`--demo` runs the app on the bundled sample data with a fake Notion in memory, so you can try
anything, including marking things done, without a token or a Notion account.

## Before you open a pull request

Run all three. None of them talks to Notion or needs a token.

```bash
swift build
.build/debug/NotionBar --selftest      # date rules, Notion requests, store, Keychain import
scripts/ui_test.sh                     # real mouse clicks through the app, off screen
python3 scripts/compare_with_plugin.py # sections and order still match the reference
```

If you changed how something looks, draw it and check it in both appearances:

```bash
.build/debug/NotionBar --snapshot out.png --state tasks --dark
.build/debug/NotionBar --snapshot out.png --state tasks
```

`--state` accepts: `hero default tasks option filter add addstep day pinned done toast focus empty
error notfound notoken offline loading menubar settings`. Several at once (`--state filter,add,done`)
draws them side by side.

## How the code is laid out

| Folder | What lives there |
|---|---|
| `App/` | entry point, app delegate, the menu bar item, the panel window |
| `Model/` | dates (`Day`), `Item`, `Board` (which row goes in which section), `TaskStore` (state and writes) |
| `Notion/` | the API client, response models, and `FakeNotion` |
| `Services/` | settings, Keychain, quick add, hot key, notifications, focus timer, log |
| `UI/` | theme, panel, rows, status icon, settings window |
| `Dev/` | self-test, snapshot renderer, debug driver, app icon |

Two files do most of the thinking: `Model/Board.swift` decides what the panel shows, and
`Model/TaskStore.swift` decides when to fetch and how a change is sent and rolled back.

## Conventions

- **No dependencies.** Foundation, AppKit and SwiftUI only.
- **`@ViewState`, not `@State`.** On the macOS 27 SDK `@State` needs a compiler plugin that only ships
  with Xcode. `ViewState` is an alias for the same property wrapper and builds everywhere.
- **Colours and fonts come from `UI/Theme.swift`.** Everything is Menlo; text colours have a light and a dark value.
- **Animations go through `animate(_:_:_:)` or check `\.motion`,** so the Animations setting and Reduce Motion both switch them off.
- **Anything clickable gets `.clickTarget("name")`.** That is how `scripts/ui_test.sh` finds it. Add a step to the script for new buttons.
- **Changes to Notion are optimistic.** Update the list first, send the request, and put things back with a toast if it fails. `TaskStore.edit` does this for you.
- **New behaviour that changes what users already see goes behind a setting** that is off by default. With every optional setting off, the sections must keep matching `scripts/reference/golden.json`.
- **Comments say why,** not what.

## Never commit

- a Notion token,
- real database or page ids (the samples use made-up ones: see `NotionConfig.sample`),
- `~/Library/Logs/NotionBar.log` without reading it first. It has no token or task names, but it does contain page ids.

## Reporting a bug

Open an issue with what you did, what you expected and what happened. The last few lines of
Settings → **Show log** usually explain a problem with Notion straight away.
