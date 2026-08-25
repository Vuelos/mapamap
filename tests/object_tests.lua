-- Live Objects tab + Details tests: the session object helpers (copy / create
-- / move / label / remove), the hybrid Objects tab list, object tool loading,
-- and the Details panel for objects -- including mouse-click DELETE (the fix
-- for "can't delete from the details panel").

package.path = "../../../?.lua;" .. package.path

if not _G.love then _G.love = require("tests.love_stub") end

local Data = require("src.core.Data")
if not (Data.maps and Data.maps.PALLET_TOWN) then Data:load() end
local data = Data

local Session = require("mods.mapamap.domain.edit_session")
local Input = require("mods.mapamap.controllers.input")
local Inventory = require("mods.mapamap.components.inventory")
local Details = require("mods.mapamap.components.details")
local Panel = require("mods.mapamap.components.panel")
local Coords = require("mods.mapamap.engine.coords")

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
  Input.selectedObject = nil
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

local function freshSession()
  local s = assert(Session.new(mod, game, "PALLET_TOWN"))
  s.def.objects = {}
  s.def.warps = {}
  return s
end

function test_placeObjectCopyDeepCopiesAtCell()
  local s = freshSession()
  -- An existing object on the map establishes the index floor.
  local existing = s:placeNewObject(1, 1)
  local src = { x = 0, y = 0, sprite = "LASS", object_type = "NPC", index = 1 }
  local o = s:placeObjectCopy(3, 4, src)
  assert(o, "copy placement returns the new object")
  assert(o ~= src and o ~= existing, "the copy is a distinct object record")
  assert(o.x == 3 and o.y == 4, "copy lands at the requested cell")
  assert(o.sprite == "LASS" and o.object_type == "NPC", "copy carries the source fields")
  assert(o.index == existing.index + 1, "copy gets a fresh index above the max")
  assert(#s.def.objects == 2, "the copy joins the map without replacing anything")
  assert(s:objectAt(3, 4) == o, "object is wired at the cell")
end

function test_placeObjectCopyRejectsBadSample()
  local s = freshSession()
  assert(s:placeObjectCopy(1, 1, nil) == nil, "no sample is rejected")
  assert(s:placeObjectCopy(1, 1, { x = 0, y = 0 }) == nil,
    "sample without object_type is rejected")
  assert(#s.def.objects == 0, "nothing placed for rejected copies")
end

function test_placeNewObjectCreatesVisibleNpc()
  local s = freshSession()
  local o = s:placeNewObject(2, 2)
  assert(o, "new object placement succeeds")
  assert(o.object_type == "NPC", "new objects are simple NPCs")
  assert(o.sprite and data.sprites[o.sprite], "new object renders with a real sprite")
  assert(o.label == "New Object", "new objects get an editable default label")
  assert(s:objectAt(2, 2) == o, "new object wired at the cell")
end

function test_objectName()
  local s = freshSession()
  local item = s:placeObjectCopy(0, 0, { x = 0, y = 0, object_type = "item", item = "POTION" })
  assert(s:objectName(item) == "POTION", "item objects name from their item id")
  local npc = s:placeObjectCopy(1, 0, { x = 0, y = 0, sprite = "LASS", object_type = "NPC" })
  assert(s:objectName(npc) == "LASS", "NPC objects name from their sprite id")
  assert(s:setObjectLabel(npc, "Mom"), "label set succeeds")
  assert(s:objectName(npc) == "Mom", "labels win the display name")
end

function test_moveAndRemoveObject()
  local s = freshSession()
  local o = s:placeNewObject(5, 5)
  assert(s:moveObject(o, 6, 7), "move succeeds")
  assert(o.x == 6 and o.y == 7, "object lands on the new cell")
  assert(s:objectAt(5, 5) == nil and s:objectAt(6, 7) == o, "object moved cells")
  assert(s:moveObject(o, -1, 0) == false, "out of bounds move is rejected")
  assert(o.x == 6 and o.y == 7, "rejected move leaves the object put")
  assert(s:removeObject(o), "remove succeeds")
  assert(#s.def.objects == 0, "object removed from the array")
  assert(s:removeObject(o) == false, "double removal is a no-op")
end

function test_objectCellLoadsCopyTool()
  local s = freshSession()
  local o = s:placeNewObject(1, 1)
  resetInput()
  Input.inventory = { items = { { kind = "entity", entityType = "object", obj = o } }, tab = 2, scroll = 1 }
  local cx, cy = inventoryCellCentre(1)
  assert(Input.mousepressed(s, game, cx, cy, 1), "click on a saved object cell is consumed")
  local item = Input.hotbar[1]
  assert(item and item.kind == "entity" and item.entityType == "object"
    and item.obj == o, "saved object cell loads a copy tool")
  assert(s.selectedItem == o, "loading an object tool selects it")
end

function test_creatorToolCellKeepsCreatePayload()
  local s = freshSession()
  resetInput()
  -- This test places real entities on the SHARED map def; clear signs too
  -- and restore them so nothing leaks into later tests.
  local savedSigns = s.def.signs
  s.def.signs = {}
  -- A creator-made NPC tool stored by CREATE carries a `create` spec and no
  -- live obj; loading it must keep the spec intact (rebuilding it as a copy
  -- tool drops the payload and nothing can be placed).
  local spriteId = next(data.sprites)
  Input.inventory = { items = {
    { kind = "entity", entityType = "object",
      create = { objectType = "npc", sprite = spriteId,
                 movement = "STAY", range = "DOWN", label = "Cloner" } },
    { kind = "entity", entityType = "sign",
      create = { text = "...", label = "Signpost" } },
  }, tab = 2, scroll = 1 }
  local cx, cy = inventoryCellCentre(1)
  assert(Input.mousepressed(s, game, cx, cy, 1), "creator cell click is consumed")
  local npcTool = Input.hotbar[1]
  assert(npcTool and npcTool.create and npcTool.create.objectType == "npc",
    "loading a creator NPC tool keeps its create spec")
  assert(s:placeObjectSpec(2, 2, npcTool.create),
    "the loaded create spec places an NPC")
  -- The sign creator tool loads the same way (into the second slot).
  Input.selected = 2
  Input.inventory = { items = {
    { kind = "entity", entityType = "sign",
      create = { text = "...", label = "Signpost" } },
  }, tab = 2, scroll = 1 }
  local sx, sy = inventoryCellCentre(1)
  assert(Input.mousepressed(s, game, sx, sy, 1), "creator sign cell click is consumed")
  local signTool = Input.hotbar[2]
  assert(signTool and signTool.create and signTool.entityType == "sign",
    "loading a creator sign tool keeps its create spec")
  assert(s:placeSignSpec(3, 3, signTool.create),
    "the loaded create spec places a sign")
  -- Leave no entities behind on the shared def.
  s.def.objects = {}
  s.def.signs = savedSigns
end

function test_objectTemplateCellLoadsNewTool()
  local s = freshSession()
  resetInput()
  -- Templates are gone; each tab leads with its own toolbar shortcut and
  -- nothing arms a tool.
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

function test_inventoryRmbOnObjectOpensDetails()
  local s = freshSession()
  local o = s:placeNewObject(1, 1)
  resetInput()
  Input.inventory = { items = { { kind = "entity", entityType = "object", obj = o } }, tab = 2, scroll = 1 }
  local cx, cy = inventoryCellCentre(1)
  assert(Input.mousepressed(s, game, cx, cy, 2), "RMB on an object cell is consumed")
  assert(Input.details and Input.details.target and Input.details.target.entity == o, "RMB opens Details for the object")
end

function test_detailsObjectBuildFields()
  local s = freshSession()
  local o = s:placeNewObject(2, 3)
  Input.openDetails(s, { entity = o, entityType = "object" })
  local d = Input.details
  local keys, types = {}, {}
  for _, f in ipairs(d.fields) do keys[#keys + 1] = f.key; types[f.key] = f.type end
  assert(keys[1] == "type" and types.type == "readonly", "Type row is readonly")
  assert(keys[2] == "name" and types.name == "text", "Name row is editable")
  assert(keys[3] == "movement" and types.movement == "choice",
    "Walks row is a choice")
  assert(keys[4] == "range" and types.range == "choice",
    "Facing row is a choice")
  assert(keys[5] == "text" and types.text == "text", "Dialog row is editable")
  assert(keys[6] == "pos" and types.pos == "readonly", "Pos row is readonly")
  assert(#keys == 6, "object has 6 field rows (no inline DELETE)")
  -- Choice vocabularies ride on the rows.
  for _, f in ipairs(d.fields) do
    if f.type == "choice" then
      assert(f.choices and #f.choices > 0, "choice row carries its vocabulary")
    end
  end
end

function test_detailsObjectChoiceCycling()
  local s = freshSession()
  local o = s:placeNewObject(1, 1)
  Input.openDetails(s, { entity = o, entityType = "object" })
  local d = Input.details
  -- Row 3 is movement; cycle forward STAY -> WALK.
  d.index = 3
  Input.keypressed(s, "right")
  assert(o.movement == "WALK", "cycling right switches movement to WALK")
  assert(o.range == "ANY_DIR", "switching movement coerces the range")
  -- The rebuilt fields keep a choice on the range row with WALK vocabulary.
  assert(d.fields[d.index].key == "movement", "row stays selected after rebuild")
  assert(#d.fields[4].choices == 3, "range vocabulary follows the movement")
  -- Cycle back left twice wraps to STAY.
  Input.keypressed(s, "left")
  Input.keypressed(s, "left")
  assert(o.movement == "STAY", "cycling wraps around to STAY")
  assert(o.range == "DOWN", "wrapping back re-coerces the range")
end

function test_detailsObjectKeyboardDelete()
  local s = freshSession()
  local o = s:placeNewObject(1, 1)
  Input.openDetails(s, { entity = o, entityType = "object" })
  assert(Input.details and Input.details.entity == o, "object details open")
  assert(Input.keypressed(s, "x"), "X deletes the target")
  assert(#s.def.objects == 0, "object removed from the map")
  assert(Input.details == nil, "Details closes after delete")
end

function test_detailsObjectDeleteByMouseClick()
  local s = freshSession()
  local o = s:placeNewObject(1, 1)
  Input.openDetails(s, { entity = o, entityType = "object" })
  Input.details.index = 1
  local n = #Input.details.fields
  assert(n == 6, "object details lists 6 rows")
  -- Click the REMOVE button in the bottom strip (button index 3).
  local bx, by, bw, bh = Details.buttonRectAt(Input.details, 3, VW, VH)
  assert(bx, "REMOVE button rect exists")
  assert(Input.mousepressed(s, game, bx + bw / 2, by + bh / 2, 1),
    "click on the REMOVE button is consumed")
  assert(#s.def.objects == 0, "mouse-click REMOVE removes the object")
  assert(Input.details == nil, "Details closes after the click-remove")
  -- A click on a non-action row must NOT delete.
  s:placeNewObject(3, 3)
  Input.openDetails(s, { entity = s.def.objects[1], entityType = "object" })
  local rowY = select(2, Details.rect(VW, VH)) + Panel.PAD + 20
  local px = select(1, Details.rect(VW, VH))
  assert(Input.mousepressed(s, game, px + Panel.PAD, rowY, 1),
    "click on the first row is consumed")
  assert(#s.def.objects == 1, "clicking a text/readonly row does not delete")
end

function test_detailsObjectKeyboardEditName()
  local s = freshSession()
  local o = s:placeNewObject(1, 1)
  Input.openDetails(s, { entity = o, entityType = "object" })
  local d = Input.details
  d.index = 2 -- Name
  assert(Input.keypressed(s, "return"), "Enter starts the text edit")
  assert(d.editing and d.editing.fieldIdx == 2 and d.editing.buf == "New Object",
    "edit buffer primed with the current value")
  for c in (("Giga"):gmatch(".")) do Input.keypressed(s, c) end
  assert(Input.keypressed(s, "return"), "Enter commits")
  assert(o.label == "New ObjectGiga", "typed characters append to the object label")
end

function test_detailsItemDelete()
  local s = freshSession()
  resetInput()
  local it = { kind = "sprite", id = "LASS" }
  Input.inventory = { items = { it }, tab = 2, scroll = 1 }
  Input.openDetails(s, { item = it })
  assert(Input.details and Input.details.item == it, "item details open")
  assert(Input.keypressed(s, "x"), "X deletes the inventory item")
  assert(#Input.inventory.items == 0, "item removed from the inventory")
  assert(Input.details == nil, "Details closes after delete")
end

function test_detailsWarpDeleteByMouseClick()
  local s = freshSession()
  local w = s:placeWarp(1, 1)
  Input.openDetails(s, { entity = w, entityType = "warp" })
  local n = #Input.details.fields
  assert(n == 4, "warp details lists 4 rows")
  -- Click the REMOVE button in the bottom strip (button index 3).
  local bx, by, bw, bh = Details.buttonRectAt(Input.details, 3, VW, VH)
  assert(bx, "REMOVE button rect exists")
  assert(Input.mousepressed(s, game, bx + bw / 2, by + bh / 2, 1),
    "click on the REMOVE button is consumed")
  assert(#s.def.warps == 0, "warp removed by mouse click")
end

function test_objectToolClearsBlockBrush()
  local s = freshSession()
  resetInput()
  Input.hotbar[1] = { kind = "block", id = 3 }
  Input.applySelection(s)
  Input.hotbar[1] = { kind = "entity", entityType = "object",
    obj = { x = 0, y = 0, object_type = "NPC", sprite = "LASS" } }
  Input.applySelection(s)
  assert(s.selectedSprite == nil and s.selectedBlock == nil,
    "an object tool must not map to a block/sprite brush")
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

function test_undoRedoObjectViaKeyboard()
  local s = freshSession()
  resetInput()
  -- A creator-built NPC tool (create payload), like the F factory produces.
  local sprite = assert(next(data.sprites), "fixture data has sprites")
  Input.hotbar[1] = { kind = "entity", entityType = "object",
    create = { objectType = "npc", sprite = sprite } }
  Input.selected = 1
  local restore = stubTransform()
  Input.reset()
  assert(Input.paintAt(s, 16 * 4 + 8, 16 * 5 + 8), "object tool paint succeeds")
  restore()
  assert(#s.def.objects == 1, "one object placed")
  local orig = _G.love.keyboard.isDown
  _G.love.keyboard.isDown = function() return true end
  assert(Input.keypressed(s, "z"), "Ctrl+Z triggers undo")
  assert(#s.def.objects == 0, "undo removes the placed object")
  assert(s:objectAt(4, 5) == nil, "undo clears the object cell")
  assert(Input.keypressed(s, "y"), "Ctrl+Y triggers redo")
  assert(#s.def.objects == 1, "redo restores the object")
  assert(s:objectAt(4, 5) ~= nil, "redo rewires the object cell")
  _G.love.keyboard.isDown = orig
end

function test_paintedBlocksUniqueCellTools()
  local s = freshSession()
  s.def.blocks = { 0, 1, 0, 2, 1 }
  local cells = s:paintedBlocks()
  assert(#cells == 3, "one placement tool per unique painted id")
  assert(cells[1].kind == "block" and cells[1].id == 0
    and cells[1].tileset == s.tileset.id, "native id maps as a native tool")
  assert(cells[2].id == 1 and cells[3].id == 2, "the rest follow paint order")
end

function test_paintedBlocksResolvesGrafts()
  local s = freshSession()
  local native = #s.tileset.blocks
  s.def.graftBlocks = { { srcTileset = "TS_B", srcBlock = 3, tiles = {} } }
  s.def.blocks = { 0, 1, native + 1 }
  local cells = s:paintedBlocks()
  assert(#cells == 3, "native + one grafted id")
  local grafted
  for _, c in ipairs(cells) do
    if c.srcTileset then grafted = c end
  end
  assert(grafted and grafted.kind == "block" and grafted.id == 3
    and grafted.srcTileset == "TS_B",
    "grafted ids resolve to their source tileset + source block")
end

function test_tabListObjectsShowsOnlySavedItems()
  local s = freshSession()
  resetInput()
  s:placeNewObject(2, 2)
  Input.inventory = { items = { { kind = "sprite", id = "LASS" } }, tab = 2, scroll = 1 }
  local list = Input.inventoryList(s)
  assert(#list == 1 and list[1].kind == "sprite" and list[1].id == "LASS",
    "live objects are not mixed into the inventory object tab")
end

-- Right-clicking an entity on ANOTHER laid-out map opens read-only Details:
-- the hover markers are neighbor-aware, so the pick must be too.
function test_rmbNeighborEntityOpensReadOnlyDetails()
  local s = freshSession()
  resetInput()
  local east = { width = 2, height = 2, tileset = s.def.tileset,
    blocks = { 1, 1, 1, 1 },
    objects = { { x = 0, y = 0, sprite = "LASS", index = 1 } } }
  s.neighbors = { { id = "EAST", def = east, ox = s.def.width * 32, oy = 0 } }
  local realTransform = Coords.transform
  Coords.transform = function()
    return { camx = 0, camy = 0, sx = 1, sy = 1, wox = 0, woy = 0 }
  end
  -- The first cell of the neighbor (its local 0,0) sits just past the root's
  -- east edge.
  local wx = s.def.width * 2 * 16 + 8
  assert(Input.mousepressed(s, game, wx, 8, 2),
    "RMB on a neighbor entity is consumed")
  assert(Input.mousereleased(s, wx, 8, 2), "release consumed")
  Coords.transform = realTransform
  assert(Input.details ~= nil, "RMB opens Details for the neighbor entity")
  assert(Input.details.readOnly, "the panel is read-only")
  Input.keypressed(s, "x")
  assert(#east.objects == 1, "read-only delete leaves the other map intact")
  Input.keypressed(s, "escape")
  assert(Input.details == nil, "Escape closes it")
end

function test_lmbNeighborEntityPicksUpCopy()
  local s = freshSession()
  resetInput()
  local eastObj = { x = 0, y = 0, sprite = "LASS", index = 1,
    object_type = "NPC" }
  local east = { width = 2, height = 2, tileset = s.def.tileset,
    blocks = { 1, 1, 1, 1 }, objects = { eastObj } }
  s.neighbors = { { id = "EAST", def = east, ox = s.def.width * 32, oy = 0 } }
  local realTransform = Coords.transform
  Coords.transform = function()
    return { camx = 0, camy = 0, sx = 1, sy = 1, wox = 0, woy = 0 }
  end
  local wx = s.def.width * 2 * 16 + 8
  Input.mousepressed(s, game, wx, 8, 1)
  Coords.transform = realTransform
  local tool = Input.hotbar[Input.selected]
  assert(tool and tool.kind == "entity" and tool.entityType == "object"
    and tool.obj == eastObj, "LMB picks up the neighbor entity as a tool")
end

return {
  name = "MAPAMAP_OBJECT",
  tests = {
    "test_placeObjectCopyDeepCopiesAtCell",
    "test_placeObjectCopyRejectsBadSample",
    "test_placeNewObjectCreatesVisibleNpc",
    "test_objectName",
    "test_moveAndRemoveObject",
    "test_objectCellLoadsCopyTool",
    "test_creatorToolCellKeepsCreatePayload",
    "test_objectTemplateCellLoadsNewTool",
    "test_rmbNeighborEntityOpensReadOnlyDetails",
    "test_lmbNeighborEntityPicksUpCopy",
    "test_inventoryRmbOnObjectOpensDetails",
    "test_detailsObjectBuildFields",
    "test_detailsObjectKeyboardDelete",
    "test_detailsObjectDeleteByMouseClick",
    "test_detailsObjectKeyboardEditName",
    "test_detailsItemDelete",
    "test_detailsWarpDeleteByMouseClick",
    "test_objectToolClearsBlockBrush",
    "test_undoRedoObjectViaKeyboard",
    "test_paintedBlocksUniqueCellTools",
    "test_paintedBlocksResolvesGrafts",
    "test_tabListObjectsShowsOnlySavedItems",
  },
}
