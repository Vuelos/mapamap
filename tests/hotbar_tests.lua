-- Hotbar assignment tests: a plain click on a picker cell or an inventory
-- blueprint cell replaces the currently-selected hotbar slot, and a press that
-- lands on a hotbar slot targets that slot (drag-drop to a slot also works).

package.path = "../../../?.lua;" .. package.path

if not _G.love then _G.love = require("tests.love_stub") end

local Data = require("src.core.Data")
if not (Data.maps and Data.maps.PALLET_TOWN) then Data:load() end
local data = Data

local Session = require("mods.mapamap.domain.edit_session")
local Input = require("mods.mapamap.controllers.input")
local Hotbar = require("mods.mapamap.components.hotbar")
local PickerM = require("mods.mapamap.components.picker")
local Inventory = require("mods.mapamap.components.inventory")
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
  -- Pin the browsed catalog to nil (the current map's tileset) so picker-cell
  -- clicks always land on blocks regardless of what earlier suites left in
  -- the shared Input state (State.reset defaults People).
  Input.pickerTileset = nil
  Input.pickerTilesetScroll = 1
  Input.dragItem = nil
  Input.inventory = { items = {}, tab = 1, scroll = 1 }
end

local VW, VH = 640, 576

-- Centre of picker item cell `i` (1-based) in the picker grid.
local function pickerCellCentre(i)
  local ix, iy, _, _ = PickerM.rect(VW, VH)
  local cols = PickerM.cols(VW, VH)
  local gx = ix + Panel.PAD
  local gy = iy + PickerM.HEAD_H + 6
  local ci = i - 1
  local col = ci % cols
  local row = math.floor(ci / cols)
  return gx + col * (PickerM.SLOT + PickerM.GAP) + PickerM.SLOT / 2,
         gy + row * (PickerM.SLOT + PickerM.GAP) + PickerM.SLOT / 2
end

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

-- Esc NEVER closes the editor (F6 only): it dismisses the inventory surface
-- when open, and stays swallowed by the overlay otherwise.
function test_escapeClosesInventoryButNotTheEditor()
  local s = Session.new(mod, game, "PALLET_TOWN")
  assert(s, "no session")
  Input.reset()
  Input.showInventory = true
  assert(Input.keypressed(s, "escape"), "Esc is consumed by the overlay")
  assert(not Input.showInventory, "Esc closes the inventory")
  -- Esc with the inventory already closed is a no-op swallow.
  Input.showInventory = false
  assert(Input.keypressed(s, "escape"), "Esc stays consumed")
  assert(not Input.showInventory and not Input.showPicker,
    "Esc opens nothing when everything is closed")
  -- Restore the default surface state for later suites.
  Input.showInventory = true
end

function test_pickerClickReplacesSelectedSlot()
  local s = Session.new(mod, game, "PALLET_TOWN")
  assert(s, "no session")
  resetInput()
  s:rebuildNeighbors()
  Input.showPicker = true
  Input.selected = 1
  -- A sentinel far outside any real block id, so the replacement is unambiguous
  -- regardless of what PALLET_TOWN's tileset actually contains.
  Input.hotbar[1] = { kind = "block", id = 9000 }
  -- Pick the second picker cell (a different block, or an item/NPC).
  local cx, cy = pickerCellCentre(2)
  local consumed = Input.mousepressed(s, game, cx, cy, 1)
  assert(consumed, "click on the picker grid should be consumed")
  assert(Input.hotbar[1] and Input.hotbar[1].kind == "block"
    and Input.hotbar[1].id ~= 9000, "click should replace the selected slot 1")
  -- A press arms a drag (same as any picker cell); releasing over the same
  -- cell without dragging clears it.
  assert(Input.dragItem, "pressing a picker cell should arm a drag")
  local released = Input.mousereleased(s, cx, cy, 1)
  assert(released, "release over the picker should be consumed")
  assert(Input.dragItem == nil, "a dragless release should clear the drag")
end

function test_blueprintClickReplacesSelectedSlot()
  local s = Session.new(mod, game, "PALLET_TOWN")
  assert(s, "no session")
  Input.reset()
  Input.showInventory = true
  -- Blueprints live on tab 3 (Tiles / Entities / Blueprints / Brushes).
  Input.inventory = {
    items = { { kind = "blueprint", id = "BP_TEST", w = 1, h = 1, tiles = { 0 } } },
    tab = 3, scroll = 1,
  }
  Input.selected = 1
  Input.hotbar[1] = { kind = "block", id = 1 }
  local cx, cy = inventoryCellCentre(1)
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

function test_hotbarTagSurvivesMapEntryAndGraftsForeign()
  local s1 = assert(Session.new(mod, game, "PALLET_TOWN"))
  -- A second session must sit on a different tileset for the graft path to
  -- matter (OVERWORLD -> LAB).
  local s2 = assert(Session.new(mod, game, "FUCHSIA_MEETING_ROOM"))
  assert(s1.tileset.id ~= s2.tileset.id,
    "the two maps must use different tilesets (got " .. s1.tileset.id
      .. " vs " .. s2.tileset.id .. ")")
  resetInput()
  Input.hotbar[1] = { kind = "block", id = 0 }
  Input.selected = 1
  -- On session entry the block slot is locked to the map's tileset tag
  -- (replicates main.lua's slot-lock on open and the first applySelection).
  Input.tagBlock(s1, Input.hotbar[1])
  local tag = Input.hotbar[1].tileset
  assert(tag == s1.tileset.id, "block tagged to the entry map's tileset")
  -- Walk across the border: the tag must survive (onMapEntry is called from
  -- main.reconcileSession and must NOT re-seed the slot onto the new tileset).
  Input.onMapEntry(s2)
  assert(Input.hotbar[1].tileset == tag,
    "crossing a border must not re-tag the block onto the incoming tileset")
  -- applySelection (also called by reconcileSession) re-targets the foreign
  -- block through the graft layer: the selected id sits above the incoming
  -- tileset's native block space and equals the id the graft allocates.
  Input.applySelection(s2)
  assert(s2.selectedBlock ~= nil, "a block is selected on the incoming map")
  local gid = s2:importBlock(tag, 0)
  assert(gid ~= nil, "graft import succeeds for the tagged source")
  assert(s2.selectedBlock == gid,
    "selected block is the grafted id for the tagged tile")
  assert(s2.selectedBlock >= #s2.tileset.blocks,
    "grafted id sits above the incoming tileset's native block space")
  assert(s2._needsGraftRebuild,
    "graft layer is flagged for a rebuild after the import")
end

local function stubTransform()
  local Coords = require("mods.mapamap.engine.coords")
  local orig = Coords.transform
  Coords.transform = function()
    return { camx = 0, camy = 0, sx = 1, sy = 1, wox = 0, woy = 0 }
  end
  return function() Coords.transform = orig end
end

function test_taggedNativeBlockPaintsWithoutSelfGraft()
  local s = assert(Session.new(mod, game, "PALLET_TOWN"))
  resetInput()
  Input.hotbar[1] = { kind = "block", id = 1 }
  Input.selected = 1
  Input.tagBlock(s, Input.hotbar[1])
  assert(Input.hotbar[1].tileset == s.tileset.id, "slot is tagged to current tileset")
  local before = #(s.def.graftBlocks or {})
  local restore = stubTransform()
  assert(Input.paintAt(s, 8, 8), "paint succeeds")
  restore()
  assert(s.def.blocks[1] == 1, "native block id is painted directly")
  assert(#(s.def.graftBlocks or {}) == before, "painting a current-tileset block adds no graft")
end

function test_pickUnderVisibleNeighborKeepsTilesetTag()
  local root = { width = 2, height = 1, tileset = "TS_A", blocks = { 1, 2 } }
  local east = { width = 2, height = 1, tileset = "TS_B", blocks = { 5, 6 } }
  local session = {
    def = root,
    neighbors = { { id = "EAST", def = east, ox = 64, oy = 0 } },
  }
  local restore = stubTransform()
  local bid, tileset, mapId = Input.pickUnder(session, game, 64, 0, VW, VH)
  restore()
  assert(bid == 5, "pick reads the block under the cursor on the visible neighbor")
  assert(tileset == "TS_B" and mapId == "EAST",
    "pick returns the neighbor tileset tag for later grafting")
end

return {
  name = "MAPAMAP_HOTBAR",
  tests = {
    "test_escapeClosesInventoryButNotTheEditor",
    "test_pickerClickReplacesSelectedSlot",
    "test_blueprintClickReplacesSelectedSlot",
    "test_dragToHotbarTargetSlot",
    "test_hotbarTagSurvivesMapEntryAndGraftsForeign",
    "test_taggedNativeBlockPaintsWithoutSelfGraft",
    "test_pickUnderVisibleNeighborKeepsTilesetTag",
  },
}
