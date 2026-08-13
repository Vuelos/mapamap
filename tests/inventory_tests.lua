-- Inventory component tests: tab mounting by item kind, geometry hit-testing
-- (tabs + cells), pointer routing (click a cell loads it into the active
-- hotbar slot, tab click switches tab), drag-drop onto the panel, wheel
-- scroll, and blueprint captures surfacing in the Blueprints tab.

package.path = "../../../?.lua;" .. package.path

if not _G.love then _G.love = require("tests.love_stub") end

local Data = require("src.core.Data")
if not (Data.maps and Data.maps.PALLET_TOWN) then Data:load() end
local data = Data

local Session = require("mods.mapamap.session")
local Input = require("mods.mapamap.input")
local Hotbar = require("mods.mapamap.components.hotbar")
local Inventory = require("mods.mapamap.components.inventory")

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
  Input.inventory = { items = {}, tab = 1, scroll = 1 }
end

local VW, VH = 640, 576

-- Centre of inventory grid cell `i` (1-based) in the active tab's grid.
local function inventoryCellCentre(i)
  local px, py = Inventory.rect(VW, VH)
  local ci = i - 1
  local col = ci % Inventory.COLS
  local row = math.floor(ci / Inventory.COLS)
  return px + Inventory.PAD + col * (Inventory.SLOT + Inventory.GAP) + Inventory.SLOT / 2,
         py + Inventory.PAD + Inventory.TAB_H + Inventory.GAP
            + row * (Inventory.SLOT + Inventory.GAP) + Inventory.SLOT / 2
end

-- Centre of tab button `i` (1-based).
local function tabCentre(i)
  local x, y, w, h = Inventory.tabRect(VW, VH, i)
  return x + w / 2, y + h / 2
end

function test_tab_itemKinds()
  assert(Inventory.tabFor({ kind = "block" }) == 1, "blocks live in Tiles")
  assert(Inventory.tabFor({ kind = "sprite" }) == 2, "sprites live in Objects")
  assert(Inventory.tabFor({ kind = "item" }) == 2, "items live in Objects")
  assert(Inventory.tabFor({ kind = "warp" }) == 3, "warps live in Warps")
  assert(Inventory.tabFor({ kind = "blueprint" }) == 4, "blueprints live in Blueprints")
  assert(Inventory.tabFor({ kind = "bogus" }) == 2, "unknown kinds default to Objects")
end

function test_geometry_rows()
  local rows = Inventory.rows(VH)
  assert(rows >= 1, "at least one grid row")
  local px, py, pw, ph = Inventory.rect(VW, VH)
  -- The panel is on the left edge and stays above the hotbar band.
  assert(px < 30, "panel hugs the left edge")
  assert(py + ph <= VH - Hotbar.SLOT - Hotbar.PAD,
    "panel bottom must clear the hotbar")
  assert(pw > 0 and ph > 0, "panel has size")
end

function test_itemAt_cellGrid()
  local px, _ = Inventory.rect(VW, VH)
  assert(Inventory.itemAt(VW, VH, px + 4, 8, 1) == nil, "y before panel tab row is nil")
  -- First cell centre maps to slot 1 on page one.
  local cx, cy = inventoryCellCentre(1)
  assert(Inventory.itemAt(VW, VH, cx, cy, 1) == 1, "first cell is slot 1")
  -- Fifth horizontal position (col 4, row 0) maps past the list for 3 items
  -- but is still a valid grid slot (page-relative).
  local ix, iy = inventoryCellCentre(5)
  assert(Inventory.itemAt(VW, VH, ix, iy, 1) == 5, "col 4 maps to slot 5")
  -- Outside the panel entirely.
  local px, py, pw, ph = Inventory.rect(VW, VH)
  assert(Inventory.itemAt(VW, VH, px + pw + 4, py + 4, 1) == nil, "beyond the panel is nil")
end

function test_tabAt_fit()
  local x, y, _, _ = Inventory.rect(VW, VH)
  -- The tab row starts at py + PAD; the trim above it is panel padding.
  assert(Inventory.tabAt(VW, VH, x + 2, y + 2) == nil, "top padding sits above the tab row")
  assert(Inventory.tabAt(VW, VH, x + Inventory.PAD, y + Inventory.PAD) == 1,
    "first tab spans the tab-row origin")
  local tx, ty = tabCentre(3)
  assert(Inventory.tabAt(VW, VH, tx, ty) == 3, "third tab hit-tests")
  assert(Inventory.tabAt(VW, VH, tx, ty - 40) == nil, "above the tab row is nil")
end

function test_listFor_filtersByTab()
  local items = {
    { kind = "block", id = 1 },
    { kind = "sprite", id = "LASS" },
    { kind = "blueprint", id = "bp_1" },
  }
  local tiles = Inventory.listFor(items, 1)
  assert(#tiles == 1 and tiles[1].id == 1, "Tiles tab shows only blocks")
  local objects = Inventory.listFor(items, 2)
  assert(#objects == 1 and objects[1].id == "LASS", "Objects tab shows objects")
  local blueprints = Inventory.listFor(items, 4)
  assert(#blueprints == 1 and blueprints[1].id == "bp_1", "Blueprints tab shows blueprints")
end

function test_inventoryCellLoadsIntoActiveSlot()
  local s = Session.new(mod, game, "PALLET_TOWN")
  assert(s, "no session")
  resetInput()
  Input.hotbar[1] = { kind = "block", id = 1 }
  Input.inventory = { items = { { kind = "block", id = 7 } }, tab = 1, scroll = 1 }
  local cx, cy = inventoryCellCentre(1)
  local consumed = Input.mousepressed(s, game, cx, cy, 1)
  assert(consumed, "click on an inventory cell should be consumed")
  assert(Input.hotbar[1] and Input.hotbar[1].kind == "block"
    and Input.hotbar[1].id == 7, "click should load the inventory item into the slot")
  assert(Input.dragItem == nil, "plain inventory click should not arm a drag")
end

function test_tabClickSwitchesTab()
  local s = assert(Session.new(mod, game, "PALLET_TOWN"))
  assert(s, "no session")
  resetInput()
  Input.inventory = { items = {
    { kind = "block", id = 1 }, { kind = "warp", destMap = "PALLET_TOWN" },
  }, tab = 1, scroll = 1 }
  local tx, ty = tabCentre(3)
  local consumed = Input.mousepressed(s, game, tx, ty, 1)
  assert(consumed, "click on a tab should be consumed")
  assert(Input.inventory.tab == 3, "tab click should switch to the Warps tab")
end

function test_dragDropOntoInventoryAddsItem()
  local s = assert(Session.new(mod, game, "PALLET_TOWN"))
  assert(s, "no session")
  resetInput()
  Input.dragItem = { kind = "block", id = 9 }
  local cx, cy = inventoryCellCentre(1)
  local consumed = Input.mousereleased(s, cx, cy, 1)
  assert(consumed, "release over the inventory should be consumed")
  assert(#Input.inventory.items == 1, "released item should join the inventory")
  assert(Input.inventory.items[1].id == 9, "inventory holds the carried item")
  assert(Input.dragItem == nil, "drag cleared after release")
end

function test_wheelScrollsInventoryPage()
  local s = assert(Session.new(mod, game, "PALLET_TOWN"))
  assert(s, "no session")
  resetInput()
  local per = Inventory.perPage(VW, VH)
  Input.inventory.items = {}
  for i = 1, per + 3 do
    Input.inventory.items[i] = { kind = "block", id = i }
  end
  Input.inventory.tab = 1
  Input.inventory.scroll = 1
  local cx, cy = inventoryCellCentre(1)
  -- Replace mouse position to sit over the inventory for the wheel handler.
  local orig = love.mouse.getPosition
  _G.love.mouse.getPosition = function() return cx, cy end
  -- dy=+1 scrolls down through the list (page numbers increase).
  local ok = Input.wheelmoved(s, 1)
  _G.love.mouse.getPosition = orig
  assert(ok and Input.inventory.scroll > 1, "wheel over the panel scrolls a page")
  -- Clamps at the last page: keep scrolling must not overflow.
  local max = math.ceil(#Input.inventory.items / per)
  _G.love.mouse.getPosition = function() return cx, cy end
  Input.wheelmoved(s, 1)
  _G.love.mouse.getPosition = orig
  assert(Input.inventory.scroll == max, "scroll clamps at the last page")
  _G.love.mouse.getPosition = function() return cx, cy end
  local up = Input.wheelmoved(s, -1)
  _G.love.mouse.getPosition = orig
  assert(up and Input.inventory.scroll < max, "wheel up scrolls back")
end

function test_blueprintCaptureAddsToInventory()
  local s = assert(Session.new(mod, game, "PALLET_TOWN"))
  assert(s, "no session")
  resetInput()
  Input.selectStart = { bx = 0, by = 0 }
  Input.selectEnd = { bx = 1, by = 1 }
  local id = Input.captureBlueprint(s)
  assert(id, "capture should produce a blueprint")
  local bpItem = nil
  for _, it in ipairs(Input.inventory.items) do
    if it.kind == "blueprint" and it.id == id then bpItem = it end
  end
  assert(bpItem, "captured blueprint should surface in the inventory")
  assert(Input.inventory.tab == 4, "capture should switch to the Blueprints tab")
end

return {
  name = "MAPAMAP_INVENTORY",
  tests = {
    "test_tab_itemKinds",
    "test_geometry_rows",
    "test_itemAt_cellGrid",
    "test_tabAt_fit",
    "test_listFor_filtersByTab",
    "test_inventoryCellLoadsIntoActiveSlot",
    "test_tabClickSwitchesTab",
    "test_dragDropOntoInventoryAddsItem",
    "test_wheelScrollsInventoryPage",
    "test_blueprintCaptureAddsToInventory",
  },
}