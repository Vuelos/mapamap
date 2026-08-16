-- Live Objects tab + Details tests: the session object helpers (copy / create
-- / move / label / remove), the hybrid Objects tab list, object tool loading,
-- and the Details panel for objects -- including mouse-click DELETE (the fix
-- for "can't delete from the details panel").

package.path = "../../../?.lua;" .. package.path

if not _G.love then _G.love = require("tests.love_stub") end

local Data = require("src.core.Data")
if not (Data.maps and Data.maps.PALLET_TOWN) then Data:load() end
local data = Data

local Session = require("mods.mapamap.session")
local Input = require("mods.mapamap.input")
local Inventory = require("mods.mapamap.components.inventory")
local Details = require("mods.mapamap.components.details")

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

local function inventoryCellCentre(i)
  local px, py = Inventory.rect(VW, VH)
  local ci = i - 1
  local col = ci % Inventory.COLS
  local row = math.floor(ci / Inventory.COLS)
  return px + Inventory.PAD + col * (Inventory.SLOT + Inventory.GAP) + Inventory.SLOT / 2,
         py + Inventory.PAD + Inventory.TAB_H + Inventory.GAP
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
  Input.inventory = { items = { { kind = "object", obj = o } }, tab = 2, scroll = 1 }
  local cx, cy = inventoryCellCentre(1)
  assert(Input.mousepressed(s, game, cx, cy, 1), "click on a saved object cell is consumed")
  local item = Input.hotbar[1]
  assert(item and item.kind == "object" and item.obj == o,
    "saved object cell loads a copy tool")
  assert(s.selectedObject == o, "loading an object tool selects it")
end

function test_objectTemplateCellLoadsNewTool()
  local s = freshSession()
  resetInput()
  Input.inventory = { items = { { kind = "object", newObject = true } }, tab = 2, scroll = 1 }
  local cx, cy = inventoryCellCentre(1)
  assert(Input.mousepressed(s, game, cx, cy, 1),
    "click on the saved new-object template is consumed")
  local item = Input.hotbar[1]
  assert(item and item.kind == "object" and item.newObject,
    "template cell arms the new-object tool")
end

function test_inventoryRmbOnObjectOpensDetails()
  local s = freshSession()
  local o = s:placeNewObject(1, 1)
  resetInput()
  Input.inventory = { items = { { kind = "object", obj = o } }, tab = 2, scroll = 1 }
  local cx, cy = inventoryCellCentre(1)
  assert(Input.mousepressed(s, game, cx, cy, 2), "RMB on an object cell is consumed")
  assert(Input.details and Input.details.object == o, "RMB opens Details for the object")
end

function test_detailsObjectBuildFields()
  local s = freshSession()
  local o = s:placeNewObject(2, 3)
  Input.openDetails(s, { object = o })
  local d = Input.details
  local keys, types = {}, {}
  for _, f in ipairs(d.fields) do keys[#keys + 1] = f.key; types[f.key] = f.type end
  assert(keys[1] == "type" and types.type == "readonly", "Type row is readonly")
  assert(keys[2] == "name" and types.name == "text", "Name row is editable")
  assert(keys[3] == "pos" and types.pos == "readonly", "Pos row is readonly")
  assert(keys[4] == "delete" and types.delete == "action", "DELETE action row")
end

function test_detailsObjectKeyboardDelete()
  local s = freshSession()
  local o = s:placeNewObject(1, 1)
  Input.openDetails(s, { object = o })
  assert(Input.details and Input.details.object == o, "object details open")
  assert(Input.keypressed(s, "x"), "X deletes the target")
  assert(#s.def.objects == 0, "object removed from the map")
  assert(Input.details == nil, "Details closes after delete")
end

function test_detailsObjectDeleteByMouseClick()
  local s = freshSession()
  local o = s:placeNewObject(1, 1)
  Input.openDetails(s, { object = o })
  Input.details.index = 1
  local n = #Input.details.fields
  assert(n == 4, "object details lists 4 rows")
  local px, py, pw, ph = Details.rect(VW, VH)
  local rowY = py + Details.PAD + 20
  local delY = rowY + (n - 1) * (Details.ROW_H + 6)
  assert(Input.mousepressed(s, game, px + pw / 2, delY, 1),
    "click on the DELETE row is consumed")
  assert(#s.def.objects == 0, "mouse-click DELETE removes the object")
  assert(Input.details == nil, "Details closes after the click-delete")
  -- A click on a non-action row must NOT delete.
  s:placeNewObject(3, 3)
  Input.openDetails(s, { object = s.def.objects[1] })
  assert(Input.mousepressed(s, game, px + pw / 2, rowY, 1),
    "click on the first row is consumed")
  assert(#s.def.objects == 1, "clicking a text/readonly row does not delete")
end

function test_detailsObjectKeyboardEditName()
  local s = freshSession()
  local o = s:placeNewObject(1, 1)
  Input.openDetails(s, { object = o })
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
  Input.openDetails(s, { warp = w })
  local n = #Input.details.fields
  assert(n == 5, "warp details lists 5 rows")
  local px, py, pw, ph = Details.rect(VW, VH)
  local rowY = py + Details.PAD + 20
  local delY = rowY + (n - 1) * (Details.ROW_H + 6)
  assert(Input.mousepressed(s, game, px + pw / 2, delY, 1),
    "click on the warp DELETE row is consumed")
  assert(#s.def.warps == 0, "warp removed by mouse click")
end

function test_objectToolClearsBlockBrush()
  local s = freshSession()
  resetInput()
  Input.hotbar[1] = { kind = "block", id = 3 }
  Input.applySelection(s)
  Input.hotbar[1] = { kind = "object", obj = { x = 0, y = 0, object_type = "NPC", sprite = "LASS" } }
  Input.applySelection(s)
  assert(s.selectedSprite == nil and s.selectedBlock == nil,
    "an object tool must not map to a block/sprite brush")
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

function test_undoRedoObjectViaKeyboard()
  local s = freshSession()
  resetInput()
  Input.hotbar[1] = { kind = "object", newObject = true }
  Input.selected = 1
  local restore = stubTransform()
  Input.reset()
  assert(Input.paintAt(s, 16 * 4 + 8, 16 * 5 + 8), "template paint succeeds")
  restore()
  assert(#s.def.objects == 1, "one object placed")
  Input.closeDetails() -- placing opens the Details panel; it must not eat Ctrl+Z
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

return {
  name = "MAPAMAP_OBJECT",
  tests = {
    "test_placeObjectCopyDeepCopiesAtCell",
    "test_placeObjectCopyRejectsBadSample",
    "test_placeNewObjectCreatesVisibleNpc",
    "test_objectName",
    "test_moveAndRemoveObject",
    "test_objectCellLoadsCopyTool",
    "test_objectTemplateCellLoadsNewTool",
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
