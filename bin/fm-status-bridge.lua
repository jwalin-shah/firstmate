-- fm-status-bridge.lua
-- Watches all mintmux pane output for crewmate status lines and routes them
-- to fm-tasks to keep tasks.db authoritative.
--
-- Load with: mintmux --script /path/to/fm-status-bridge.lua
-- Env: FM_ROOT must be set in the server's environment, or edit fm_root below.
--
-- Crewmate status protocol (from brief.md Rules #4):
--   echo "<state>: <note>" | tee -a $FM_ROOT/state/<id>.status
-- States: working | needs-decision | blocked | done | failed
--
-- tee copies the status line to both the file and terminal stdout.
-- This bridge watches pane stdout for those bare "state: note" lines.
--
-- Pane → task mapping lives in $FM_ROOT/state/.pane-map (tab-separated):
--   <pane_id>\t<task_id>
-- fm-spawn.sh appends to this file after each successful spawn.

local fm_root = os.getenv("FM_ROOT") or (os.getenv("HOME") .. "/projects/firstmate")
local pane_map_path = fm_root .. "/state/.pane-map"

-- pane_to_task: pane_id (number) -> task_id (string)
local pane_to_task = {}

-- reload_map reads .pane-map and rebuilds pane_to_task.
local function reload_map()
  local out, code = mm.run("cat " .. pane_map_path .. " 2>/dev/null || true", 2000)
  if code ~= 0 or out == "" then return end
  local new_map = {}
  for line in out:gmatch("[^\n]+") do
    local pane_id, task_id = line:match("^(%d+)\t(.+)$")
    if pane_id and task_id then
      new_map[tonumber(pane_id)] = task_id
    end
  end
  pane_to_task = new_map
end

reload_map()

-- valid_states: the states crewmates may report (bare "state: note" line in pane output).
-- Crewmates run: echo "done: summary" | tee -a $FM_ROOT/state/<id>.status
-- tee copies stdout to both the file and the terminal, so "done: summary" appears
-- as a bare pane output line that this bridge can pattern-match.
local valid_states = {
  working = true,
  ["needs-decision"] = true,
  blocked = true,
  done = true,
  failed = true,
}

-- fm_tasks_update calls fm-tasks to set status. We map our states to fm-tasks subcommands.
local function fm_tasks_update(task_id, state, note)
  local cmd
  if state == "done" then
    cmd = "fm-tasks done " .. task_id
  elseif state == "failed" then
    cmd = "fm-tasks fail " .. task_id
  else
    -- For working/blocked/needs-decision: fm-tasks has no direct subcommand yet;
    -- append to status file directly as a fallback until fm-tasks set-status lands.
    cmd = "echo " .. state .. ": " .. note:gsub("'", "\\'") ..
          " >> " .. fm_root .. "/state/" .. task_id .. ".status"
  end
  mm.run(cmd, 3000)
end

-- map_reload_counter: reload map every ~30 events to pick up new spawns.
local event_count = 0
local MAP_RELOAD_INTERVAL = 30

-- on_event callback: receives every pane event.
mm.on_event(function(ev)
  if ev.kind ~= "out" then return end

  event_count = event_count + 1
  if event_count % MAP_RELOAD_INTERVAL == 0 then
    reload_map()
    event_count = 0
  end

  local task_id = pane_to_task[ev.pane]
  if not task_id then return end  -- pane not a tracked crewmate

  local data = ev.data or ""

  -- Match the bare status line: "done: built auth module"
  -- tee copies stdout to the terminal, so "done: ..." arrives in pane output.
  for line in data:gmatch("[^\r\n]+") do
    local state, note = line:match("^([%w%-]+):%s*(.*)$")
    if state and valid_states[state] then
      fm_tasks_update(task_id, state, note or "")
      -- On terminal states, remove from map so we don't reprocess.
      if state == "done" or state == "failed" then
        pane_to_task[ev.pane] = nil
      end
      break  -- one status line per event chunk is enough
    end
  end
end)
