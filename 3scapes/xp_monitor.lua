local M = { name = "xp_monitor", version = "1.0", priority = 45 }
M.window_launcher = { label = "XP Monitor", compact_label = "XP", order = 20 }
local command = require("command")
local state = { total = 0, spend = 0, gain30 = 0, baseline = 0, reset_at = 0, max = false, mode = "stats", kills = {} }
local trigger_ids, command_id, kill_listener, popup_open = {}, nil, nil, false
local pending_kill
local function comma(n) local s=tostring(math.floor(n or 0)); repeat s,k=s:gsub("^(%-?%d+)(%d%d%d)", "%1,%2") until k==0; return s end
local function elapsed() local n=math.max(0, os.time()-(state.reset_at or 0)); return string.format("%02d:%02d:%02d", math.floor(n/3600), math.floor(n/60)%60, n%60) end
local function save() store.set(state); store.save() end
local function lines(w)
  local out = { "\27[96m[Stats] [Kills] [Close]\27[0m" }
  if state.mode == "kills" then
    local total=0; for _, k in ipairs(state.kills) do total=total+k.xp end
    out[#out+1]=string.format("\27[96m%d kills\27[0m  Total \27[92m%s\27[0m  Avg \27[92m%s\27[0m", #state.kills, comma(total), comma(#state.kills>0 and total/#state.kills or 0))
    for _, k in ipairs(state.kills) do out[#out+1]=string.format("\27[93m%-24s\27[0m +\27[92m%s XP\27[0m", k.enemy:sub(1,24), comma(k.xp)) end
    if #state.kills==0 then out[#out+1]="\27[2mNo kills recorded yet\27[0m" end
  else
    out[#out+1]="\27[96mTotal XP:    \27[0m"..comma(state.total)
    out[#out+1]="\27[96mXP to Spend: \27[0m"..comma(state.spend)
    out[#out+1]="\27[96m30min Gain:  \27[92m"..comma(state.gain30).."\27[0m"
    out[#out+1]="\27[96mSince Reset: \27[92m"..comma(state.total-state.baseline).."\27[0m ("..elapsed()..")"
    out[#out+1]=state.max and "\27[93mMaximum level\27[0m" or ""
  end
  out[#out+1]=""; out[#out+1]="\27[2m/xp [kills|stats|reset|refresh]\27[0m"; return out
end
local window = { render=function(rect) local ls=lines(rect:w()); for i,l in ipairs(ls) do if i>rect:h() then break end; ui.text_ansi(ui.rect(rect:x(),rect:y()+i-1,rect:w(),1),l) end end }
function window.on_pointer(event)
  if event.kind ~= "down" or event.button ~= "left" or event.y ~= 0 then return false end
  if event.x >= 0 and event.x < 7 then state.mode = "stats"
  elseif event.x >= 8 and event.x < 15 then state.mode = "kills"
  elseif event.x >= 16 and event.x < 23 then M.close(); return true
  else return false end
  changed()
  return true
end
local function toggle() local wm=require("wm"); if popup_open and wm.popup.is_open() then wm.popup.close(); popup_open=false else wm.popup.open(window,{title="XP Monitor",width=.5,height=.42,on_close=function() popup_open=false end}); popup_open=true end end
local function changed() if popup_open then ui.dirty() end; save() end
local function add(pattern, fn) local id=trigger.add(pattern,fn,{omit_from_output=true}); if id then trigger_ids[#trigger_ids+1]=id end end
local function close_popup()
  local wm = require("wm")
  if popup_open and wm.popup.is_open() then wm.popup.close() end
  popup_open = false
end

function M.is_open() return popup_open end
function M.open() if not popup_open then toggle() end end
function M.close() close_popup() end
function M.toggle() toggle() end

function M.on_load()
  store.load(); local saved=store.get(); if type(saved)=="table" then state=saved; state.kills=state.kills or {} end
  add("^You have ([0-9,]+) total xp\\.$",function(_, n) n=tonumber((n:gsub(",", ""))); local d=n-(state.total or 0); state.total=n; if d>0 and pending_kill then table.insert(state.kills,1,{enemy=pending_kill,xp=d}); if #state.kills>20 then table.remove(state.kills) end; pending_kill=nil end; changed() end)
  add("^You have ([0-9,]+) to spend\\.$",function(_,n) state.spend=tonumber((n:gsub(",", ""))); changed() end)
  add("^XP Gain for the last 30 minutes: ([0-9,]+)$",function(_,n) state.gain30=tonumber((n:gsub(",", ""))); changed() end)
  add("^You have reached maximum level\\.$",function() state.max=true; changed() end)
  add("^You need ([0-9,]+) experience to achieve your next level\\.$",function() state.max=false; changed() end)
  local k=plugin.get("kill_trigger"); if k and k.on_monster_died then kill_listener=k.on_monster_died(function(_,victim) pending_kill=victim end) end
  command_id=assert(command.register({name="/xp",usage="/xp [stats|kills|reset|refresh]",summary="XP monitor",accepts_args=true,handler=function(a) local x=(a or ""):match("%S+") or ""; if x=="kills" or x=="stats" then state.mode=x; changed(); if not popup_open then toggle() end elseif x=="reset" then state.baseline=state.total; state.reset_at=os.time(); state.kills={}; changed(); mud.send("xp") elseif x=="refresh" then mud.send("xp") else toggle() end end}))
end
function M.on_unload() close_popup(); for _,id in ipairs(trigger_ids) do trigger.remove(id) end; if command_id then command.unregister(command_id) end; local k=plugin.get("kill_trigger"); if k and kill_listener then k.remove_kill_listener(kill_listener) end end
return M
