#!/usr/bin/env python3
"""Checks that NotionBar groups rows exactly like the SwiftBar plugin did.

It feeds the same Notion pages to both, at the same pretend time, and diffs the result:
which rows are in which section, in what order, how they're coloured (overdue / late)
and what the detail line says.

    swift build
    python3 scripts/compare_with_plugin.py path/to/notion-tasks.py   # against the plugin itself
    python3 scripts/compare_with_plugin.py                           # against the saved reference

With no plugin file, the app is compared with scripts/reference/golden.json: the output of a
build that was checked against the plugin line for line. (`--write-golden <binary>` remakes it.)

Nothing here talks to Notion: the plugin's own functions are called directly.
"""
import datetime as dt
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
BINARY = os.path.join(ROOT, ".build", "debug", "NotionBar")
ZONE = "America/Toronto"

sys.path.insert(0, HERE)
import make_fixtures as fx  # noqa: E402


def load_plugin(path):
    spec = importlib.util.spec_from_file_location("notion_tasks_plugin", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


# ------------------------------------------------------------ what Notion would return ---
def start_key(page):
    date = page["properties"]["Due date"]["date"]
    if not date or not date.get("start"):
        return None
    value = date["start"]
    if "T" not in value:
        return dt.datetime.fromisoformat(value).astimezone().timestamp()
    return dt.datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()


def as_query(pages):
    """Status != Done, sorted by Due date ascending with empty dates last (stable)."""
    live = [p for p in pages if p["properties"]["Status"]["status"]["name"] != "Done"]
    dated = sorted([p for p in live if start_key(p) is not None], key=start_key)
    return dated + [p for p in live if start_key(p) is None]


# ------------------------------------------------------------------- plugin → plain text ---
def plugin_text(plugin, tasks, steps, now):
    class Frozen(dt.datetime):
        @classmethod
        def now(cls, tz=None):
            return cls(now.year, now.month, now.day, now.hour, now.minute)

    plugin.datetime = Frozen
    today = now.date()
    built_tasks, built_steps = plugin.build(as_query(tasks), as_query(steps), today)
    out = plugin.render(built_tasks, built_steps, today)

    states = {plugin.RED: "overdue", plugin.ORANGE: "late", plugin.DIM: "normal"}
    lines = []
    title = None
    task_line, task_steps = None, []
    for raw in out[1:]:
        text, _, params = raw.partition(" | ")
        depth = 0
        while text.startswith("--"):
            text, depth = text[2:], depth + 1
        if not text.strip("-") or "alternate=true" in params or text.startswith("$ "):
            continue
        if text.startswith("// "):
            if depth == 0 and not text.startswith("// hold"):
                lines.append("[%s]" % text[3:])
            continue
        if text.startswith("tasks/ ("):
            lines.append("[%s]" % text)
            continue
        if text.startswith("✓ nothing due today"):
            lines.append("nothing due today")
            continue
        if text.startswith("✓ everything's done"):
            lines.append("everything's done")
            continue
        if text.startswith("   … "):
            lines.append("more=%s" % text.split()[1])
            continue
        if text.startswith("   └ "):
            colour = params.split("color=")[1].split()[0]
            detail = text[5:]
            if depth == 1:      # a task under tasks/: its detail comes after its steps
                lines.append("%s | %s | %s" % (states[colour], task_line, detail))
                lines.extend(task_steps)
                task_line, task_steps = None, []
            elif depth == 2:    # a step under a task
                task_steps.append("  %s | %s | %s" % (states[colour], title, detail))
            else:
                lines.append("%s | %s | %s" % (states[colour], title, detail))
            continue
        if depth == 1:
            task_line = text
        else:
            title = text

    count = out[0].split("|")[0].strip() or "0"
    overdue = "exclamationmark.circle" in out[0]
    return ["count=%s overdue=%s" % (count, "true" if overdue else "false")] + lines


# --------------------------------------------------------------------- app → plain text ---
def app_text(tasks, steps, now, binary=None):
    with tempfile.TemporaryDirectory() as folder:
        for name, pages in (("tasks-query", tasks), ("steps-query", steps)):
            with open(os.path.join(folder, name + ".json"), "w") as fh:
                json.dump({"object": "list", "results": pages, "has_more": False, "next_cursor": None}, fh)
        stamp = now.astimezone().isoformat(timespec="milliseconds")
        result = subprocess.run([binary or BINARY, "--dump", "--fixtures", folder, "--now", stamp],
                                capture_output=True, text=True, env=dict(os.environ, TZ=ZONE))
        if result.returncode != 0:
            sys.exit("NotionBar --dump failed:\n" + result.stdout + result.stderr)
        return result.stdout.strip().split("\n")


# ----------------------------------------------------------------------------- the data ---
def edge_cases():
    """Awkward rows: ranges, UTC times, no dates, missing parents, ties, a long upcoming list."""
    essay, lab, quiz, done = "history essay", "lab report", "spanish quiz", "old finished thing"
    tasks = [
        fx.task(essay, "Not started", "2026-11-09", ["project"], due_end="2026-11-12"),
        fx.task(lab, "In progress", "2026-11-08", ["project", "homework"]),
        fx.task("read novel", "Not started", None, ["personal"]),
        fx.task(quiz, "Not started", "2026-11-10T15:30:00.000-05:00", ["test"]),
        fx.task("art portfolio", "Not started", "2026-12-20", []),
        fx.task("ended range", "Not started", "2026-11-05", ["homework"], due_end="2026-11-09"),
        fx.task("utc deadline", "In progress", "2026-11-11T02:00:00.000Z", ["test"]),
        fx.task("timed range", "Not started", "2026-11-09T09:00:00.000-05:00", ["project"],
                due_end="2026-11-10T17:00:00.000-05:00"),
        fx.task(done, "Done", "2026-11-01", ["test"]),
    ]
    steps = [
        fx.step("outline", "Not started", "2026-11-10T09:00:00.000-05:00", "Prepare", essay),
        fx.step("draft", "Not started", "2026-11-10", "Do", essay),
        fx.step("revise", "Not started", None, "Prac", essay),
        fx.step("cite sources", "Not started", "2026-11-13T16:00:00.000-05:00", "Do", essay),
        fx.step("collect data", "Not started", "2026-11-09T18:00:00.000-05:00", "Prepare", lab),
        fx.step("write up", "In progress", "2026-11-10T20:00:00.000-05:00", "Do", lab),
        fx.step("orphan step", "Not started", "2026-11-12", "Do", done),
        fx.step("loose step", "Not started", "2026-11-17", "Prac", None),
        fx.step("far step", "Not started", "2026-11-18", "Do", None),
        fx.step("no type step", "Not started", "2026-11-12T10:00:00.000-05:00", None, quiz),
        fx.step("tie a", "Not started", "2026-11-12T10:00:00.000-05:00", "Do", quiz),
        fx.step("tie b", "Not started", "2026-11-12T10:00:00.000-05:00", "Do", quiz),
        fx.step("finished step", "Done", "2026-11-09", "Do", essay),
    ]
    steps += [fx.step("drill %d" % i, "Not started", "2026-11-11T08:%02d:00.000-05:00" % i, "Prac", quiz)
              for i in range(1, 15)]
    return tasks, steps


GOLDEN = os.path.join(HERE, "reference", "golden.json")


def all_cases():
    return [
        ("sample data", (fx.tasks, fx.steps), ["2026-11-10 09:15", "2026-11-10 07:00", "2026-11-11 08:00"]),
        ("edge cases", edge_cases(), ["2026-11-10 14:00", "2026-11-10 08:00", "2026-11-10 23:30",
                                      "2026-11-11 00:10", "2026-11-14 12:00", "2026-11-03 10:00"]),
        ("nothing at all", ([], []), ["2026-11-10 09:15"]),
    ]


def main():
    os.environ["TZ"] = ZONE
    time.tzset()
    args = sys.argv[1:]

    if args[:1] == ["--write-golden"]:
        binary = args[1] if len(args) > 1 else BINARY
        golden = {}
        for name, (tasks, steps), moments in all_cases():
            for moment in moments:
                now = dt.datetime.strptime(moment, "%Y-%m-%d %H:%M")
                golden["%s @ %s" % (name, moment)] = app_text(tasks, steps, now, binary)
        os.makedirs(os.path.dirname(GOLDEN), exist_ok=True)
        with open(GOLDEN, "w") as fh:
            json.dump(golden, fh, indent=1, ensure_ascii=False)
        print("wrote %s (%d cases) from %s" % (GOLDEN, len(golden), binary))
        return

    if not os.path.exists(BINARY):
        sys.exit("build the app first: swift build")
    plugin = load_plugin(args[0]) if args else None
    golden = None
    if plugin is None:
        if not os.path.exists(GOLDEN):
            sys.exit(__doc__)
        golden = json.load(open(GOLDEN))
        print("no plugin file given: comparing with the saved reference (scripts/reference/golden.json)\n")

    failures = 0
    for name, (tasks, steps), moments in all_cases():
        for moment in moments:
            now = dt.datetime.strptime(moment, "%Y-%m-%d %H:%M")
            want = plugin_text(plugin, tasks, steps, now) if plugin else golden["%s @ %s" % (name, moment)]
            got = app_text(tasks, steps, now)
            if want == got:
                print("same   %-15s at %s  (%d lines)" % (name, moment, len(want)))
                continue
            failures += 1
            print("DIFFER %-15s at %s" % (name, moment))
            for i in range(max(len(want), len(got))):
                a = want[i] if i < len(want) else "<nothing>"
                b = got[i] if i < len(got) else "<nothing>"
                if a != b:
                    print("   %s: %s\n   app:    %s" % ("plugin" if plugin else "saved ", a, b))
    print("\n%s" % ("all identical" if failures == 0 else "%d case(s) differ" % failures))
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
