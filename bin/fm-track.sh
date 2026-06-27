#!/usr/bin/env bash
# fm-track — Session-level todo list that firstmate MUST interact with.
# This is the session contract: firstmate calls start/done/current to
# track what it's working on. The pre-spawn gate checks this before
# allowing any crewmate dispatch.
#
# Usage:
#   fm-track list                    — show all items
#   fm-track start <item>            — mark item as in-progress (only one active)
#   fm-track done <item>             — mark item complete
#   fm-track current                 — show current active item
#   fm-track add <description>       — add a new item
#   fm-track reset                   — clear all items (new session)
#
# State: state/session-todos.json (atomically written)
# Source: derived from state/session-agenda.md

set -eu

FM_ROOT="${CLAUDE_PROJECT_DIR:-}"
if [ -z "$FM_ROOT" ] || [ ! -d "$FM_ROOT/state" ]; then
  FM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd 2>/dev/null)" || exit 1
fi

cd "$FM_ROOT" 2>/dev/null || exit 1

TODOS="$FM_ROOT/state/session-todos.json"
mkdir -p "$(dirname "$TODOS")"

# Initialize from session-agenda.md if todos don't exist
if [ ! -f "$TODOS" ] && [ -f "$FM_ROOT/state/session-agenda.md" ]; then
  # Extract todo items from agenda
  python3 -c "
import json, re, sys
agenda = open('$FM_ROOT/state/session-agenda.md').read()
items = []
# Find all - [ ] items
for line in agenda.split('\n'):
    m = re.match(r'^- \[ \] (.+)', line)
    if m:
        items.append({'description': m.group(1).strip(), 'status': 'pending', 'started_at': None})
json.dump({'items': items, 'active': None}, sys.stdout, indent=2)
" > "$TODOS" 2>/dev/null || true
fi

# Ensure valid JSON exists
if [ ! -f "$TODOS" ]; then
  echo '{"items":[],"active":null}' > "$TODOS"
fi

cmd="${1:-list}"
case "$cmd" in
  list)
    python3 -c "
import json, sys
d = json.load(open('$TODOS'))
active = d.get('active')
for i, item in enumerate(d.get('items', [])):
    marker = '> ' if item.get('description') == active else '  '
    status = item.get('status', 'pending')
    if status == 'done':
        marker = '✓ '
    print(f\"{marker}{i+1}. [{status}] {item['description']}\")
print()
if active:
    print(f'Active: {active}')
else:
    print('No active item — set one with: fm-track start <number>')
"
    ;;

  current)
    python3 -c "
import json, sys
d = json.load(open('$TODOS'))
active = d.get('active')
if active:
    print(active)
    sys.exit(0)
else:
    sys.exit(1)
"
    ;;

  start)
    ITEM="${2:-}"
    if [ -z "$ITEM" ]; then
      echo "usage: fm-track start <item-description-or-number>"
      exit 1
    fi
    TODO_ITEM="$ITEM" python3 -c "
import json, os, sys
d = json.load(open('$TODOS'))
items = d.get('items', [])
item = os.environ['TODO_ITEM']

if item.isdigit():
    idx = int(item) - 1
    if idx < 0 or idx >= len(items):
        print(f'error: no item #{item}')
        sys.exit(1)
    desc = items[idx]['description']
else:
    desc = item
    found = False
    for it in items:
        if it['description'] == desc:
            found = True
            break
    if not found:
        items.append({'description': desc, 'status': 'pending', 'started_at': None})

d['active'] = desc
for it in items:
    if it['description'] == desc:
        it['status'] = 'in_progress'
        it['started_at'] = __import__('datetime').datetime.now().isoformat()

json.dump(d, sys.stdout, indent=2)
" > "$TODOS.tmp" && mv "$TODOS.tmp" "$TODOS"
    echo "started: $ITEM"
    ;;

  done)
    ITEM="${2:-}"
    if [ -z "$ITEM" ]; then
      echo "usage: fm-track done <item-description-or-number>"
      exit 1
    fi
    TODO_ITEM="$ITEM" python3 -c "
import json, os, sys, datetime
d = json.load(open('$TODOS'))
items = d.get('items', [])
item = os.environ['TODO_ITEM']

if item.isdigit():
    idx = int(item) - 1
    if idx < 0 or idx >= len(items):
        print(f'error: no item #{item}')
        sys.exit(1)
    desc = items[idx]['description']
else:
    desc = item

for it in items:
    if it['description'] == desc:
        it['status'] = 'done'
        it['completed_at'] = datetime.datetime.now().isoformat()
        if d.get('active') == desc:
            d['active'] = None

json.dump(d, sys.stdout, indent=2)
" > "$TODOS.tmp" && mv "$TODOS.tmp" "$TODOS"
    echo "done: $ITEM"
    ;;

  add)
    DESC="${2:-}"
    if [ -z "$DESC" ]; then
      echo "usage: fm-track add <description>"
      exit 1
    fi
    TODO_DESC="$DESC" python3 -c "
import json, os, sys
d = json.load(open('$TODOS'))
desc = os.environ['TODO_DESC']
d['items'].append({'description': desc, 'status': 'pending', 'started_at': None})
json.dump(d, sys.stdout, indent=2)
" > "$TODOS.tmp" && mv "$TODOS.tmp" "$TODOS"
    echo "added: $DESC"
    ;;

  reset)
    # Archive old todos first
    if [ -f "$TODOS" ]; then
      cp "$TODOS" "$FM_ROOT/state/session-todos.$(date +%s).json" 2>/dev/null || true
    fi
    echo '{"items":[],"active":null}' > "$TODOS"
    echo "todos reset"
    ;;

  check-gate)
    # Used by pre-spawn gate: exits 0 if active todo exists, 1 otherwise
    python3 -c "
import json, sys
d = json.load(open('$TODOS'))
active = d.get('active')
if active:
    print(f'TODO active: {active}')
    sys.exit(0)
else:
    print('NO ACTIVE TODO — set one with: fm-track start <item>')
    sys.exit(1)
"
    ;;

  *)
    echo "usage: fm-track <list|start|done|current|add|reset>"
    exit 1
    ;;
esac
