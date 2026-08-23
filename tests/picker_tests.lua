-- Picker catalog tests: the virtual People/Monsters/Items entries come first
-- (People lists every person sprite, Monsters one wild tool per data.pokemon
-- species, Items one ball tool per data.items entry), the current map's
-- tileset is featured first among the real tilesets, and block ids index the
-- BROWSED tileset's blocks.

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
    TS_A = { name = "A", blocks = {} },
    TS_B = { name = "B", blocks = {} },
    TS_C = { name = "C", blocks = {} },
  }, {}, {})
  local cat = Picker.catalog(s)
  assert(cat[1] == Picker.SPEC_PERSON, "People entry should come first")
  assert(cat[2] == Picker.SPEC_MONSTER and cat[3] == Picker.SPEC_ITEMS,
    "Monsters then Items follow")
  -- The current map's tileset is featured first among real tilesets.
  local real = {}
  for i = 4, #cat do real[#real + 1] = cat[i] end
  assert(real[1] == "TS_B", "current map tileset should be first, got " .. tostring(real[1]))
end

function test_catalogRealTilesetsSorted()
  local s = sessionWith("TS_Z", {
    TS_Z = { name = "Z", blocks = {} },
    TS_A = { name = "A", blocks = {} },
    TS_M = { name = "M", blocks = {} },
  }, {}, {})
  local cat = Picker.catalog(s)
  local real = {}
  for i = 4, #cat do real[#real + 1] = cat[i] end
  assert(real[1] == "TS_Z", "featured current first")
  -- the rest are alphabetically sorted (excluding the featured one)
  assert(real[2] == "TS_A" and real[3] == "TS_M",
    "remaining tilesets should be sorted, got " .. table.concat(real, ","))
end

function test_peopleListSpritesOnly()
  local s = sessionWith("TS_A", { TS_A = { blocks = { 0, 1 } } }, {
    ZAPCAN = {}, ACORN = {},
  }, {
    LASS = {}, BUG = {}, SPRITE_SNORLAX = {},
  })
  local list = Picker.itemList(s, Picker.SPEC_PERSON)
  assert(#list == 3, "expected every sprite (no hardcoded exclusion), got "
    .. #list)
  assert(list[1].kind == "sprite" and list[1].id == "BUG",
    "sprites sorted, got " .. tostring(list[1].id))
  assert(list[2].kind == "sprite" and list[2].id == "LASS", "second sprite wrong")
  assert(list[3].kind == "sprite" and list[3].id == "SPRITE_SNORLAX",
    "critter sheets stay placeable as overworld NPCs")
end

function test_monsterListBuildsWildTools()
  local s = sessionWith("TS_A", { TS_A = {} }, {
    POTION = {},
  }, {
    LASS = {}, SPRITE_SNORLAX = {}, SPRITE_SEEL = {},
    SPRITE_MONSTER = {},
  })
  s.data.pokemon = {
    SNORLAX = { dex = 143 }, SEEL = { dex = 86 }, ABRA = { dex = 63 },
  }
  local list = Picker.itemList(s, Picker.SPEC_MONSTER)
  assert(#list == 3, "one tool per species, got " .. #list)
  assert(list[1].kind == "entity" and list[1].entityType == "object",
    "monster entries are object tools")
  -- Species are ordered by dex number (ABRA 63 < SEEL 86 < SNORLAX 143).
  assert(list[1].create.objectType == "mon"
    and list[1].create.pokemon == "ABRA",
    "tools are sorted by dex, ABRA first")
  assert(list[2].create.pokemon == "SEEL"
    and list[2].create.sprite == "SPRITE_SEEL",
    "an exact-named sheet wins when the extraction carries one")
  assert(list[3].create.pokemon == "SNORLAX"
    and list[3].create.sprite == "SPRITE_SNORLAX", "SNORLAX maps to its sheet")
  -- A species without its own sheet falls back to a generic critter sheet.
  local generics = { SPRITE_MONSTER = true, SPRITE_BIRD = true,
    SPRITE_SEEL = true, SPRITE_FAIRY = true, SPRITE_SNORLAX = true }
  assert(generics[list[1].create.sprite],
    "sheet-less species fall back to a generic monster sheet, got "
    .. tostring(list[1].create.sprite))
  assert(list[1].label == "ABRA" and list[2].label == "SEEL",
    "species tools carry their name for the hover header")
end

function test_itemListOneBallToolPerItem()
  local s = sessionWith("TS_A", { TS_A = {} }, {
    POTION = {}, ACORN = {},
  }, { LASS = {} })
  local list = Picker.itemList(s, Picker.SPEC_ITEMS)
  assert(#list == 2, "one item-ball tool per data.items entry, got " .. #list)
  assert(list[1].kind == "entity" and list[1].entityType == "object",
    "item entries are object tools")
  assert(list[1].create.objectType == "itemball"
    and not list[1].create.sprite,
    "the placer defaults the ball sprite (none hardcoded here)")
  assert(list[1].create.item == "ACORN" and list[2].create.item == "POTION",
    "items are sorted by id")
  -- No items at all -> no ball tools.
  local s2 = sessionWith("TS_A", { TS_A = {} }, {}, { LASS = {} })
  assert(#Picker.itemList(s2, Picker.SPEC_ITEMS) == 0,
    "empty items table yields no ball tools")
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
  assert(Picker.label(s, Picker.SPEC_PERSON) == "People", "People label")
  assert(Picker.label(s, Picker.SPEC_MONSTER) == "Monsters", "Monsters label")
  assert(Picker.label(s, Picker.SPEC_ITEMS) == "Items", "Items label")
  assert(Picker.isSpecial(Picker.SPEC_PERSON), "specials are flagged")
  assert(not Picker.isSpecial("TS_A"), "real tilesets are not specials")
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
  assert(Picker.tilesetDef(s, Picker.SPEC_PERSON) == nil, "virtual catalog has no tileset def")
  assert(Picker.tilesetDef(s, "TS_NOPE") == nil, "unknown tileset resolves to nil")
end

return {
  name = "MAPAMAP_PICKER",
  tests = {
    "test_catalogVirtualEntryFirst",
    "test_catalogRealTilesetsSorted",
    "test_peopleListSpritesOnly",
    "test_monsterListBuildsWildTools",
    "test_itemListOneBallToolPerItem",
    "test_blockListForRealTileset",
    "test_nilSelectionResolvesToCurrentTileset",
    "test_labelForSpecialAndTileset",
    "test_itemListBrowsesSelectedTilesetNotCurrent",
    "test_tilesetDefResolvesBrowsedTileset",
  },
}