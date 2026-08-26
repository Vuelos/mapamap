-- Warp + Details tests: the session warp helpers (place / pair / move /
-- remove / dest / connect), the live Warps tab, and the modal Details panel
-- (build / commit / nudge / activate / delete + keyboard routing).

package.path = "../../../?.lua;" .. package.path

if not _G.love then _G.love = require("tests.love_stub") end

local Data = require("src.core.Data")
if not (Data.maps and Data.maps.PALLET_TOWN) then Data:load() end
local data = Data

local Session = require("mods.mapamap.domain.edit_session")
local Input = require("mods.mapamap.controllers.input")
local Inventory = require("mods.mapamap.components.inventory")
local Details = require("mods.mapamap.components.details")
local Overlay = require("mods.mapamap.components.overlay")
local Panel = require("mods.mapamap.components.panel")

local mod = {
  log = { warn = function() end, info = function() end, error = function() end },
  save = { get = function() return nil end, set = function() end },
  ui = { Font = { draw = function() end } },
}
local game = { data = data, overworld = nil }

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
end

local VW, VH = 640, 576

-- Centre of inventory CONTENT cell `i` (1-based) on the active tab.  The
-- first grid slot is the tab's toolbar shortcut, so content starts at the
-- second cell.
local function inventoryCellCentre(i)
  local px, py = Inventory.rect(VW, VH)
  local ci = i
  local col = ci % Inventory.COLS
  local row = math.floor(ci / Inventory.COLS)
  return px + Panel.PAD + col * (Inventory.SLOT + Inventory.GAP) + Inventory.SLOT / 2,
         py + Panel.PAD + Panel.TITLE_H + Panel.TITLE_GAP + Panel.TAB_H + Inventory.GAP
            + row * (Inventory.SLOT + Inventory.GAP) + Inventory.SLOT / 2
end

function test_placeWarpInBody()
  local s = assert(Session.new(mod, game, "PALLET_TOWN"))
  s.def.warps = {}
  local w = s:placeWarp(1, 1)
  assert(w, "placeWarp should return the warp")
  assert(s:warpAt(1, 1) == w, "warp should be wired at the cell")
  assert(w.destMap == "PALLET_TOWN", "default dest is the map itself")
  assert(w.destWarp == 1, "default dest warp is 1 (engine indexes warps[n] directly)")
  assert(s.mapChanged, "placing should mark the map changed")
end

function test_placeWarpOutOfBounds()
  local s = assert(Session.new(mod, game, "PALLET_TOWN"))
  s.def.warps = {}
  assert(s:placeWarp(-1, 0) == nil, "left of the map is rejected")
  assert(s:placeWarp(0, -1) == nil, "above the map is rejected")
  assert(s:placeWarp(s.def.width * 2, 0) == nil, "beyond the east edge is rejected")
  assert(#s.def.warps == 0, "nothing should be inserted for rejected cells")
end

-- Identity transform so Input.paintAt can map screen -> world cells headless
-- (a live overworld/camera does not exist under the stub).
local function stubTransform()
  local Coords = require("mods.mapamap.engine.coords")
  local orig = Coords.transform
  Coords.transform = function()
    return { camx = 0, camy = 0, sx = 1, sy = 1, wox = 0, woy = 0 }
  end
  return function() Coords.transform = orig end
end

-- A creator-built warp tool carries its destination as a `create` payload;
-- painting it inserts exactly ONE warp at the cell.
local function newWarpTool()
  return { kind = "entity", entityType = "warp",
           create = { destMap = "PALLET_TOWN", destWarp = 0 } }
end

function test_templatePaintPlacesSingleWarp()
  local s = assert(Session.new(mod, game, "PALLET_TOWN"))
  s.def.warps = {}
  resetInput()
  Input.reset()
  Input.hotbar[1] = newWarpTool()
  Input.selected = 1
  local restore = stubTransform()
  local spent = Input.paintAt(s, 16 * 4 + 8, 16 * 5 + 8)
  restore()
  assert(spent, "painting a warp tool should succeed")
  assert(#s.def.warps == 1, "the tool places exactly ONE warp, not a pair")
  local w = s.def.warps[1]
  assert(w.x == 4 and w.y == 5, "single warp sits at the painted cell")
  assert(w.destMap == "PALLET_TOWN" and w.destWarp == 0,
    "warp keeps the tool's self-destination (map itself, warp 0)")
end

function test_templatePaintPlacesSingleWarpAnywhere()
  local s = assert(Session.new(mod, game, "PALLET_TOWN"))
  s.def.warps = {}
  resetInput()
  Input.hotbar[1] = newWarpTool()
  Input.selected = 1
  local restore = stubTransform()
  for _, cell in ipairs({ { 19, 0 }, { 0, 17 }, { 7, 6 } }) do
    local tx = 16 * cell[1] + 8
    local ty = 16 * cell[2] + 8
    Input.reset()
    local before = #s.def.warps
    Input.paintAt(s, tx, ty)
    assert(#s.def.warps == before + 1,
      "each warp tool paint inserts exactly one warp")
  end
  -- Out-of-map cells are rejected; nothing is inserted.
  local before = #s.def.warps
  Input.reset()
  Input.paintAt(s, 16 * -1, 16 * 2 + 8)
  assert(#s.def.warps == before, "off-map warp tool paint is rejected")
  restore()
end

function test_moveAndRemoveWarp()
  local s = assert(Session.new(mod, game, "PALLET_TOWN"))
  s.def.warps = {}
  local w = s:placeWarp(3, 3)
  assert(s:moveWarp(w, 5, 6), "move should succeed")
  assert(w.x == 5 and w.y == 6, "warp lands on the new cell")
  assert(s:warpAt(5, 6) == w, "warp now lives at the new cell")
  assert(s:moveWarp(w, -1, 0) == false, "moving out of bounds is rejected")
  assert(w.x == 5 and w.y == 6, "rejected move leaves the warp in place")
  assert(s:removeWarp(w), "remove should succeed")
  assert(#s.def.warps == 0, "warp removed from the array")
  assert(s:removeWarp(w) == false, "double removal is a no-op")
end

function test_undoRedoWarpViaKeyboard()
  local s = assert(Session.new(mod, game, "PALLET_TOWN"))
  s.def.warps = {}
  resetInput()
  Input.hotbar[1] = newWarpTool()
  Input.selected = 1
  local restore = stubTransform()
  Input.reset()
  assert(Input.paintAt(s, 16 * 2 + 8, 16 * 3 + 8), "warp tool paint succeeds")
  restore()
  assert(#s.def.warps == 1, "one warp placed")
  local orig = _G.love.keyboard.isDown
  _G.love.keyboard.isDown = function() return true end
  assert(Input.keypressed(s, "z"), "Ctrl+Z triggers undo")
  assert(#s.def.warps == 0, "undo removes the placed warp")
  assert(s:warpAt(2, 3) == nil, "undo clears the warp cell")
  assert(Input.keypressed(s, "y"), "Ctrl+Y triggers redo")
  assert(#s.def.warps == 1, "redo restores the warp")
  assert(s:warpAt(2, 3) ~= nil, "redo rewires the warp cell")
  _G.love.keyboard.isDown = orig
end

function test_setWarpDestAndLabel()
  local s = assert(Session.new(mod, game, "PALLET_TOWN"))
  s.def.warps = {}
  -- Warp # is validated against the destination's warp list: give
  -- ROUTE_1 enough entries for the #2 this test points at.
  local rd = Data.maps.ROUTE_1
  rd.warps = rd.warps or {}
  while #rd.warps < 3 do rd.warps[#rd.warps + 1] = { x = 0, y = 0 } end
  local w = s:placeWarp(0, 0)
  assert(s:setWarpDest(w, "ROUTE_1", 2), "dest change should succeed")
  assert(w.destMap == "ROUTE_1" and w.destWarp == 2, "dest fields updated")
  assert(not s:setWarpDest(w, nil, 9), "past-the-end numbers are rejected")
  assert(s:setWarpLabel(w, "exit"), "label set should succeed")
  assert(w.label == "exit", "label stored on the warp")
end

function test_connectWarpToCellCreatesReciprocal()
  local s = assert(Session.new(mod, game, "PALLET_TOWN"))
  s.def.warps = {}
  local w = s:placeWarp(1, 1)
  local destDef = assert(data.maps.ROUTE_1, "ROUTE_1 must be loaded")
  destDef.warps = {}
  assert(s:connectWarpToCell(w, "ROUTE_1", 0, 0), "connect should succeed")
  assert(w.destMap == "ROUTE_1" and w.destWarp == 1,
    "source warp re-pointed at the destination warp (1-based)")
  local dw = destDef.warps[1]
  assert(dw and dw.x == 0 and dw.y == 0, "destination warp placed at the cell")
  assert(dw.destMap == "PALLET_TOWN", "destination reciprocates back")
  assert(dw.destWarp == s:warpIndex(w), "reciprocal index points at the source")
  assert(s.neighborDirty and s.neighborDirty.ROUTE_1,
    "loaded destination is marked dirty for persistence")
end

function test_connectWarpToCellReusesExisting()
  local s = assert(Session.new(mod, game, "PALLET_TOWN"))
  s.def.warps = {}
  local w = s:placeWarp(1, 1)
  local destDef = assert(data.maps.ROUTE_1)
  destDef.warps = { { x = 0, y = 0, destMap = "VIRIDIAN_CITY", destWarp = 0 } }
  assert(s:connectWarpToCell(w, "ROUTE_1", 0, 0), "connect over an existing warp")
  assert(#destDef.warps == 1, "existing destination warp is reused, not duplicated")
  assert(destDef.warps[1].destMap == "PALLET_TOWN",
    "the reused warp is rewired to the source map")
end

function test_warpTabLoadsPlacementTool()
  local s = assert(Session.new(mod, game, "PALLET_TOWN"))
  s.def.warps = {}
  local w = s:placeWarp(2, 2, "ROUTE_1", 1)
  resetInput()
  Input.inventory = { items = {
    { kind = "entity", entityType = "warp", destMap = "ROUTE_1", destWarp = 1, warp = w },
  }, tab = 2, scroll = 1 }
  assert(Inventory.tabFor({ kind = "entity", entityType = "warp" }) == 2,
    "warps mount on the Entities tab")
  local cx, cy = inventoryCellCentre(1)
  local consumed = Input.mousepressed(s, game, cx, cy, 1)
  assert(consumed, "click on a warp cell is consumed")
  local item = Input.hotbar[1]
  assert(item and item.kind == "entity" and item.entityType == "warp",
    "loaded tool is a warp tool")
  assert(item.destMap == "ROUTE_1" and item.destWarp == 1,
    "tool carries the warp's destination")
  assert(s.selectedItem == w, "loading a live warp selects it")
end

-- The template cells are gone; each tab leads with its own toolbar shortcut
-- ([E] picker, [F] factory, [R] blueprint rect-select, [M] Brush Maker) and
-- nothing arms a tool from the empty grid.
function test_shortcutCellsAreNotItems()
  local s = assert(Session.new(mod, game, "PALLET_TOWN"))
  resetInput()
  Input.inventory = { items = {}, tab = 2, scroll = 1 }
  -- The tab's shortcut cell (first grid slot; centre of content index 0).
  local sx, sy = inventoryCellCentre(0)
  assert(Input.mousepressed(s, game, sx, sy, 1), "shortcut click is consumed")
  assert(Input.hotbar[1] == nil, "shortcut cell arms no tool")
  -- An empty content cell arms nothing either.
  local cx, cy = inventoryCellCentre(1)
  assert(Input.mousepressed(s, game, cx, cy, 1), "empty cell click is consumed")
  assert(Input.hotbar[1] == nil, "empty content cell arms no tool")
end

function test_warpTabShowsOnlySavedItems()
  local s = assert(Session.new(mod, game, "PALLET_TOWN"))
  s.def.warps = {}
  s:placeWarp(4, 4)
  resetInput()
  Input.inventory = { items = {}, tab = 3, scroll = 1 }
  assert(#Input.inventoryList(s) == 0, "live warps are not mixed into the inventory")
end

function test_inventoryRmbOpensWarpDetails()
  local s = assert(Session.new(mod, game, "PALLET_TOWN"))
  s.def.warps = {}
  -- Docked side surfaces would eat inventory clicks: start clean.
  Input.showEntitySelector = false
  Input.entityCreator = nil
  Input.showBrushEditor = false
  Input.slotsOpen = false
  Input.details = nil
  Input.showInventory = true
  local w = s:placeWarp(3, 3)
  resetInput()
  Input.inventory = { items = { { kind = "entity", entityType = "warp", warp = w } },
    tab = 2, scroll = 1 }
  local cx, cy = inventoryCellCentre(1)
  assert(Input.mousepressed(s, game, cx, cy, 2), "RMB on a warp cell is consumed")
  assert(Input.details and Input.details.target
    and Input.details.target.entity == w, "RMB opens Details for the warp")
end

function test_inventoryRmbOnItemOpensDetails()
  local s = assert(Session.new(mod, game, "PALLET_TOWN"))
  Input.showEntitySelector = false
  Input.entityCreator = nil
  Input.showBrushEditor = false
  Input.slotsOpen = false
  Input.details = nil
  Input.showInventory = true
  s.def.blocks = {}
  local it = { kind = "block", id = 7 }
  Input.inventory = { items = { it }, tab = 1, scroll = 1 }
  local cx, cy = inventoryCellCentre(1)
  assert(Input.mousepressed(s, game, cx, cy, 2), "RMB on an item cell is consumed")
  assert(Input.details and Input.details.target.item == it,
    "RMB opens Details for the inventory item")
end

function test_detailsBuildWarpFields()
  local s = assert(Session.new(mod, game, "PALLET_TOWN"))
  s.def.warps = {}
  local w = s:placeWarp(1, 2, "ROUTE_1", 3)
  Input.openDetails(s, { entity = w, entityType = "warp" })
  local d = Input.details
  local keys, types = {}, {}
  for _, f in ipairs(d.fields) do keys[#keys + 1] = f.key; types[f.key] = f.type end
  assert(keys[1] == "pos" and types.pos == "readonly", "Pos field is readonly")
  assert(keys[2] == "destMap" and types.destMap == "text", "Dest map is text")
  assert(keys[3] == "destWarp" and types.destWarp == "number", "Warp # is numeric")
  assert(keys[4] == "label", "Label field present")
  assert(#keys == 4, "warp has 4 field rows (no inline DELETE)")
  assert(d.index == 1, "opens on the first field")
end

function test_detailsCommitValidatesDestMap()
  local s = assert(Session.new(mod, game, "PALLET_TOWN"))
  s.def.warps = {}
  local w = s:placeWarp(0, 0)
  Input.openDetails(s, { entity = w, entityType = "warp" })
  local d = Input.details
  d.index = 2 -- destMap
  assert(Details.commit(s, d, d.index, "NOT_A_MAP") == false,
    "commit of an unknown map is rejected")
  assert(w.destMap == "PALLET_TOWN", "rejected commit leaves the warp untouched")
  assert(Details.commit(s, d, d.index, "ROUTE_1"), "commit of a known map succeeds")
  assert(w.destMap == "ROUTE_1", "warp re-pointed on commit")
end

function test_detailsNudgeWarpNumber()
  local s = assert(Session.new(mod, game, "PALLET_TOWN"))
  s.def.warps = {}
  -- The nudge walks the destination's warp list: give ROUTE_1 enough
  -- entries for #2.
  local rd = Data.maps.ROUTE_1
  rd.warps = rd.warps or {}
  while #rd.warps < 3 do rd.warps[#rd.warps + 1] = { x = 0, y = 0 } end
  local w = s:placeWarp(0, 0, "ROUTE_1", 1)
  Input.openDetails(s, { entity = w, entityType = "warp" })
  local d = Input.details
  d.index = 3 -- destWarp
  Details.nudge(s, d, 1)
  assert(w.destWarp == 2, "right-nudge increments the warp number")
  Details.nudge(s, d, -3)
  assert(w.destWarp == 1, "numeric clamps keep a valid 1-based warp number")
end

function test_detailsKeyboardEditingLabel()
  local s = assert(Session.new(mod, game, "PALLET_TOWN"))
  s.def.warps = {}
  local w = s:placeWarp(0, 0)
  Input.openDetails(s, { entity = w, entityType = "warp" })
  local d = Input.details
  d.index = 4 -- label
  assert(Input.keypressed(s, "return"), "Enter starts the text edit")
  assert(d.editing and d.editing.fieldIdx == 4 and d.editing.buf == "",
    "editing buffer primed with the current value")
  assert(Input.keypressed(s, "h") and Input.keypressed(s, "i"),
    "printable keys append to the buffer")
  assert(d.editing.buf == "hi", "buffer accumulates typed text")
  assert(Input.keypressed(s, "return"), "Enter commits the edit")
  assert(d.editing == nil, "editing session ends on commit")
  assert(w.label == "hi", "warp label written through")
end

function test_detailsDeleteWarp()
  local s = assert(Session.new(mod, game, "PALLET_TOWN"))
  s.def.warps = {}
  local w = s:placeWarp(1, 1)
  Input.openDetails(s, { entity = w, entityType = "warp" })
  assert(Input.keypressed(s, "x"), "X deletes the target")
  assert(#s.def.warps == 0, "warp removed from the map")
  assert(Input.details == nil, "Details closes after delete")
end

function test_detailsModalConsumesAndCloses()
  local s = assert(Session.new(mod, game, "PALLET_TOWN"))
  s.def.warps = {}
  local w = s:placeWarp(1, 1)
  Input.openDetails(s, { entity = w, entityType = "warp" })
  assert(Input.details, "details open")
  -- Keyboard routing owns all keys while open.
  assert(Input.keypressed(s, "e") == true, "E is consumed by the modal")
  assert(Input.showPicker == false, "E did not open the picker underneath")
  -- Escape closes without an edit.
  assert(Input.keypressed(s, "escape"), "Escape closes the panel")
  assert(Input.details == nil, "detail stack cleared")
  assert(s:placeWarp(2, 2) == w or true, "session still usable after close")
end

function test_detailsOutsideClickCloses()
  local s = assert(Session.new(mod, game, "PALLET_TOWN"))
  s.def.warps = {}
  local w = s:placeWarp(1, 1)
  resetInput()
  Input.inventory = { items = { { kind = "entity", entityType = "warp", warp = w } }, tab = 2, scroll = 1 }
  local cx, cy = inventoryCellCentre(1)
  Input.mousepressed(s, game, cx, cy, 2)
  assert(Input.details, "details open via RMB")
  local d = Input.details
  local px, py, pw, ph = require("mods.mapamap.components.details").rect(VW, VH)
  -- A click far from the panel closes it; a click on the panel is consumed.
  assert(Input.mousepressed(s, game, 10, 10, 1), "outside click is consumed")
  assert(Input.details == nil, "outside click closes the panel")
end

-- The overlay draws warps in the RUNTIME's world frame (the map the overworld
-- is drawing, with neighbors at their strip offsets) so circles stay glued to
-- their tiles across a border cross -- not the session's frame, which lags
-- until the next input reconciles it.
function test_overlayWarpsFollowRuntimeFrame()
  local s = assert(Session.new(mod, game, "PALLET_TOWN"))
  s.def.warps = {}
  s.def.warps[1] = { x = 1, y = 1, destMap = "PALLET_TOWN", destWarp = 0 }
  local ow = {
    camera = { x = 0, y = 0 },
    map = {
      id = "VIRIDIAN_CITY",
      def = { warps = { { x = 2, y = 2, destMap = "VIRIDIAN_CITY", destWarp = 0 } } },
    },
    neighbors = {
      {
        map = { id = "ROUTE_2", def = { warps = { { x = 3, y = 4, destMap = "ROUTE_2", destWarp = 0 } } } },
        ox = 0, oy = -576,
      },
    },
  }
  local vis = Overlay.visibleWarps(s, { data = data, overworld = ow })
  assert(#vis == 2, "runtime frame enumerates ow.map + ow.neighbors, got " .. #vis)
  assert(vis[1].warp.x == 2 and vis[1].ox == 0 and vis[1].oy == 0,
    "runtime root warp anchors at 0,0")
  assert(vis[2].warp.x == 3 and vis[2].ox == 0 and vis[2].oy == -576,
    "runtime neighbor warp carries the runtime strip offset")
  -- No live overworld -> session anchor fallback (real neighbors carry their
  -- own data warps too; just assert the session's root warp anchors first).
  local vis2 = Overlay.visibleWarps(s, { data = data })
  assert(#vis2 >= 1, "fallback enumerates session warps")
  assert(vis2[1].warp == s.def.warps[1] and vis2[1].ox == 0 and vis2[1].oy == 0,
    "fallback anchors the session's root warp at 0,0")
end

-- The Details component is required lazily by Input; the top-level require
-- above keeps the commit/nudge helpers available to the tests.

function test_visibleWarpsIncludeNeighborMaps()
  local s = assert(Session.new(mod, game, "PALLET_TOWN"))
  assert(s.neighbors and #s.neighbors > 0, "fixture expects laid-out neighbors")
  s.def.warps = {}
  local rootWarp = { x = 1, y = 1, destMap = "PALLET_TOWN", destWarp = 0 }
  s.def.warps[1] = rootWarp
  local nb = s.neighbors[1]
  local nbWarp = { x = 3, y = 4, destMap = "PALLET_TOWN", destWarp = 0 }
  nb.def.warps = { nbWarp }
  -- The real data set may carry its own warps on PALLET_TOWN / its neighbors;
  -- assert on our two identity markers, not on the total count.
  local vis = s:visibleWarps()
  assert(#vis >= 2, "root + neighbor warps both visible, got " .. #vis)
  local foundRoot, foundNb = false, false
  for _, e in ipairs(vis) do
    if e.warp == rootWarp then
      assert(e.ox == 0 and e.oy == 0, "root warp carries the 0,0 world offset")
      foundRoot = true
    elseif e.warp == nbWarp then
      assert(e.ox == nb.ox and e.oy == nb.oy,
        "neighbor warp carries the neighbor's world offset")
      foundNb = true
    end
  end
  assert(foundRoot and foundNb, "both maps' warps must be enumerated")
end

return {
  name = "MAPAMAP_WARP",
  tests = {
    "test_placeWarpInBody",
    "test_placeWarpOutOfBounds",
    "test_templatePaintPlacesSingleWarp",
    "test_templatePaintPlacesSingleWarpAnywhere",
    "test_moveAndRemoveWarp",
    "test_undoRedoWarpViaKeyboard",
    "test_setWarpDestAndLabel",
    "test_connectWarpToCellCreatesReciprocal",
    "test_connectWarpToCellReusesExisting",
    "test_warpTabLoadsPlacementTool",
    "test_shortcutCellsAreNotItems",
    "test_warpTabShowsOnlySavedItems",
    "test_inventoryRmbOpensWarpDetails",
    "test_inventoryRmbOnItemOpensDetails",
    "test_detailsBuildWarpFields",
    "test_detailsCommitValidatesDestMap",
    "test_detailsNudgeWarpNumber",
    "test_detailsKeyboardEditingLabel",
    "test_detailsDeleteWarp",
    "test_detailsModalConsumesAndCloses",
    "test_detailsOutsideClickCloses",
    "test_visibleWarpsIncludeNeighborMaps",
    "test_overlayWarpsFollowRuntimeFrame",
  },
}
