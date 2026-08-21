-- Brush model + Brush Maker panel tests: position picking over the join-mask
-- space (edges, corners, inner corners, corridors, borderless line runs,
-- isolated), fallback resolution for sparse brushes, block membership
-- (native + grafted), world stamping with ring re-blending through
-- MapOps.paintBrush (including across a seam), and the panel's input flow
-- (click-assign from the hotbar, drag-drop, RMB clear/edit, save/clear).

package.path = "../../../?.lua;" .. package.path

if not _G.love then _G.love = require("tests.love_stub") end

local Brushes = require("mods.mapamap.domain.brushes")
local MapOps = require("mods.mapamap.domain.map_ops")
local Input = require("mods.mapamap.controllers.input")
local Inventory = require("mods.mapamap.components.inventory")
local BrushEditor = require("mods.mapamap.components.brush_editor")
local Panel = require("mods.mapamap.components.panel")

local VW, VH = 640, 576

local function blk(id)
  return { kind = "block", id = id }
end

local function reset()
  Input.showBrushEditor = false
  Input.brushDraft = Brushes.new("Brush")
  Input.dragItem = nil
  Input.dragFromSlot = nil
  Input.hotbar = {}
  Input.selected = 1
  Input.inventory = { items = {}, tab = 1, scroll = 1 }
  Input.mouseButtons = { [1] = false, [2] = false, [3] = false }
  Input.details = nil
  Input.encEditor = nil
end

-- Join-mask builder: keys of `joined` are present terrain.
local function mask(joined)
  local t = { n = false, s = false, e = false, w = false,
              nw = false, ne = false, sw = false, se = false }
  for k in pairs(joined or {}) do t[k] = true end
  return t
end

local FULL = { n = true, s = true, e = true, w = true,
               nw = true, ne = true, sw = true, se = true }

-- ---------------------------------------------------------------------------
-- Model: position picking

function test_pickKey_sides_corners_center()
  assert(Brushes.pickKey(mask()) == "o", "no joins -> isolated")
  -- Bordered edges: one side open, the other three joined.
  assert(Brushes.pickKey(mask({ s = true, w = true, e = true })) == "n")
  assert(Brushes.pickKey(mask({ n = true, w = true, e = true })) == "s")
  assert(Brushes.pickKey(mask({ n = true, s = true, e = true })) == "w")
  assert(Brushes.pickKey(mask({ n = true, s = true, w = true })) == "e")
  -- Outer corners: the key names the OPEN sides (where the rim shows).
  assert(Brushes.pickKey(mask({ n = true, w = true })) == "se")
  assert(Brushes.pickKey(mask({ n = true, e = true })) == "sw")
  assert(Brushes.pickKey(mask({ s = true, w = true })) == "ne")
  assert(Brushes.pickKey(mask({ s = true, e = true })) == "nw")
  assert(Brushes.pickKey(mask({ n = true, s = true })) == "v",
    "north+south joined, west/east open -> vertical corridor")
  assert(Brushes.pickKey(mask({ w = true, e = true })) == "h",
    "west+east joined, north/south open -> horizontal corridor")
  assert(Brushes.pickKey(mask(FULL)) == "c", "fully joined -> center")
end

function test_pickKey_endCaps()
  -- Exactly one joined side: the tile is the cap facing away from it.
  assert(Brushes.pickKey(mask({ n = true })) == "s")
  assert(Brushes.pickKey(mask({ s = true })) == "n")
  assert(Brushes.pickKey(mask({ w = true })) == "e")
  assert(Brushes.pickKey(mask({ e = true })) == "w")
end

function test_pickKey_innerCorners()
  assert(Brushes.pickKey(mask(FULL)) == "c")
  local m = mask(FULL); m.nw = false
  assert(Brushes.pickKey(m) == "i_nw")
  m = mask(FULL); m.ne = false
  assert(Brushes.pickKey(m) == "i_ne")
  m = mask(FULL); m.sw = false
  assert(Brushes.pickKey(m) == "i_sw")
  m = mask(FULL); m.se = false
  assert(Brushes.pickKey(m) == "i_se")
end

function test_pickKey_lineRuns()
  -- North edge continuing past BOTH ends -> borderless line tile.
  local m = mask(FULL); m.n = false
  assert(Brushes.pickKey(m) == "ln", "straight north run -> ln")
  m.nw = false
  assert(Brushes.pickKey(m) == "n", "broken west continuation -> bordered N")
  m = mask(FULL); m.s = false
  assert(Brushes.pickKey(m) == "ls")
  m.se = false
  assert(Brushes.pickKey(m) == "s")
  m = mask(FULL); m.w = false
  assert(Brushes.pickKey(m) == "lw")
  m.sw = false
  assert(Brushes.pickKey(m) == "w")
  m = mask(FULL); m.e = false
  assert(Brushes.pickKey(m) == "le")
  m.ne = false
  assert(Brushes.pickKey(m) == "e")
end

-- ---------------------------------------------------------------------------
-- Model: fallbacks, slots, cloning

function test_fallback_resolution()
  local b = Brushes.new()
  b.tiles.c = blk(1)
  local key, item = Brushes.resolve(b, "nw")
  assert(key == "c" and item.id == 1, "nw falls back through n to c")
  b.tiles.n = blk(2)
  local key2, item2 = Brushes.resolve(b, "nw")
  assert(key2 == "n" and item2.id == 2, "nw falls back to assigned n")
  assert(Brushes.resolve(b, "c") == "c", nil)
  local _, ci = Brushes.resolve(b, "c")
  assert(ci.id == 1)
end

function test_lineFallsBackToEdgeThenCenter()
  local b = Brushes.new()
  b.tiles.c = blk(1)
  b.tiles.n = blk(2)
  local m = mask(FULL); m.n = false
  assert(Brushes.tileFor(b, m).id == 2, "missing ln resolves to n")
  local m2 = mask()
  assert(Brushes.tileFor(b, m2).id == 1, "isolated resolves to c")
end

function test_slots_clone_complete()
  local b = Brushes.new("M")
  assert(not Brushes.isComplete(b), "no center yet")
  Brushes.setSlot(b, "c", blk(3))
  Brushes.setSlot(b, "nw", blk(4))
  assert(Brushes.isComplete(b) and Brushes.filled(b) == 2)
  Brushes.setSlot(b, "nw", nil)
  assert(Brushes.slot(b, "nw") == nil and Brushes.filled(b) == 1)
  local clone = Brushes.clone(b)
  clone.tiles.c.id = 99
  assert(Brushes.slot(b, "c").id == 3, "clone detaches from the original")
end

-- ---------------------------------------------------------------------------
-- Model: membership

function test_ownsBlock_nativeAndGrafted()
  local def = { tileset = "TS_A",
    graftBlocks = { { srcTileset = "TS_B", srcBlock = 9, tiles = {} } } }
  local native = 3
  local b = Brushes.new()
  b.tiles.c = blk(2)
  assert(Brushes.ownsBlock(b, def, native, 2) == true, "native id matches")
  assert(Brushes.ownsBlock(b, def, native, 1) == false, "other id does not")
  -- Graft i owns block id native + i, so graft 1 is id 4 here.
  local g = Brushes.new()
  g.tiles.c = { kind = "block", id = 9, srcTileset = "TS_B" }
  assert(Brushes.ownsBlock(g, def, native, 4) == true,
    "grafted id resolves back to its source block")
  assert(Brushes.ownsBlock(g, def, native, 2) == false,
    "the grafted slot does not claim native ids")
  -- An id above native with no graft entry was written verbatim.
  local v = Brushes.new()
  v.tiles.c = blk(7)
  assert(Brushes.ownsBlock(v, def, native, 7) == true,
    "verbatim-written ids match by raw id")
  local tagged = Brushes.new()
  tagged.tiles.c = { kind = "block", id = 2, srcTileset = "TS_B" }
  assert(Brushes.ownsBlock(tagged, def, native, 2) == false,
    "foreign-tagged slot must not claim another tileset's native id")
end

-- ---------------------------------------------------------------------------
-- World stamping (MapOps.paintBrush)

local function bidx(w, bx, by) return by * w + bx + 1 end

local function makeSession(w, h)
  w, h = w or 3, h or 3
  local root = { width = w, height = h, tileset = "TS_A", blocks = {} }
  for i = 1, w * h do root.blocks[i] = 0 end
  local rebuilt = { root = 0 }
  local s = {
    def = root,
    data = { tilesets = { TS_A = { id = "TS_A", blocks = { {}, {}, {} } } } },
    neighbors = {},
    neighborMaps = {},
    neighborDirty = {},
    map = { renderer = {
      rebuild = function() rebuilt.root = rebuilt.root + 1 end } },
    refreshLiveRenderers = function() end,
    undo = { captures = {}, capture = function(self, def, l, t, mapId, idx)
      self.captures[#self.captures + 1] =
        { def = def, mapId = mapId, n = idx and #idx or 0 }
    end },
    _rebuilt = rebuilt,
  }
  return s
end

local function mountainBrush()
  local b = Brushes.new("Mountain")
  b.tiles.c = blk(5)
  b.tiles.n = blk(6)
  b.tiles.s = blk(7)
  b.tiles.w = blk(8)
  b.tiles.e = blk(9)
  return b
end

function test_paintBrush_stampsAndReblendsRing()
  local s = makeSession()
  local brush = mountainBrush()
  assert(MapOps.paintBrush(s, brush, 1, 1) == true, "first stamp changes")
  assert(s.def.blocks[bidx(3, 1, 1)] == 5, "isolated cell paints the center")
  assert(MapOps.paintBrush(s, brush, 1, 0) == true)
  assert(s.def.blocks[bidx(3, 1, 0)] == 6,
    "cell south of terrain caps with its north edge")
  assert(s.def.blocks[bidx(3, 1, 1)] == 7,
    "the ring re-blend reshapes the old cell to a south edge")
  assert(#s.undo.captures == 2, "one undo capture per stroke")
  assert(s.undo.captures[2].n == 2, "second stroke writes new cell + re-blend")
  assert(s._rebuilt.root > 0, "renderer rebuilt")
  assert(s.mapChanged, "session flagged dirty")
end

function test_paintBrush_spansNeighborSeam()
  local s = makeSession(3, 3)
  local east = { width = 2, height = 3, tileset = "TS_A",
    blocks = { 0, 0, 0, 0, 0, 0 } }
  s.neighbors = { { id = "EAST", def = east, ox = 96, oy = 0 } }
  s.neighborMaps = { EAST = { renderer = {
    rebuild = function() s._rebuilt.east = (s._rebuilt.east or 0) + 1 end } } }
  local brush = mountainBrush()

  assert(MapOps.paintBrush(s, brush, 2, 1) == true)
  assert(s.def.blocks[bidx(3, 2, 1)] == 5)
  assert(MapOps.paintBrush(s, brush, 3, 1) == true,
    "stamp lands on the east map across the seam")
  assert(east.blocks[bidx(2, 0, 1)] == 9,
    "cell west of terrain caps with its east edge - on the neighbor def")
  assert(s.def.blocks[bidx(3, 2, 1)] == 8,
    "root cell re-blends to a west edge after the seam fill")
  assert(s.neighborDirty.EAST == true, "neighbor marked dirty")
  assert((s._rebuilt.east or 0) > 0, "neighbor renderer rebuilt")
  assert(#s.undo.captures == 3, "captures grouped per touched map")
end

function test_paintBrush_requiresCenter()
  local s = makeSession()
  local b = Brushes.new("Broken")
  b.tiles.n = blk(6)
  assert(MapOps.paintBrush(s, b, 1, 1) == false,
    "no center tile -> nothing paints")
  assert(s.def.blocks[bidx(3, 1, 1)] == 0)
  assert(#s.undo.captures == 0)
end

-- ---------------------------------------------------------------------------
-- Brush Maker panel geometry

function test_panel_slotHitTest()
  reset()
  Input.showBrushEditor = true
  for _, key in ipairs({ "nw", "c", "se", "v", "h", "i_nw", "i_se",
                         "ln", "lw", "le", "ls", "o" }) do
    local x, y = BrushEditor.rect(VW, VH)
    local cell = BrushEditor.LAYOUT[key]
    assert(cell, key .. " has a layout cell")
    local groupGap = cell[2] > 5 and BrushEditor.GROUP_GAP or 0
    local sx = x + Panel.PAD + cell[1] * (BrushEditor.SLOT + BrushEditor.GAP)
    local sy = y + Panel.TITLE_H + Panel.TITLE_GAP + Panel.PAD
      + cell[2] * (BrushEditor.SLOT + BrushEditor.GAP) + groupGap
    assert(BrushEditor.slotKeyAt(VW, VH, sx + 4, sy + 4) == key,
      key .. " hit-tests at its layout cell")
  end
end

function test_panel_buttonsThirds()
  local _, _, pw = BrushEditor.rect(VW, VH)
  local sx, sy, sw = BrushEditor.buttonRect(VW, VH, "save")
  local cx, cy, cw = BrushEditor.buttonRect(VW, VH, "clear")
  local dx, dy, dw = BrushEditor.buttonRect(VW, VH, "delete")
  assert(sw == cw and cw == dw, "equal widths across the three buttons")
  assert(sx + sw + BrushEditor.GAP == cx, "one gap between save and clear")
  assert(cx + cw + BrushEditor.GAP == dx, "one gap between clear and delete")
  assert(dx + dw <= sx + pw - Panel.PAD, "buttons stay inside the panel")
  assert(cy == sy and dy == sy, "buttons share a row")
end

-- ---------------------------------------------------------------------------
-- Brush Maker input flow

function test_clickAssignsHotbarTileToSlot()
  reset()
  Input.showBrushEditor = true
  Input.hotbar[1] = blk(12)
  Input.selected = 1
  local x, y = BrushEditor.rect(VW, VH)
  local cell = BrushEditor.LAYOUT.c
  local cx = x + Panel.PAD + cell[1] * (BrushEditor.SLOT + BrushEditor.GAP) + 4
  local cy = y + Panel.TITLE_H + Panel.TITLE_GAP + Panel.PAD
    + cell[2] * (BrushEditor.SLOT + BrushEditor.GAP) + 4
  assert(Input.mousepressed({}, {}, cx, cy, 1) == true)
  local slot = Brushes.slot(Input.brushDraft, "c")
  assert(slot and slot.id == 12, "clicking a slot stores the hotbar tile")
end

function test_dragDropOntoSlotStoresCopy()
  reset()
  Input.showBrushEditor = true
  Input.dragItem = blk(21)
  local x, y = BrushEditor.rect(VW, VH)
  local cell = BrushEditor.LAYOUT.ne
  local dx = x + Panel.PAD + cell[1] * (BrushEditor.SLOT + BrushEditor.GAP) + 4
  local dy = y + Panel.TITLE_H + Panel.TITLE_GAP + Panel.PAD
    + cell[2] * (BrushEditor.SLOT + BrushEditor.GAP) + 4
  assert(Input.mousereleased({}, dx, dy, 1) == true)
  local slot = Brushes.slot(Input.brushDraft, "ne")
  assert(slot and slot.id == 21, "dropped tile joins the slot")
  assert(slot ~= Input.dragItem, "slot holds a copy")
  assert(Input.dragItem == nil, "drag cleared")
end

function test_rmbClearsSlot()
  reset()
  Input.showBrushEditor = true
  Brushes.setSlot(Input.brushDraft, "sw", blk(5))
  local x, y = BrushEditor.rect(VW, VH)
  local cell = BrushEditor.LAYOUT.sw
  local cx = x + Panel.PAD + cell[1] * (BrushEditor.SLOT + BrushEditor.GAP) + 4
  local cy = y + Panel.TITLE_H + Panel.TITLE_GAP + Panel.PAD
    + cell[2] * (BrushEditor.SLOT + BrushEditor.GAP) + 4
  assert(Input.mousepressed({}, {}, cx, cy, 2) == true)
  assert(Brushes.slot(Input.brushDraft, "sw") == nil, "RMB clears the slot")
end

function test_grabSlotOntoHotbarWhenNothingSelected()
  reset()
  Input.showBrushEditor = true
  Brushes.setSlot(Input.brushDraft, "e", blk(9))
  local x, y = BrushEditor.rect(VW, VH)
  local cell = BrushEditor.LAYOUT.e
  local cx = x + Panel.PAD + cell[1] * (BrushEditor.SLOT + BrushEditor.GAP) + 4
  local cy = y + Panel.TITLE_H + Panel.TITLE_GAP + Panel.PAD
    + cell[2] * (BrushEditor.SLOT + BrushEditor.GAP) + 4
  assert(Input.mousepressed({}, {}, cx, cy, 1) == true)
  assert(Input.hotbar[1] and Input.hotbar[1].id == 9,
    "with no tile selected, clicking a filled slot grabs it")
end

function test_saveAddsBrushToInventoryBrushesTab()
  reset()
  Input.showBrushEditor = true
  Brushes.setSlot(Input.brushDraft, "c", blk(7))
  Brushes.setSlot(Input.brushDraft, "n", blk(8))
  local bx, by, bw, bh = BrushEditor.buttonRect(VW, VH, "save")
  assert(Input.mousepressed({}, {}, bx + bw / 2, by + bh / 2, 1) == true)
  assert(#Input.inventory.items == 1, "saved brush joins the inventory")
  local saved = Input.inventory.items[1]
  assert(saved.kind == "brush" and saved.tiles.c.id == 7
    and saved.tiles.n.id == 8, "saved brush keeps its slots")
  assert(saved.tiles.c ~= Input.brushDraft.tiles.c,
    "saved brush is detached from the draft")
  assert(Input.inventory.tab == Inventory.tabFor(saved),
    "inventory switches to the Brushes tab")

  -- Without a center the save is rejected.
  Input.clearBrushDraft()
  Brushes.setSlot(Input.brushDraft, "n", blk(8))
  assert(Input.mousepressed({}, {}, bx + bw / 2, by + bh / 2, 1) == true)
  assert(#Input.inventory.items == 1, "center-less draft is not saved")
end

function test_clearButtonEmptiesDraft()
  reset()
  Input.showBrushEditor = true
  Brushes.setSlot(Input.brushDraft, "c", blk(1))
  Brushes.setSlot(Input.brushDraft, "o", blk(2))
  local bx, by, bw, bh = BrushEditor.buttonRect(VW, VH, "clear")
  assert(Input.mousepressed({}, {}, bx + bw / 2, by + bh / 2, 1) == true)
  assert(Brushes.filled(Input.brushDraft) == 0, "CLEAR empties every slot")
end

local function clickButton(which)
  local bx, by, bw, bh = BrushEditor.buttonRect(VW, VH, which)
  return Input.mousepressed({}, {}, bx + bw / 2, by + bh / 2, 1)
end

function test_deleteRemovesLoadedBrushFromInventory()
  reset()
  Input.showInventory = true
  local saved = { kind = "brush", name = "Cliff",
    tiles = { c = blk(3), n = blk(4) } }
  Input.inventory.items = { saved }
  Input.inventory.tab = 4
  -- Load it into the maker (RMB on its cell), then DELETE.
  local px, py = Inventory.rect(VW, VH)
  local cx = px + Panel.PAD + Inventory.SLOT / 2
  local cy = py + Panel.PAD + Panel.TITLE_H + Panel.TITLE_GAP + Panel.TAB_H
    + Inventory.GAP + Inventory.SLOT / 2
  Input.mousepressed({}, {}, cx, cy, 2)
  assert(Input.brushSource == saved, "the draft links to the saved brush")
  assert(clickButton("delete") == true)
  assert(#Input.inventory.items == 0, "DELETE removes the brush")
  assert(Input.brushSource == nil, "the source link clears")
  assert(Brushes.slot(Input.brushDraft, "c") ~= nil,
    "the draft keeps its slots for tweaking")
end

function test_saveUpdatesLoadedBrushInPlace()
  reset()
  local saved = { kind = "brush", name = "Cliff", tiles = { c = blk(3) } }
  Input.inventory.items = { saved }
  assert(Input.editBrush(saved) == true)
  Brushes.setSlot(Input.brushDraft, "n", blk(4))
  assert(clickButton("save") == true)
  assert(#Input.inventory.items == 1, "SAVE replaces in place, no duplicate")
  local updated = Input.inventory.items[1]
  assert(updated ~= saved, "a fresh item table is stored")
  assert(updated.tiles.c.id == 3 and updated.tiles.n.id == 4,
    "the update carries the edited slots")
  assert(updated.name == "Cliff", "the name is kept")
  assert(Input.brushSource == nil, "the source link detaches after save")
end

function test_deleteInertWithoutSource()
  reset()
  Input.showBrushEditor = true
  Input.inventory.items = { { kind = "block", id = 1 } }
  Brushes.setSlot(Input.brushDraft, "c", blk(5))
  assert(clickButton("delete") == true, "the click is still consumed")
  assert(#Input.inventory.items == 1,
    "a fresh draft has nothing to delete")
  assert(Input.deleteBrushSource() == false)
end

function test_rmbBrushCellOpensMaker()
  reset()
  Input.showInventory = true
  Input.inventory.items = { {
    kind = "brush", name = "Cliff",
    tiles = { c = blk(3), n = blk(4) },
  } }
  Input.inventory.tab = 4
  local px, py = Inventory.rect(VW, VH)
  local cx = px + Panel.PAD + Inventory.SLOT / 2
  local cy = py + Panel.PAD + Panel.TITLE_H + Panel.TITLE_GAP + Panel.TAB_H
    + Inventory.GAP + Inventory.SLOT / 2
  assert(Input.mousepressed({}, {}, cx, cy, 2) == true)
  assert(Input.showBrushEditor, "RMB on a brush cell opens the maker")
  assert(Input.brushDraft.name == "Cliff", "draft carries the brush name")
  assert(Brushes.slot(Input.brushDraft, "c").id == 3,
    "draft carries the brush slots")
  assert(Input.details == nil, "no Details panel for brushes")
end

function test_toggleInventoryHidesBrushMaker()
  reset()
  Input.showInventory = true
  Input.showBrushEditor = true
  assert(Input.keypressed({}, "tab") == true)
  assert(Input.showInventory == false, "TAB closes the inventory")
  assert(Input.showBrushEditor == false,
    "the maker hides together with the inventory")
end

return {
  name = "MAPAMAP_BRUSHES",
  tests = {
    "test_pickKey_sides_corners_center",
    "test_pickKey_endCaps",
    "test_pickKey_innerCorners",
    "test_pickKey_lineRuns",
    "test_fallback_resolution",
    "test_lineFallsBackToEdgeThenCenter",
    "test_slots_clone_complete",
    "test_ownsBlock_nativeAndGrafted",
    "test_paintBrush_stampsAndReblendsRing",
    "test_paintBrush_spansNeighborSeam",
    "test_paintBrush_requiresCenter",
    "test_panel_slotHitTest",
    "test_panel_buttonsThirds",
    "test_clickAssignsHotbarTileToSlot",
    "test_dragDropOntoSlotStoresCopy",
    "test_rmbClearsSlot",
    "test_grabSlotOntoHotbarWhenNothingSelected",
    "test_saveAddsBrushToInventoryBrushesTab",
    "test_clearButtonEmptiesDraft",
    "test_deleteRemovesLoadedBrushFromInventory",
    "test_saveUpdatesLoadedBrushInPlace",
    "test_deleteInertWithoutSource",
    "test_rmbBrushCellOpensMaker",
    "test_toggleInventoryHidesBrushMaker",
  },
}
