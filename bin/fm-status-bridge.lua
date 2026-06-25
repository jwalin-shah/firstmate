-- fm-status-bridge.lua
-- Watches all mintmux pane output for crewmate status lines and routes them
-- to fm-tasks to keep tasks.db authoritative.
--
-- Load with: mintmux --script /path/to/fm-status-bridge.lua
-- Env: FM_ROOT must be set in the server's environment.
--
-- Crewmate status protocol (from brief.md Rules #4):
--   echo "<state>:<task-id>: <note>" | tee -a $FM_ROOT/state/<id>.status
-- States: working | needs-decision | blocked | done | failed
--
-- The task id is embedded in the line itself, so no external pane→task
-- mapping is needed. tee writes to the status file AND terminal stdout;
-- this bridge watches stdout for those "<state>:<id>: <note>" lines.
--
-- Mintmux uses gopher-lua (Lua 5.1 subset) which does not expose os/io.
-- Environment is read via mm.run.

local function shell(cmd)
  local out, _ = mm.run(cmd, 2000)
  return (out or ""):gsub("%s+$", "")
end

local fm_root = shell("printf %s \"$FM_ROOT\"")
if fm_root == "" then
  fm_root = shell("printf %s \"$HOME\"") .. "/projects/firstmate"
end

-- valid_states: the states crewmates may report.
local valid_states = {
  working = true,
  ["needs-decision"] = true,
  blocked = true,
  done = true,
  failed = true,
}

-- terminated_tasks: prevent reprocess after done/failed.
local terminated = {}

-- fm_tasks_update: call fm-tasks or fall back to status-file append.
local function fm_tasks_update(task_id, state, note)
  local cmd
  if state == "done" then
    cmd = "fm-tasks done " .. task_id
  elseif state == "failed" then
    cmd = "fm-tasks fail " .. task_id
  else
    -- fm-tasks set-status not yet landed; append to status file.
    cmd = "echo " .. state .. ": " .. note:gsub("'", "'\\''") ..
          " >> " .. fm_root .. "/state/" .. task_id .. ".status"
  end
  mm.run(cmd, 3000)
end

-- on_event: receives every pane event. Match "state:task-id: note" lines
-- from pane output. No pane-map needed — the task id is on the line.
mm.on_event(function(ev)
  if ev.kind ~= "out" then return end

  local data = ev.data or ""

  for line in data:gmatch("[^\r\n]+") do
    -- Format: "done:fix-login-k3: built auth module"
    -- Capture state, task-id, and optional note.
    local state, task_id, note = line:match("^([%w%-]+):([%w%-]+):%s*(.*)$")
    if state and valid_states[state] then
      if state == "done" or state == "failed" then
        if terminated[task_id] then break end
        terminated[task_id] = true
      end
      fm_tasks_update(task_id, state, note or "")
      break  -- one status line per event chunk
    end
  end
end)