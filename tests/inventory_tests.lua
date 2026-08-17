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
local MapOps = require("mods.mapamap.func.map_ops")

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

-- Font stub with a width method (glyphs are 8px each, matching the nil-font
-- fallback) so button sizes are deterministic in tests.
local fakeFont = { width = function(str) return #str * 8 end }

function test_tabRectTextFit()
  local x1, _, w1, _ = Inventory.tabRect(VW, VH, 1, fakeFont)
  local x2, _, w2, _ = Inventory.tabRect(VW, VH, 2, fakeFont)
  local x3, _, w3, _ = Inventory.tabRect(VW, VH, 3, fakeFont)
  local x4, _, w4, _ = Inventory.tabRect(VW, VH, 4, fakeFont)
  assert(w2 > w1, "Objects is wider than Tiles")
  assert(w3 == w1, "Warps and Tiles are the same length")
  assert(w4 > w2, "Blueprints is the widest tab")
  assert(x2 == x1 + w1 + Inventory.TAB_GAP, "tab 2 starts one gap after tab 1")
  assert(x3 == x2 + w2 + Inventory.TAB_GAP, "tab 3 starts one gap after tab 2")
  assert(x4 > x3 + w3, "tab 4 starts after tab 3")
  -- Hit-testing agrees with the per-text rects.
  local px, py = Inventory.rect(VW, VH)
  local ty = py + Inventory.PAD + Inventory.TAB_H / 2
  assert(Inventory.tabAt(VW, VH, x4 + w4 / 2, ty, fakeFont) == 4,
    "Blueprints hit-tests inside its own button")
  assert(Inventory.tabAt(VW, VH, x2 + w2 + Inventory.TAB_GAP / 2, ty, fakeFont) == nil,
    "the gap between tabs hit-tests as nothing")
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

function test_tabListShowsOnlySavedItems()
  local s = assert(Session.new(mod, game, "PALLET_TOWN"))
  resetInput()
  s.def.blocks = { 5, 5, 5, 0 }
  Input.inventory = { items = {
    { kind = "block", id = 7 }, { kind = "block", id = 8 },
  }, tab = 1, scroll = 1 }
  local list = Input.inventoryList(s)
  assert(list[1].kind == "block" and list[1].id == 7,
    "the saved collection is shown")
  assert(list[1].tileset == nil, "saved tile has no tileset tag")
  assert(#list == 2 and list[2].id == 8,
    "current-map tiles are not mixed into inventory")
end

function test_tabListEmptyWhenNoSavedItems()
  local s = assert(Session.new(mod, game, "PALLET_TOWN"))
  resetInput()
  s.def.blocks = { 3, 3 }
  Input.inventory = { items = {}, tab = 1, scroll = 1 }
  assert(#Input.inventoryList(s) == 0,
    "live current-map tiles do not populate inventory")
end

function test_inventoryCellLoadsIntoActiveSlot()
  local s = Session.new(mod, game, "PALLET_TOWN")
  assert(s, "no session")
  resetInput()
  Input.hotbar[1] = { kind = "block", id = 1 }
  Input.inventory = { items = { { kind = "block", id = 7 } }, tab = 1, scroll = 1 }
  -- The stored item sits in the saved inventory grid; click its actual cell.
  local target = nil
  for i, cell in ipairs(Input.inventoryList(s)) do
    if cell == Input.inventory.items[1] then target = i break end
  end
  assert(target, "stored item should appear in the tab list")
  local per = Inventory.perPage(VW, VH)
  Input.inventory.scroll = math.floor((target - 1) / per) + 1
  local onPage = target - (Input.inventory.scroll - 1) * per
  local cx, cy = inventoryCellCentre(onPage)
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

function test_hotbarDragSwapsSlots()
  local s = assert(Session.new(mod, game, "PALLET_TOWN"))
  assert(s, "no session")
  resetInput()
  Input.hotbar[1] = { kind = "block", id = 1 }
  Input.hotbar[2] = { kind = "block", id = 2 }
  Input.selected = 1
  local x1, y1, w1, _ = Hotbar.slot(1, VW, VH)
  local x2, y2, w2, _ = Hotbar.slot(2, VW, VH)
  local consumed = Input.mousepressed(s, game, x1 + w1 / 2, y1 + w1 / 2, 1)
  assert(consumed, "press on a filled hotbar slot is consumed")
  assert(Input.dragItem == Input.hotbar[1] and Input.dragFromSlot == 1,
    "press on a filled slot arms a drag from that slot")
  local released = Input.mousereleased(s, x2 + w2 / 2, y2 + w2 / 2, 1)
  assert(released, "release over another slot is consumed")
  assert(Input.hotbar[1].id == 2 and Input.hotbar[2].id == 1,
    "the two slots swap so nothing is lost")
  assert(Input.selected == 2, "selection moves to the drop slot")
  assert(Input.dragItem == nil and Input.dragFromSlot == nil,
    "drag state clears after the swap")
end

function test_hotbarDragAddsCopyToInventory()
  local s = assert(Session.new(mod, game, "PALLET_TOWN"))
  assert(s, "no session")
  resetInput()
  Input.hotbar[1] = { kind = "block", id = 3 }
  Input.selected = 1
  local x1, y1, w1, _ = Hotbar.slot(1, VW, VH)
  Input.mousepressed(s, game, x1 + w1 / 2, y1 + w1 / 2, 1)
  assert(Input.dragItem and Input.dragFromSlot == 1, "drag armed from slot 1")
  local cx, cy = inventoryCellCentre(1)
  local released = Input.mousereleased(s, cx, cy, 1)
  assert(released, "release over the inventory panel is consumed")
  assert(#Input.inventory.items == 1 and Input.inventory.items[1].id == 3,
    "dragged hotbar item joins the inventory")
  assert(Input.hotbar[1] and Input.hotbar[1].id == 3,
    "the hotbar copy stays in its slot")
  assert(Input.dragItem == nil and Input.dragFromSlot == nil,
    "drag state clears after the drop")
end

function test_cancelClearsHotbarDrag()
  local s = assert(Session.new(mod, game, "PALLET_TOWN"))
  assert(s, "no session")
  resetInput()
  Input.hotbar[1] = { kind = "block", id = 4 }
  Input.selected = 1
  local x1, y1, w1, _ = Hotbar.slot(1, VW, VH)
  Input.mousepressed(s, game, x1 + w1 / 2, y1 + w1 / 2, 1)
  assert(Input.dragItem and Input.dragFromSlot == 1, "drag armed before the cancel")
  Input.cancelled()
  assert(Input.dragItem == nil and Input.dragFromSlot == nil,
    "a cancelled pointer retires the drag so nothing waits for a release")
end

function test_lostReleaseOutsideUiClearsDrag()
  local s = assert(Session.new(mod, game, "PALLET_TOWN"))
  assert(s, "no session")
  resetInput()
  Input.hotbar[1] = { kind = "block", id = 5 }
  Input.selected = 1
  local x1, y1, w1, _ = Hotbar.slot(1, VW, VH)
  Input.mousepressed(s, game, x1 + w1 / 2, y1 + w1 / 2, 1)
  assert(Input.dragItem and Input.dragFromSlot == 1, "drag is armed on press")

  local wasDown = love.mouse.isDown
  love.mouse.isDown = function() return false end
  Input.mousemoved(s, 0, 0)
  love.mouse.isDown = wasDown

  assert(Input.dragItem == nil and Input.dragFromSlot == nil,
    "a physical release outside the UI clears the drag even without a release event")
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
  -- Clamps at the last page: keep scrolling must not overflow.  The list
  -- measure the real saved-item list.
  local list = Input.inventoryList(s)
  local max = math.ceil(#list / per)
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

function test_blueprintCaptureCanSpanVisibleMaps()
  resetInput()
  local root = { width = 2, height = 1, tileset = "TS_A", blocks = { 1, 2 } }
  local east = { width = 2, height = 1, tileset = "TS_A", blocks = { 3, 4 } }
  local session = {
    def = root,
    neighbors = { { id = "EAST", def = east, ox = 64, oy = 0 } },
  }
  Input.selectStart = { bx = 1, by = 0 }
  Input.selectEnd = { bx = 2, by = 0 }
  local id = Input.captureBlueprint(session)
  assert(id, "capture should produce a blueprint")
  local bp = Input.inventory.items[1]
  assert(bp and bp.kind == "blueprint" and bp.w == 2 and bp.h == 1,
    "captured blueprint keeps the world-block rectangle")
  assert(bp.tiles[1].id == 2 and bp.tiles[1].tileset == "TS_A"
    and bp.tiles[2].id == 3 and bp.tiles[2].tileset == "TS_A",
    "capture reads from root then visible neighbor across the seam")
end

function test_blueprintPaintCanSpanVisibleMaps()
  local root = { width = 2, height = 1, blocks = { 0, 0 } }
  local east = { width = 2, height = 1, blocks = { 0, 0 } }
  local rebuilt = { root = 0, east = 0 }
  local session = {
    def = root,
    neighbors = { { id = "EAST", def = east, ox = 64, oy = 0 } },
    neighborMaps = { EAST = { renderer = { rebuild = function() rebuilt.east = rebuilt.east + 1 end } } },
    neighborDirty = {},
    map = { renderer = { rebuild = function() rebuilt.root = rebuilt.root + 1 end } },
    cursorBx = 2,
    cursorBy = 0,
  }
  local changed = MapOps.paintBlueprint(session, { w = 2, h = 1, tiles = { 7, 8 } })
  assert(changed, "stamp should change visible map cells")
  assert(root.blocks[2] == 7 and east.blocks[1] == 8,
    "stamp writes root and neighbor cells according to world-block placement")
  assert(session.neighborDirty.EAST == true, "neighbor stamp is marked dirty")
  assert(rebuilt.root > 0 and rebuilt.east > 0, "touched renderers are rebuilt")
end

function test_tabToggleHidesAndShowsInventory()
  local s = assert(Session.new(mod, game, "PALLET_TOWN"))
  assert(s, "no session")
  resetInput()
  assert(Input.showInventory == true, "inventory is visible by default")
  local consumed = Input.keypressed(s, "tab")
  assert(consumed, "TAB key should be consumed")
  assert(Input.showInventory == false, "TAB should hide the inventory")
  local consumed2 = Input.keypressed(s, "tab")
  assert(consumed2, "second TAB should be consumed")
  assert(Input.showInventory == true, "second TAB should show the inventory again")
end

function test_cursorOnlyActiveWhileMouseIsDown()
  local s = assert(Session.new(mod, game, "PALLET_TOWN"))
  assert(s, "no session")
  resetInput()
  assert(Input.mouseButtons[1] == false, "cursor state starts idle")
  Input.mousepressed(s, game, 10, 10, 1)
  assert(Input.mouseButtons[1] == true, "mouse press arms the cursor")
  Input.mousereleased(s, 10, 10, 1)
  assert(Input.mouseButtons[1] == false, "mouse release clears the cursor")
end

function test_stringMouseButtonsAreNormalized()
  local s = assert(Session.new(mod, game, "PALLET_TOWN"))
  assert(s, "no session")
  resetInput()
  Input.mousepressed(s, game, 10, 10, "left")
  assert(Input.mouseButtons[1] == true, "left button is normalized to 1")
  Input.mousereleased(s, 10, 10, "left")
  assert(Input.mouseButtons[1] == false, "release clears the normalized left button")
  Input.mousepressed(s, game, 10, 10, "right")
  assert(Input.mouseButtons[2] == true, "right button is normalized to 2")
end

function test_wheelOverWorldPassesThroughForGameZoom()
  local s = assert(Session.new(mod, game, "PALLET_TOWN"))
  assert(s, "no session")
  resetInput()
  local orig = love.mouse.getPosition
  _G.love.mouse.getPosition = function() return 540, 280 end
  local ok = Input.wheelmoved(s, 1)
  _G.love.mouse.getPosition = orig
  assert(ok == false, "wheel over the world should not consume the overlay scroll")
end

function test_blueprintDragCreatesBlueprintFromInputFlow()
  local s = assert(Session.new(mod, game, "PALLET_TOWN"))
  assert(s, "no session")
  resetInput()
  Input.blueprintMode = true
  local orig = Input.blockCellAt
  Input.blockCellAt = function() return 0, 0 end
  assert(Input.mousepressed(s, game, 1, 1, 1) == true,
    "press starts a blueprint selection")
  Input.blockCellAt = function() return 1, 1 end
  assert(Input.mousemoved(s, 1, 1) == true,
    "drag updates the blueprint selection")
  Input.blockCellAt = function() return 1, 1 end
  local id = Input.mousereleased(s, 1, 1, 1)
  Input.blockCellAt = orig
  assert(id == true, "release finishes the blueprint capture")
  assert(#Input.inventory.items > 0, "drag release should add a blueprint")
  assert(Input.inventory.tab == 4, "blueprints tab should be active after capture")
end

function test_blueprintTwoClickCreatesBlueprintAndClosesTool()
  local s = assert(Session.new(mod, game, "PALLET_TOWN"))
  assert(s, "no session")
  resetInput()
  Input.blueprintMode = true
  local orig = Input.blockCellAt
  Input.blockCellAt = function() return 0, 0 end
  assert(Input.mousepressed(s, game, 1, 1, 1) == true,
    "first click anchors the start corner")
  -- A release with no drag in between must NOT capture yet (waits for 2nd click).
  Input.blockCellAt = orig
  assert(Input.mousereleased(s, 1, 1, 1) == true,
    "release without a drag is still consumed")
  assert(#Input.inventory.items == 0, "no blueprint until the second click")
  assert(Input.blueprintMode == true, "the R tool stays open after the first click")
  Input.blockCellAt = function() return 1, 1 end
  local id = Input.mousepressed(s, game, 1, 1, 1)
  Input.blockCellAt = orig
  assert(id == true, "second click finishes the blueprint capture")
  assert(#Input.inventory.items > 0, "two-click capture should add a blueprint")
  assert(Input.blueprintMode == false,
    "the R tool should close after the second click")
end


return {
  name = "MAPAMAP_INVENTORY",
  tests = {
    "test_tab_itemKinds",
    "test_geometry_rows",
    "test_itemAt_cellGrid",
    "test_tabAt_fit",
    "test_tabRectTextFit",
    "test_listFor_filtersByTab",
    "test_tabListShowsOnlySavedItems",
    "test_tabListEmptyWhenNoSavedItems",
    "test_inventoryCellLoadsIntoActiveSlot",
    "test_tabClickSwitchesTab",
    "test_dragDropOntoInventoryAddsItem",
    "test_hotbarDragSwapsSlots",
    "test_hotbarDragAddsCopyToInventory",
    "test_cancelClearsHotbarDrag",
    "test_wheelScrollsInventoryPage",
    "test_blueprintCaptureAddsToInventory",
    "test_blueprintCaptureCanSpanVisibleMaps",
    "test_blueprintPaintCanSpanVisibleMaps",
    "test_tabToggleHidesAndShowsInventory",
    "test_cursorOnlyActiveWhileMouseIsDown",
    "test_stringMouseButtonsAreNormalized",
    "test_wheelOverWorldPassesThroughForGameZoom",
    "test_blueprintDragCreatesBlueprintFromInputFlow",
    "test_blueprintTwoClickCreatesBlueprintAndClosesTool",
  },
}
