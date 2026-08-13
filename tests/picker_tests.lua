-- Picker catalog tests: the virtual "NPCs" entry comes first, the current
-- map's tileset is featured first among the real tilesets, and the item list
-- for the virtual entry contains NPC sprites only (items stay in the
-- inventory).

package.path = "../../../?.lua;" .. package.path

if not _G.love then _G.love = require("tests.love_stub") end

local Picker = require("mods.mapamap.components.picker")

local function sessionWith(tilesetId, tilesets, items, sprites)
  return {
    data = {
      tilesets = tilesets,
      items = items,
      sprites = sprites,
    },
    tileset = { id = tilesetId },
  }
end

function test_catalogVirtualEntryFirst()
  local s = sessionWith("TS_B", {
    TS_A = { name = "A" }, TS_B = { name = "B" }, TS_C = { name = "C" },
  }, {}, {})
  local cat = Picker.catalog(s)
  assert(cat[1] == Picker.SPEC, "virtual Items & NPCs entry should come first")
  -- The current map's tileset is featured first among real tilesets.
  local real = {}
  for i = 2, #cat do real[#real + 1] = cat[i] end
  assert(real[1] == "TS_B", "current map tileset should be first, got " .. tostring(real[1]))
end

function test_catalogRealTilesetsSorted()
  local s = sessionWith("TS_Z", {
    TS_Z = { name = "Z" }, TS_A = { name = "A" }, TS_M = { name = "M" },
  }, {}, {})
  local cat = Picker.catalog(s)
  local real = {}
  for i = 2, #cat do real[#real + 1] = cat[i] end
  assert(real[1] == "TS_Z", "featured current first")
  -- the rest are alphabetically sorted (excluding the featured one)
  assert(real[2] == "TS_A" and real[3] == "TS_M",
    "remaining tilesets should be sorted, got " .. table.concat(real, ","))
end

function test_virtualItemListSpritesThenItems()
  local s = sessionWith("TS_A", { TS_A = { blocks = { 0, 1 } } }, {
    ZAPCAN = {}, ACORN = {},
  }, {
    LASS = {}, BUG = {},
  })
  local list = Picker.itemList(s, Picker.SPEC)
  assert(#list == 2, "expected 2 sprites (no items), got " .. #list)
  assert(list[1].kind == "sprite" and list[1].id == "BUG",
    "sprites come first sorted, got " .. tostring(list[1].id))
  assert(list[2].kind == "sprite" and list[2].id == "LASS", "second sprite wrong")
end

function test_blockListForRealTileset()
  local s = sessionWith("TS_A", { TS_A = { blocks = { 0, 1, 2, 3 } } }, {}, {})
  local list = Picker.itemList(s, "TS_A")
  assert(#list == 4, "expected 4 blocks, got " .. #list)
  assert(list[1].kind == "block" and list[1].id == 0, "first block id 0")
  assert(list[4].kind == "block" and list[4].id == 3, "last block id 3")
end

function test_nilSelectionResolvesToCurrentTileset()
  local s = sessionWith("TS_A", { TS_A = { blocks = { 0, 1 } } }, {}, {})
  local resolved = Picker.resolve(nil, s)
  assert(resolved == "TS_A", "nil selection should resolve to the current map tileset")
  local list = Picker.itemList(s, nil)
  assert(list[1].kind == "block", "nil selection should browse the current map's blocks")
end

function test_labelForSpecialAndTileset()
  local s = sessionWith("TS_A", { TS_A = { name = "Overworld A" } }, {}, {})
  assert(Picker.label(s, Picker.SPEC) == "NPCs", "special label")
  assert(Picker.label(s, "TS_A") == "Overworld A", "tileset label uses its name")
end

-- The core regression for "picker shows the current map tileset for all
-- tilesets": browsing a tileset that is NOT the current one must list that
-- tileset's own blocks (its count), and resolve nil back to the current tileset.
function test_itemListBrowsesSelectedTilesetNotCurrent()
  local s = sessionWith("TS_A", {
    TS_A = { blocks = { 0, 1, 2 } },                  -- current tileset, 3 blocks
    TS_B = { blocks = { 0, 1, 2, 3, 4, 5, 6, 7 } },  -- foreign tileset, 8 blocks
  }, {}, {})
  local foreign = Picker.itemList(s, "TS_B")
  assert(#foreign == 8, "browsing TS_B should list its 8 blocks, got " .. #foreign)
  assert(foreign[1].kind == "block" and foreign[1].id == 0, "first block id 0")
  assert(foreign[8].kind == "block" and foreign[8].id == 7, "last block id 7")
  -- The default (unset) selection must still be the current tileset's blocks.
  local cur = Picker.itemList(s, nil)
  assert(#cur == 3, "nil/default should be the current tileset blocks, got " .. #cur)
  -- A foreign selection must NOT leak the current tileset's block count.
  assert(#foreign ~= #cur, "browsed tileset must not fall back to the current tileset")
end

function test_tilesetDefResolvesBrowsedTileset()
  local a = { id = "TS_A", blocks = { 0 } }
  local b = { id = "TS_B", blocks = { 0, 1, 2, 3, 4, 5 } }
  local s = sessionWith("TS_A", { TS_A = a, TS_B = b }, {}, {})
  assert(Picker.tilesetDef(s, "TS_B") == b, "tilesetDef should resolve the browsed tileset")
  assert(Picker.tilesetDef(s, "TS_B") ~= a, "must not fall back to the current tileset")
  assert(Picker.tilesetDef(s, nil) == a, "nil selection resolves to the current tileset")
  assert(Picker.tilesetDef(s, Picker.SPEC) == nil, "virtual catalog has no tileset def")
  assert(Picker.tilesetDef(s, "TS_NOPE") == nil, "unknown tileset resolves to nil")
end

return {
  name = "MAPAMAP_PICKER",
  tests = {
    "test_catalogVirtualEntryFirst",
    "test_catalogRealTilesetsSorted",
    "test_virtualItemListSpritesThenItems",
    "test_blockListForRealTileset",
    "test_nilSelectionResolvesToCurrentTileset",
    "test_labelForSpecialAndTileset",
    "test_itemListBrowsesSelectedTilesetNotCurrent",
    "test_tilesetDefResolvesBrowsedTileset",
  },
}