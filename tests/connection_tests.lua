-- Mapamap connection-graph tests (grid model): map expansion runs on load via
-- MapGrid (never on paint), closing every open void within one hop of the
-- loaded map and wiring each flush neighbour with a reciprocal connection so
-- the graph stays consistent (the old "bug 2" surface: the right map connects
-- back to the centre map, never a stale / offset-shifted side extension).

package.path = "../../../?.lua;" .. package.path

if not _G.love then _G.love = require("tests.love_stub") end

local Data = require("src.core.Data")
if not (Data.maps and Data.maps.PALLET_TOWN) then Data:load() end
local data = Data

local Session = require("mods.mapamap.session")
local Input = require("mods.mapamap.input")
local MapGrid = require("mods.mapamap.func.map_grid")
local Common = require("mods.mapamap.func.common")

local mod = {
  log = { warn = function() end, info = function() end, error = function() end },
  save = { get = function() return nil end, set = function() end },
  ui = { Font = { draw = function() end } },
}
local game = { data = data, overworld = nil }

local BACK = { north = "south", south = "north", east = "west", west = "east" }

local function conn(def, dir)
  return (def.connections or {})[dir]
end

-- Every reciprocal connection must mirror its forward offset.
local function assertReciprocal(def, rootId, where)
  for dir, c in pairs(def.connections or {}) do
    local other = data.maps and data.maps[c.map]
    local back = BACK[dir]
    assert(other, where .. ": " .. def.id .. " -> " .. c.map .. " missing def")
    assert(back, where .. ": bad dir " .. tostring(dir))
    local r = conn(other, back)
    assert(r, where .. ": " .. def.id .. "->" .. c.map
      .. " missing reciprocal " .. tostring(back))
    assert(r.map == def.id, where .. ": reciprocal back-points " .. r.map
      .. " not " .. def.id)
    assert(r.offset == -(c.offset or 0), where .. ": offset mismatch "
      .. (r.offset or 0) .. " vs " .. (-(c.offset or 0)))
  end
end

-- Deep-snapshots the connection graph of every map reachable from Pallet, so a
-- test can restore the shared live data afterwards (grid tests create maps).
local function captureGraph()
  local saved = {}
  local stack = { "PALLET_TOWN" }
  local seen = {}
  while #stack > 0 do
    local id = table.remove(stack)
    if not seen[id] then
      seen[id] = true
      local def = data.maps[id]
      if def then
        saved[id] = Common.deepCopy(def.connections or {})
        for _, c in pairs(def.connections or {}) do
          if data.maps[c.map] then table.insert(stack, c.map) end
        end
      end
    end
  end
  return saved
end

-- The pristine graph, captured once before any test mutates the shared data.
local PRistine = captureGraph()

-- Restores the pristine connection graph and removes every grid-created _EXT
-- map, so each test starts from the real Pallet data.
local function restoreGraph()
  for id, conns in pairs(PRistine) do
    local def = data.maps[id]
    if def then def.connections = Common.deepCopy(conns) end
  end
  local created = {}
  for id in pairs(data.maps) do
    if id:find("^PALLET_TOWN_EXT") then created[#created + 1] = id end
  end
  local MapLoader = require("src.world.MapLoader")
  for _, id in ipairs(created) do
    data.maps[id] = nil
    MapLoader.invalidate(id)
  end
end

local function gridCreatedCount()
  local n = 0
  for id in pairs(data.maps) do
    if id:find("^PALLET_TOWN_EXT") then n = n + 1 end
  end
  return n
end

local function resetInput()
  Input.hotbar = {}
  Input.selected = 1
  Input.showPicker = false
  Input.pickerScroll = 1
  Input.pickerTilesetScroll = 1
  Input.dragItem = nil
  Input.selectedWarp = nil
  Input.warpDestPick = false
  Input.details = nil
  Input.inventory = { items = {}, tab = 1, scroll = 1 }
  Input.reset()
end

-- Identity transform so Input.paintAt can map screen -> world cells headless
-- (a live overworld/camera does not exist under the stub).
local function stubTransform()
  local Coords = require("mods.mapamap.func.coords")
  local orig = Coords.transform
  Coords.transform = function()
    return { camx = 0, camy = 0, sx = 1, sy = 1, wox = 0, woy = 0 }
  end
  return function() Coords.transform = orig end
end

-- Control+Z (undo) must not crash: the undo path in map_ops restoreSnapshot
-- calls reloadMap() on the primary-map branch, which mapamap's Session must
-- provide (it is not mixed in from map_editor's full-screen scene).
function test_undoAfterPaintDoesNotCrash()
  local s = Session.new(mod, game, "PALLET_TOWN")
  assert(s, "no session for PALLET_TOWN")
  s:rebuildNeighbors()
  local before = s.def.blocks[1]
  -- Paint the top-left block cell (world cell 0,0 -> block 0, blocks[1]).
  s.cursorBx, s.cursorBy = 0, 0
  s:snapCursorToBlock()
  s.selectedBlock = 0
  assert(s.undo and s.undo:stack("undo"), "session should have an undo stack")
  assert(before ~= 0, "pick a paint value different from the existing block")
  s:paintBlock()
  assert(s.undo and s.undo:canUndo(), "paint should push an undo step")
  assert(s.def.blocks[1] == 0, "paint should have changed the block")
  -- Ctrl+Z path: restoreSnapshot("undo") then refresh live renderers.
  s:restoreSnapshot("undo")
  s:refreshLiveRenderers()
  assert(s.def.blocks[1] == before, "undo should restore the original block")
end

-- The grid fill's first void must wire flush maps reciprocally (mirror
-- offsets), and the new map must be reachable from the root through the
-- connection graph -- never a dangling / offset-shifted side extension.
function test_gridCreateWiresFlushReciprocals()
  restoreGraph()
  local s = Session.new(mod, game, "PALLET_TOWN")
  assert(s, "no session for PALLET_TOWN")
  s:rebuildNeighbors()
  local id = MapGrid.fillNextVoid(s, 1)
  assert(id, "depth-1 fill should close an open void around Pallet")
  local newDef = assert(data.maps[id], "new map should live in data.maps")
  assertReciprocal(newDef, "PALLET_TOWN", "grid-" .. id)
  -- The whole graph stays reciprocal-consistent after the create.
  for _, r in ipairs(MapGrid.layout(data.maps, "PALLET_TOWN", math.huge)) do
    assertReciprocal(r.def, "PALLET_TOWN", "full-" .. r.id)
  end
  -- The new map is reachable from the root via connections.
  local found
  for _, r in ipairs(MapGrid.layout(data.maps, "PALLET_TOWN", math.huge)) do
    if r.id == id then found = r end
  end
  assert(found, "new map should be reachable from the root")
  assert(found.w > 0 and found.h > 0, "new map should have a body")
  assert(s._newMaps and s._newMaps[id], "new map tracked whole for persistence")
end

-- After a grid create + rebuild, a cell inside the new map's body is a
-- neighbor cell (so a paint lands there), while a cell beyond every laid-out
-- body reports the root's card edge and is NOT inside any neighbor (block
-- paint then no-ops).
function test_cellInsideNeighborAfterCreate()
  restoreGraph()
  local s = Session.new(mod, game, "PALLET_TOWN")
  assert(s, "no session for PALLET_TOWN")
  s:rebuildNeighbors()
  local id = MapGrid.fillNextVoid(s, 1)
  assert(id, "depth-1 fill should create a map")
  s:rebuildNeighbors()
  local x, y
  for _, r in ipairs(MapGrid.layout(data.maps, "PALLET_TOWN", math.huge)) do
    if r.id == id then x, y = r.x, r.y end
  end
  assert(x and y, "new map should be laid out")
  assert(s:cellInsideNeighbor(x * 2 + 1, y * 2 + 1),
    "a cell inside the new map's body should hit a neighbor")
  assert(not s:cellInsideNeighbor(500, 500),
    "a far-off cell should not be inside any neighbor")
  assert(s:cellEdgeSide(500, 5) == "east",
    "a far east cell reports the root's east edge")
end

-- Painting a block beyond every laid-out map body must no-op: expansion runs
-- on load (MapGrid.autofill), never on paint.
function test_paintBeyondAllBodiesNoops()
  restoreGraph()
  local s = Session.new(mod, game, "PALLET_TOWN")
  assert(s, "no session for PALLET_TOWN")
  local before = Common.deepCopy(s.def.blocks)
  local createdBefore = gridCreatedCount()
  resetInput()
  Input.hotbar[1] = { kind = "block", id = 0 }
  Input.selected = 1
  local restore = stubTransform()
  local spent = Input.paintAt(s, 16 * 500 + 8, 16 * 500 + 8)
  restore()
  assert(spent == false, "off-body block paint should be a no-op, got "
    .. tostring(spent))
  assert(gridCreatedCount() == createdBefore,
    "off-body paint must never create a map")
  assert(Common.tablesEqual(s.def.blocks, before),
    "off-body paint must not touch any block")
end

-- Painting into a real neighbor's body still paints (the load-time grid does
-- not break cross-border block painting).
function test_paintOnNeighborBodyStillPaints()
  restoreGraph()
  local s = Session.new(mod, game, "PALLET_TOWN")
  assert(s, "no session for PALLET_TOWN")
  s:rebuildNeighbors()
  local routeDef = assert(data.maps.ROUTE_1, "ROUTE_1 must be loaded")
  local targetIdx = 13 * routeDef.width + 2 + 1  -- block (2,13) on ROUTE_1
  local orig = routeDef.blocks[targetIdx]
  resetInput()
  Input.hotbar[1] = { kind = "block", id = 0 }
  Input.selected = 1
  local restore = stubTransform()
  local spent = Input.paintAt(s, 16 * 4 + 8, 16 * -10 + 8)  -- world cell (4,-10)
  restore()
  assert(spent, "paint into a neighbor body should paint")
  assert(routeDef.blocks[targetIdx] == 0,
    "block should be painted on the neighbor map")
  routeDef.blocks[targetIdx] = orig
end

-- Autofill closes every open void within one hop and then stops: a follow-up
-- fill returns nil (the world around the loaded map is fully tiled).
function test_autofillFillsVoidsThenStops()
  restoreGraph()
  local s = Session.new(mod, game, "PALLET_TOWN")
  assert(s, "no session for PALLET_TOWN")
  s:rebuildNeighbors()
  local created = MapGrid.autofill(s, 1)
  assert(created >= 1,
    "autofill should close at least one void around Pallet, got " .. created)
  assert(created <= 64, "autofill must respect its cap, got " .. created)
  -- Every created map is tracked whole for persistence.
  local tracked = 0
  for id, def in pairs(s._newMaps or {}) do
    tracked = tracked + 1
    assert(data.maps[id], "tracked new map " .. id .. " should live in data.maps")
    assert(def.width == data.maps[id].width and def.height == data.maps[id].height,
      "tracked copy should mirror the live footprint")
  end
  assert(tracked == created, "every created map is tracked, got " .. tracked)
  -- The depth-1 world is now fully tiled: no open void remains.
  assert(MapGrid.fillNextVoid(s, 1) == nil,
    "no depth-1 void should remain after autofill")
  -- And the whole (larger) graph still reciprocates.
  for _, r in ipairs(MapGrid.layout(data.maps, "PALLET_TOWN", math.huge)) do
    assertReciprocal(r.def, "PALLET_TOWN", "post-" .. r.id)
  end
end

return {
  name = "MAPAMAP_CONNECTION",
  teardown = function()
    restoreGraph()
    data = Data
  end,
  tests = {
    "test_undoAfterPaintDoesNotCrash",
    "test_gridCreateWiresFlushReciprocals",
    "test_cellInsideNeighborAfterCreate",
    "test_paintBeyondAllBodiesNoops",
    "test_paintOnNeighborBodyStillPaints",
    "test_autofillFillsVoidsThenStops",
  },
}
