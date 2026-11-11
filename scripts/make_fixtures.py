#!/usr/bin/env python3
"""Writes the JSON fixtures in Sources/NotionBar/Resources.

They are shaped like real Notion API responses (POST /v1/data_sources/{id}/query)
and hold the sample data from the build brief: what the two databases looked like
on Tue Nov 10, 2026. The app uses them for --demo, --selftest and the SwiftUI previews.

    python3 scripts/make_fixtures.py
"""
import json
import os
import uuid

# Made-up ids (the same ones as NotionConfig.sample in the app). Your real databases are set in Settings.
TASKS_DB = "aaaaaaaa-0000-4000-8000-000000000001"
TASKS_DS = "aaaaaaaa-0000-4000-8000-000000000002"
STEPS_DB = "bbbbbbbb-0000-4000-8000-000000000001"
STEPS_DS = "bbbbbbbb-0000-4000-8000-000000000002"
USER = {"object": "user", "id": "b7e4c1a2-5d3f-4e8a-9c61-2f0d8a7b3c44"}
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "Sources", "NotionBar", "Resources")


def pid(name):
    return str(uuid.uuid5(uuid.NAMESPACE_URL, "notionbar-fixture/" + name))


def rich(text):
    if not text:
        return []
    return [{
        "type": "text",
        "text": {"content": text, "link": None},
        "annotations": {"bold": False, "italic": False, "strikethrough": False,
                        "underline": False, "code": False, "color": "default"},
        "plain_text": text,
        "href": None,
    }]


def option(name, color="default"):
    return {"id": pid("option/" + name)[:8], "name": name, "color": color} if name else None


def date(start, end=None):
    return {"start": start, "end": end, "time_zone": None} if start else None


def page(name, ds, db, props, edited, created="2026-11-02T21:15:00.000Z"):
    i = pid(name)
    return {
        "object": "page",
        "id": i,
        "created_time": created,
        "last_edited_time": edited,
        "created_by": USER,
        "last_edited_by": USER,
        "cover": None,
        "icon": None,
        "parent": {"type": "data_source_id", "data_source_id": ds, "database_id": db},
        "archived": False,
        "in_trash": False,
        "properties": props,
        "url": "https://www.notion.so/" + name.replace(" ", "-") + "-" + i.replace("-", ""),
        "public_url": None,
    }


STATUS_COLOR = {"Not started": "default", "In progress": "blue", "Done": "green"}


def task(name, status, due, types, steps=(), priority=None, effort=None, completed=None,
         edited="2026-11-09T22:40:00.000Z", due_end=None):
    return page(name, TASKS_DS, TASKS_DB, {
        "Task name": {"id": "title", "type": "title", "title": rich(name)},
        "Status": {"id": "iquy", "type": "status", "status": option(status, STATUS_COLOR[status])},
        "Due date": {"id": "nV%3Dq", "type": "date", "date": date(due, due_end)},
        "Task type": {"id": "%3FynO", "type": "multi_select",
                      "multi_select": [option(t) for t in types]},
        "Priority": {"id": "D%3F%3Ct", "type": "select", "select": option(priority)},
        "Effort level": {"id": "pn%7BI", "type": "select", "select": option(effort)},
        "Completion date": {"id": "c%5DkR", "type": "date", "date": date(completed)},
        "Steps": {"id": "xGfb", "type": "relation",
                  "relation": [{"id": pid(s)} for s in steps], "has_more": False},
        "Description": {"id": "desc", "type": "rich_text", "rich_text": []},
        "Assignee": {"id": "asgn", "type": "people", "people": []},
        "Attach file": {"id": "file", "type": "files", "files": []},
        "Past due": {"id": "J%3Eqk", "type": "formula",
                     "formula": {"type": "boolean", "boolean": False}},
    }, edited)


def step(name, status, due, stype, parent, edited="2026-11-09T22:40:00.000Z", due_end=None):
    return page(name, STEPS_DS, STEPS_DB, {
        "Name": {"id": "title", "type": "title", "title": rich(name)},
        "Status": {"id": "Yomv", "type": "status", "status": option(status, STATUS_COLOR[status])},
        "Due date": {"id": "due", "type": "date", "date": date(due, due_end)},
        "Step type": {"id": "%7BqEv", "type": "select", "select": option(stype)},
        "Test / Project": {"id": "d%3EW%60", "type": "relation",
                           "relation": [{"id": pid(parent)}] if parent else [], "has_more": False},
        "Description": {"id": "desc", "type": "rich_text", "rich_text": []},
    }, edited)


SCIENCE = "Science muscles and bones test"
ENGLISH = "english analysis"
SCIENCE_STEPS = [
    "Read chapter 6 and take notes",
    "Do the study guide",
    "Make flashcards for bones and muscle names",
    "Do timed practice test on muscles and bones",
    "Final skim of science notes and pack for test",
]

tasks = [
    task("math homework", "Not started", "2026-11-10", ["homework"], priority="Medium", effort="Small"),
    task(SCIENCE, "In progress", "2026-11-11", ["test"], SCIENCE_STEPS, priority="High", effort="Large"),
    task(ENGLISH, "Not started", "2026-11-13", ["project"], ["write all of analysis part"],
         priority="Medium", effort="Medium"),
    # Finished last week: only here to prove the "Status != Done" filter works.
    task("French vocab quiz", "Done", "2026-11-06", ["test"], completed="2026-11-06",
         edited="2026-11-06T20:10:00.000Z"),
]

steps = [
    # Finished this morning: shows up under done/ in the panel.
    step(SCIENCE_STEPS[0], "Done", "2026-11-06T19:00:00.000-05:00", "Prepare", SCIENCE,
         edited="2026-11-10T13:05:00.000Z"),
    step(SCIENCE_STEPS[1], "Not started", "2026-11-07T19:00:00.000-05:00", "Prepare", SCIENCE),
    step(SCIENCE_STEPS[2], "Not started", "2026-11-08T19:00:00.000-05:00", "Prepare", SCIENCE),
    step(SCIENCE_STEPS[3], "Not started", "2026-11-09T18:00:00.000-05:00", "Prac", SCIENCE),
    step(SCIENCE_STEPS[4], "Not started", "2026-11-10T07:30:00.000-05:00", "Do", SCIENCE),
    step("write all of analysis part", "Not started", "2026-11-11", "Do", ENGLISH),
]


def write(filename, results):
    body = {
        "object": "list",
        "results": results,
        "next_cursor": None,
        "has_more": False,
        "type": "page_or_data_source",
        "page_or_data_source": {},
        "request_id": pid("request/" + filename),
    }
    path = os.path.join(OUT, filename)
    with open(path, "w") as fh:
        json.dump(body, fh, indent=2, ensure_ascii=False)
        fh.write("\n")
    print("wrote", os.path.normpath(path), "(%d pages)" % len(results))


if __name__ == "__main__":
    os.makedirs(OUT, exist_ok=True)
    write("tasks-query.json", tasks)
    write("steps-query.json", steps)
