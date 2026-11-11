#!/bin/bash
# Clicks through the real app, on the sample data, and checks what happens.
#
# The app runs in demo mode (a fake Notion in memory, no token, nothing sent anywhere) with its
# panel off screen and unfocused, so this can run while you keep working. Mouse clicks are real
# events sent through the panel's window; links and the Settings window are recorded, not opened.
#
#   scripts/ui_test.sh            run it
#   scripts/ui_test.sh --verbose  also print every step
set -euo pipefail
cd "$(dirname "$0")/.."
swift build 2>&1 | grep -E "error|warning: unre" || true

OUT="$(mktemp -d)"
defaults delete local.notionbar.NotionBar.demo >/dev/null 2>&1 || true

# Sample rows (ids come from scripts/make_fixtures.py)
GUIDE=89ae43c3; FLASH=5ff77fc5; PRACTICE=a4e36e0d; SCIENCE=46c0e479; MATH=a7822c54; SKIM=3901fbc3
TOMORROW="$(date -v+1d +%Y-%m-%d)"

STEPS="
stealth; nolinks; latency:0.05; wait:1.5; open; wait:0.7;

say:opens with the sample data;
expect:panel=open; expect:count=5; expect:overdue=3; expect:today=2; expect:upcoming=1;
expect:tasks=3; expect:finished=1; expect:tasksOpen=false; expect:failure=nil;

say:folders open and close with a click;
click:folder|tasks; wait:0.5; expect:tasksOpen=true; expect:card>650;
click:folder|tasks; wait:0.5; expect:tasksOpen=false; expect:card<650;
click:folder|done; wait:0.5; expect:doneOpen=true;
click:folder|done; wait:0.5; expect:doneOpen=false;

say:a task unfolds, and its commands work;
click:folder|tasks; wait:0.5; click:row|task|$SCIENCE; wait:0.5; expect:expanded=1; expect:card>850;
click:cmd|open; wait:0.3; expect:opened~46c0e479f9735e89;
click:cmd|focus; wait:0.4; expect:focus=true; expect:icon~timer;
click:cmd|stop; wait:0.4; expect:focus=false;
click:row|task|$SCIENCE; wait:0.5; expect:expanded=0;
click:row|task|$SCIENCE; wait:0.5; expect:expanded=1;

say:clicking a row opens it in notion;
click:row|overdue|$GUIDE; wait:0.3; expect:opened~89ae43c3dc195ea6;

say:clicking the checkbox marks it done, and undo brings it back;
click:check|overdue|$GUIDE; wait:1.2; expect:count=4; expect:overdue=2; expect:finished=2; expect:toast~done;
click:cmd|undo; wait:1.2; expect:count=5; expect:finished=1;

say:holding option makes a click on the row mark it done;
option:on; click:row|overdue|$FLASH; wait:1.2; option:off; expect:count=4;
undo; wait:1.2; expect:count=5;

say:mark-done on a task finishes its steps too;
click:cmd|mark-done; wait:1.4; expect:tasks=2; expect:count=1;
undo; wait:1.8; expect:tasks=3; expect:count=5;

say:footer and header buttons;
click:cmd|open task-tracker; wait:0.2; expect:opened~aaaaaaaa00004000;
click:cmd|open steps; wait:0.2; expect:opened~bbbbbbbb00004000;
click:cmd|refresh; wait:0.6; expect:failure=nil; expect:loading=false;
click:icon|gearshape; wait:0.2; expect:settingsRequests=1;
click:icon|arrow.clockwise; wait:0.6; expect:loading=false;

say:keyboard;
key:125; expect:selection~overdue|$GUIDE; key:125; expect:selection~overdue|$FLASH; key:126; expect:selection~overdue|$GUIDE;
key:36; wait:0.2; expect:opened~89ae43c3dc195ea6;
key:36+cmd; wait:1.2; expect:count=4; undo; wait:1.2; expect:count=5;

say:filtering;
query:flash; wait:0.4; expect:rows=4;
key:36; wait:0.2; expect:opened~5ff77fc56935541f;
key:53; expect:query=; expect:rows>8;

say:adding a task from the prompt;
query:+ test thing tomorrow #hw; wait:0.3; key:36; wait:1.2; expect:tasks=4; expect:toast~created; expect:query=;

say:a failed write puts the row back;
fail:500; click:check|overdue|$PRACTICE; wait:0.8; fail:off; expect:count=5; expect:toast~couldn't mark done;
wait:2.2; expect:failure=nil;

say:error screens;
fail:401; refresh; wait:0.3; expect:failure~unauthorized;
click:cmd|open settings; wait:0.2; expect:settingsRequests=2;
fail:off; click:cmd|retry; wait:0.6; expect:failure=nil; expect:count=5;
fail:offline; refresh; wait:0.3; expect:offline=true; expect:count=5;
fail:off; click:cmd|retry; wait:0.6; expect:offline=false;

say:a click outside the card asks the panel to close;
expect:outsideClicks=0; clickat:-12,-12; wait:0.2; expect:outsideClicks=1;

say:the week strip filters to one day;
click:day|$TOMORROW; wait:0.4; expect:dayFilter=$TOMORROW; expect:overdue=3; expect:rows<10;
key:53; wait:0.3; expect:dayFilter=nil; expect:panel=open;
click:day|$TOMORROW; wait:0.3; click:cmd|clear; wait:0.3; expect:dayFilter=nil;

say:pinning keeps the panel open when you click elsewhere;
click:icon|pin; wait:0.3; expect:pinned=true; autoclose; expect:pinIgnored=1; expect:panel=open;
click:row|overdue|$GUIDE; wait:0.3; expect:panel=open;
click:icon|pin.fill; wait:0.3; expect:pinned=false;

say:add-step adds a step to the task;
click:cmd|add-step; wait:0.3; expect:addingStep=true; expect:query~+;
query:+ make cue cards #prac; wait:0.3; key:36; wait:1.2;
expect:toast~step added; expect:steps=6; expect:addingStep=false; expect:query=;
click:cmd|add-step; wait:0.2; key:53; wait:0.2; expect:addingStep=false;

say:ticking off the last thing due sets off the celebration;
expect:celebration=0;
click:cmd|mark-done; wait:1.6; expect:count=1;
click:check|today|$MATH; wait:0.75; expect:count=0; expect:celebration=1; shot:allclear; wait:1.2;

quit
"

SCRIPT="$(echo "$STEPS" | tr '\n' ' ')"
set +e
.build/debug/NotionBar --demo --debug "$SCRIPT" --debug-dir "$OUT" 2>&1 | grep -v "^$"
CODE=$?
set -e
if [ "${1:-}" = "--verbose" ]; then
    cat "$OUT/debug.log"
else
    grep -E "^(—|FAIL)" "$OUT/debug.log" || true
fi
defaults delete local.notionbar.NotionBar.demo >/dev/null 2>&1 || true
exit $CODE
