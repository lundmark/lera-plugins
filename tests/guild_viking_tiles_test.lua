package.path = "3scapes/guild_viking/?.lua;" .. package.path
local mode, loads, draws = "gui", {}, {}
local root = "3scapes/guild_viking/"
local function rect(x,y,w,h)
  return {x=function() return x end,y=function() return y end,
    w=function() return w end,h=function() return h end}
end
ui = {
  dirty=function() end, rect=rect, text_ansi=function() end,
  image_load=function(path)
    loads[path] = (loads[path] or 0)+1
    local f = io.open(root..path,"rb")
    if not f then return nil end
    assert(f:read(8) == "\137PNG\r\n\26\n", path)
    f:close()
    return path
  end,
  image=function(r,img,options)
    draws[#draws+1] = {rect=r,path=img}
    assert(options.fit == "stretch")
  end,
}
lera = {display=function() return mode end,render_pass=function() return "local" end}
local opts, tiles = require("page_opts"), require("tiles")
local maplib, S = require("maplib"), require("state").S
local function ends(s,suffix) assert(s and s:sub(-#suffix)==suffix, tostring(s).." expected "..suffix) end

-- All 16 masks, checked against independent N/E/S/W fixtures and filenames.
for mask=0,15 do
  local n,e,s,w = mask%2, math.floor(mask/2)%2, math.floor(mask/4)%2, math.floor(mask/8)%2
  local rows = {"."..(n==1 and "f" or ".")..".",
    (w==1 and "f" or ".").."f"..(e==1 and "f" or "."),
    "."..(s==1 and "f" or ".").."."}
  local path = tiles.board("campaign",rows,3,3)(1,1)
  ends(path,"woods_wang_"..w..s..e..n..".png")
  tiles.draw(rect(0,0,2,1),path)
end
ends(tiles.board("map",{"W=c"},3,1)(1,0),"bridge_wang_w_1010.png")
ends(tiles.board("map",{"W.",".W"},2,2)(0,0),"river_wang_0110.png")
ends(tiles.board("map",{"WW",".W"},2,2)(0,0),"river_wang_0010.png")
ends(tiles.board("campaign",{"f"},1,1)(0,0),"woods_wang_0000.png")
ends(tiles.board("sea",{"O"},1,1)(0,0),"sea_wang_1111.png")
ends(tiles.board("sea",{"MSD"},3,1)(1,0),"ship_over_mist.png")
ends(tiles.board("sea",{"#S#"},3,1)(1,0),"ship_over_sea.png")
ends(tiles.board("sea",{"DDD","DSD","DDD"},3,3)(1,1),"ship_over_deadwater.png")

opts.set("show_map_icons",true)
opts.set("show_sea_chart_icons",true)
opts.set("show_war_ascii",false)
local menus = require("page_menu")
local function has_option(page,key)
  for _,item in ipairs(menus.items(page)) do if item.value=="key:"..key then return true end end
  return false
end
assert(has_option("map","show_map_icons"))
assert(has_option("sea","show_sea_chart_icons"))
assert(has_option("war","show_war_ascii"))
for _,m in ipairs({"tty","headless"}) do
  mode=m
  assert(not tiles.enabled("map") and not tiles.enabled("sea") and not tiles.enabled("battle"))
  assert(not has_option("map","show_map_icons") and not has_option("war","show_war_ascii"))
  menus.pick("map","key:show_map_icons") -- cannot bypass a hidden item
  assert(opts.get("show_map_icons"))
end
mode="gui"

-- Images and ASCII share cell coordinates; image rows have no hidden gutter.
local grid = { w=2,h=2,cell=function() return {glyph="f"} end,
  image=tiles.board("campaign",{"ff","ff"},2,2) }
local g = maplib.geometry(grid,{col_headers=true,row_headers=true})
local lines = maplib.render(grid,{col_headers=true,row_headers=true})
assert(g.height==#lines)
for _,l in ipairs(lines) do assert(require("pagelib").visible_width(l)==g.width) end
for _,image in ipairs(g.images) do
  local c,r = g.cell_at(image.x,image.y)
  assert(c~=nil and r~=nil)
  local c2,r2 = g.cell_at(image.x+image.w-1,image.y+image.h-1)
  assert(c==c2 and r==r2)
end
draws={}
tiles.render_geometry(g,rect(10,20,g.width,2),0,1)
assert(#draws==2)
for _,d in ipairs(draws) do assert(d.rect:y()==20 and d.rect:x()>=10) end
draws={}
tiles.render_geometry(g,rect(10,20,3,1),0,1)
assert(#draws==0) -- partial tiles cannot bleed into adjacent panes
-- Resize uses the same geometry for painting and clicks, including markers.
for _,case in ipairs({{4,2,1},{8,4,2},{12,4,2}}) do
  local resized=maplib.geometry(grid,{},case[1])
  assert(resized.width==case[2]*grid.w)
  assert(resized.images[1].w==case[2] and resized.images[1].h==case[3])
  assert(#maplib.render(grid,{},case[1])==resized.height)
end
assert(#maplib.geometry(grid,{},3).images==4) -- narrow panes never disable PNGs
local marked={w=2,h=2,cell=function() return {glyph="12"} end,
  image=function() return tiles.city("plain"),true end}
local mg=maplib.geometry(marked,{},12)
assert(mg.images[1].w==4 and mg.images[1].h==2 and mg.height==4)
local mc,mr=mg.cell_at(3,2)
assert(mc==0 and mr==1) -- next row starts immediately, no marker gutter
assert(mg.images[3].y==mg.images[1].y+mg.images[1].h)
marked.cell=function(c,r) return {glyph="12",sel=c==0 and r==0} end
local selected=maplib.geometry(marked,{},12)
assert(#selected.images==3 and selected.height==mg.height)
assert(maplib.render(marked,{},12)[1]:find("\27[7m",1,true))
gui={size=function() return 1000,2000 end}
ui.size=function() return 100,100 end
assert(tiles.cell_aspect()==2)
gui=nil; ui.size=nil
-- Fit against the actual viewport height after reserving non-map content.
local panel={
  lines=function(width)
    local result=maplib.render(grid,{},width)
    for i=1,5 do result[#result+1]="status" end
    return result
  end,
  geometry=function(width) return maplib.geometry(grid,{},width) end,
  grid_line_offset=function() return 0 end,
}
local small,_,small_boards=tiles.layout(panel,80,8)
local large,_,large_boards=tiles.layout(panel,80,9)
assert(#small==7 and small_boards[1].geometry.images[1].h==1)
assert(#large==9 and large_boards[1].geometry.images[1].h==2)
assert(small_boards[1].geometry.cell_at(0,1)==0)
-- A later render cannot mutate the geometry saved for the previous pane.
local _,small_row=small_boards[1].geometry.cell_at(0,1)
local _,large_row=large_boards[1].geometry.cell_at(0,1)
assert(small_row==1 and large_row==0)
local path=tiles.city("plain")
tiles.draw(rect(0,0,2,1),path); tiles.draw(rect(0,0,2,1),path)
assert(loads[path]==1)
tiles.draw(rect(0,0,2,1),"missing.png"); tiles.draw(rect(0,0,2,1),"missing.png")
assert(loads["missing.png"]==1)

-- Battle wire row 1 is the BOTTOM. North/south art must follow displayed rows.
S.battle={width=1,height=2,phase="order",terrain_rows={"^","^"},units={}}
local battle=require("popups.war_battle")
local bg=battle.geometry(80)
assert(#bg.images==2)
ends(bg.images[1].path,"hill_wang_0100.png")
ends(bg.images[2].path,"hill_wang_0001.png")
S.war_map={active=true,dim=2,rows={"ff","ff"},units={},town="test"}
local war_lines,_,boards=require("pages.war").lines(80)
assert(#boards==2 and #boards[1].geometry.images==4 and #boards[2].geometry.images==2)
assert(boards[1].offset < boards[2].offset and #war_lines>boards[2].offset)
opts.set("show_war_ascii",true)
local _,_,ascii_boards=require("pages.war").lines(80)
assert(#ascii_boards[1].geometry.images==0 and #ascii_boards[2].geometry.images==0)

-- Territory tab is the exact same renderer as /vik map, with live image output.
S.vmap_seen=true; S.vmap_w=2; S.vmap_h=2
S.vmap_rows={"ff","ff"}; S.vmap_pois={}; S.vmap_px=-1; S.vmap_py=-1
local window=require("window")
assert(window.PAGES[#window.PAGES].key=="map")
assert(window.PAGES[#window.PAGES].mod==require("popups.map"))
assert(window.set_page("map"))
draws={}; window.render(rect(0,0,100,30),{})
assert(#draws==4)
mode="tty"; draws={}; window.render(rect(0,0,100,30),{})
assert(#draws==0)

-- Real glyph-mode GMCP rows already contain POIs, even when the separate
-- landmark list is absent. Every legacy symbol must resolve to its artwork.
mode="gui"
S.vmap_w=9; S.vmap_h=1; S.vmap_rows={"MLPSTRF*X"}; S.vmap_pois={}
local map=require("popups.map")
local poi_images=map.geometry(100).images
local expected={"castle","mead_hall","longhouse","herbyrgi","woods","rock",
  "farm","skald_hall","camp_host_you"}
assert(#poi_images==#expected)
for i,name in ipairs(expected) do
  ends(poi_images[i].path,"/"..name..".png")
  tiles.draw(rect(i*2,0,2,1),poi_images[i].path)
  assert(loads[poi_images[i].path], name)
end
-- Metadata overlays still win over baked symbols, then the current player.
S.vmap_pois={{type="capital",x=2,y=0}}
ends(map.geometry(100).images[3].path,"/castle.png")
S.vmap_px=2; S.vmap_py=0
ends(map.geometry(100).images[3].path,"/camp_host_you.png")
S.vmap_px=-1; S.vmap_pois={{type="future_type",x=2,y=0}}
ends(map.geometry(100).images[3].path,"/longhouse.png")
print("Viking tiles: masks, assets, GUI gating, clipping, cache, battle orientation, tabs PASS")
