-- Picker catalog tests: the virtual "Items & NPCs" entry comes first, the
-- current map's tileset is featured first among the real tilesets, and the
-- item list for the virtual entry contains NPC sprites then items.

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
  assert(#list == 4, "expected 4 virtual items, got " .. #list)
  assert(list[1].kind == "sprite" and list[1].id == "BUG",
    "sprites come first sorted, got " .. tostring(list[1].id))
  assert(list[2].kind == "sprite" and list[2].id == "LASS", "second sprite wrong")
  assert(list[3].kind == "item" and list[3].id == "ACORN", "items after sprites")
  assert(list[4].kind == "item" and list[4].id == "ZAPCAN", "last item wrong")
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
  assert(Picker.label(s, Picker.SPEC) == "Items & NPCs", "special label")
  assert(Picker.label(s, "TS_A") == "Overworld A", "tileset label uses its name")
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
  },
}