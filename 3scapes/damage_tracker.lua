local M = { name="damage_tracker", version="1.0", priority=45 }
M.window_launcher = { label = "Damage Tracker", compact_label = "Damage", order = 30 }
local command=require("command")
local state={mode="hits",omit=false,recent={},kills={},total=0,rounds=0,current=nil,current_damage=0,current_rounds=0,current_at=0}
local trigger_id, command_id, kill_listener, popup_open
local function comma(n) local s=tostring(math.floor(n or 0)); repeat s,k=s:gsub("^(%-?%d+)(%d%d%d)","%1,%2") until k==0; return s end
local function save() store.set(state); store.save() end
local function redraw() if popup_open then ui.dirty() end; save() end
local function rebuild()
 if trigger_id then trigger.remove(trigger_id) end
 trigger_id=trigger.add("^You hit (.+?) ([0-9]+) times? for ([0-9]+) damage\\.$",function(_,enemy,hits,damage)
  hits,damage=tonumber(hits),tonumber(damage); if state.current~=enemy then state.current=enemy; state.current_damage=0; state.current_rounds=0; state.current_at=os.time() end
  state.current_damage=state.current_damage+damage; state.current_rounds=state.current_rounds+1; state.total=state.total+damage; state.rounds=state.rounds+1
  table.insert(state.recent,1,{enemy=enemy,hits=hits,damage=damage,round=state.current_rounds}); if #state.recent>10 then table.remove(state.recent) end; redraw()
 end,{omit_from_output=state.omit})
end
local function lines()
 local out={"\27[96m[Hits] [Kills] [Close]\27[0m"}
 if state.mode=="kills" then for _,k in ipairs(state.kills) do out[#out+1]=string.format("\27[93m%-18s\27[0m %2ds  \27[92m%s\27[0m  avg %s",k.enemy:sub(1,18),k.time,comma(k.damage),comma(k.damage/math.max(1,k.rounds))) end; if #state.kills==0 then out[#out+1]="\27[2mNo kills recorded yet\27[0m" end
 else out[#out+1]=string.format("\27[96mAverage: \27[0m%s / round",comma(state.total/math.max(1,state.rounds))); for _,h in ipairs(state.recent) do out[#out+1]=string.format("\27[93m%-20s\27[0m \27[92m%6s\27[0m (%dx, %dr)",h.enemy:sub(1,20),comma(h.damage),h.hits,h.round) end end
 out[#out+1]=""; out[#out+1]="\27[2m/dt [hits|kills|omit on|off|reset]\27[0m"; return out
end
local window={render=function(rect) for i,l in ipairs(lines()) do if i>rect:h() then break end; ui.text_ansi(ui.rect(rect:x(),rect:y()+i-1,rect:w(),1),l) end end}
function window.on_pointer(event)
  if event.kind ~= "down" or event.button ~= "left" or event.y ~= 0 then return false end
  if event.x >= 0 and event.x < 6 then state.mode = "hits"
  elseif event.x >= 7 and event.x < 14 then state.mode = "kills"
  elseif event.x >= 15 and event.x < 22 then M.close(); return true
  else return false end
  redraw()
  return true
end
local function toggle() local wm=require("wm"); if popup_open and wm.popup.is_open() then wm.popup.close(); popup_open=false else wm.popup.open(window,{title="Damage Tracker",width=.55,height=.58,on_close=function() popup_open=false end}); popup_open=true end end
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
 store.load(); local s=store.get(); if type(s)=="table" then state=s; state.recent=state.recent or {}; state.kills=state.kills or {} end; rebuild()
 local k=plugin.get("kill_trigger"); if k and k.on_monster_died then kill_listener=k.on_monster_died(function(_,victim) if state.current_damage>0 then table.insert(state.kills,1,{enemy=victim or state.current or "Unknown",damage=state.current_damage,rounds=state.current_rounds,time=os.time()-state.current_at}); if #state.kills>25 then table.remove(state.kills) end; state.current_damage=0; state.current_rounds=0; redraw() end end) end
 command_id=assert(command.register({name="/dt",usage="/dt [hits|kills|omit on|off|reset]",summary="Damage tracker",accepts_args=true,handler=function(a) local x,y=(a or ""):match("^(%S*)%s*(%S*)"); if x=="hits" or x=="kills" then state.mode=x; redraw(); if not popup_open then toggle() end elseif x=="omit" and (y=="on" or y=="off") then state.omit=y=="on"; rebuild(); redraw() elseif x=="reset" then state.recent={}; state.kills={}; state.total=0; state.rounds=0; state.current_damage=0; state.current_rounds=0; redraw() else toggle() end end}))
end
function M.on_unload() close_popup(); if trigger_id then trigger.remove(trigger_id) end; if command_id then command.unregister(command_id) end; local k=plugin.get("kill_trigger"); if k and kill_listener then k.remove_kill_listener(kill_listener) end end
return M
