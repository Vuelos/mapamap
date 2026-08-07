-- Hotbar assignment tests: a plain click on a picker cell or a blueprint book
-- cell replaces the currently-selected hotbar slot, and a press that lands on
-- a hotbar slot targets that slot (drag-drop to a slot also works).

package.path = "../../../?.lua;" .. package.path

if not _G.love then _G.love = require("tests.love_stub") end

local Data = require("src.core.Data")
if not (Data.maps and Data.maps.PALLET_TOWN) then Data:load() end
local data = Data

local Session = require("mods.mapamap.session")
local Input = require("mods.mapamap.input")
local Hotbar = require("mods.mapamap.components.hotbar")
local PickerM = require("mods.mapamap.components.picker")
local Bp = require("mods.mapamap.components.blueprints")

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
  Input.showBlueprints = false
  Input.pickerScroll = 1
  Input.pickerTilesetScroll = 1
  Input.dragItem = nil
  Input.blueprintScroll = 1
  Input.blueprints = {}
end

local VW, VH = 640, 576

-- Centre of picker item cell `i` (1-based) in the picker grid.
local function pickerCellCentre(i)
  local ix, iy, _, _ = PickerM.rect(VW, VH)
  local cols = PickerM.cols(VW)
  local gx = ix + PickerM.PAD + PickerM.LIST_W + PickerM.GAP
  local gy = iy + PickerM.HEAD_H + 6
  local ci = i - 1
  local col = ci % cols
  local row = math.floor(ci / cols)
  return gx + col * (PickerM.SLOT + PickerM.GAP) + PickerM.SLOT / 2,
         gy + row * (PickerM.SLOT + PickerM.GAP) + PickerM.SLOT / 2
end

-- Centre of blueprint slot i (1-based) in the book panel.
local function blueprintCellCentre(i)
  local px, py = Bp.rect(VW, VH)
  local x = px + Bp.PAD + (i - 1) * (Bp.SLOT + Bp.GAP) + Bp.SLOT / 2
  local y = py + Bp.HEAD + Bp.SLOT / 2
  return x, y
end

function test_pickerClickReplacesSelectedSlot()
  local s = Session.new(mod, game, "PALLET_TOWN")
  assert(s, "no session")
  resetInput()
  s:rebuildNeighbors()
  Input.showPicker = true
  Input.selected = 1
  Input.hotbar[1] = { kind = "block", id = 1 }
  -- Pick the second picker cell (a different block, or an item/NPC).
  local cx, cy = pickerCellCentre(2)
  local consumed = Input.mousepressed(s, game, cx, cy, 1)
  assert(consumed, "click on the picker grid should be consumed")
  assert(Input.hotbar[1] and Input.hotbar[1].kind == "block"
    and Input.hotbar[1].id ~= 1, "click should replace the selected slot 1")
  assert(Input.dragItem == nil, "a release-only click should clear the drag")
end

function test_blueprintClickReplacesSelectedSlot()
  local s = Session.new(mod, game, "PALLET_TOWN")
  assert(s, "no session")
  Input.reset()
  Input.showBlueprints = true
  Input.selected = 1
  Input.hotbar[1] = { kind = "block", id = 1 }
  Input.blueprints = { { id = "BP_TEST", w = 1, h = 1, tiles = { 0 } } }
  local cx, cy = blueprintCellCentre(1)
  local consumed = Input.mousepressed(s, game, cx, cy, 1)
  assert(consumed, "click on a blueprint cell should be consumed")
  assert(Input.hotbar[1] and Input.hotbar[1].kind == "blueprint"
    and Input.hotbar[1].id == "BP_TEST",
    "click should replace the selected slot with the blueprint")
end

function test_dragToHotbarTargetSlot()
  local s = Session.new(mod, game, "PALLET_TOWN")
  assert(s, "no session")
  Input.reset()
  Input.showPicker = true
  Input.selected = 1
  Input.hotbar[1] = { kind = "block", id = 1 }
  Input.hotbar[5] = { kind = "block", id = 2 }
  -- Press on a picker cell -> assigned to the selected slot (1) and drag armed.
  local cx, cy = pickerCellCentre(2)
  Input.mousepressed(s, game, cx, cy, 1)
  assert(Input.dragItem, "pressing a picker cell should arm a drag")
  local carried = Input.hotbar[1]
  -- Release over hotbar slot 5 -> moves there.
  local x, y, w, h = Hotbar.slot(5, VW, VH)
  Input.mousereleased(s, x + w / 2, y + h / 2, 1)
  assert(Input.hotbar[5] == carried, "release over slot 5 should drop the item there")
  assert(Input.dragItem == nil, "drag should clear on release")
end

return {
  name = "MAPAMAP_HOTBAR",
  tests = {
    "test_pickerClickReplacesSelectedSlot",
    "test_blueprintClickReplacesSelectedSlot",
    "test_dragToHotbarTargetSlot",
  },
}