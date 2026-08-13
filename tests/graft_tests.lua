-- Cross-tileset grafting (func/graft.lua) tests: block-id allocation above
-- the tileset's native count, source-graphic dedup across maps, rebuild-from-
-- defs mapping, and save/undo round-trip of def.graftBlocks.

package.path = "../../../?.lua;" .. package.path

if not _G.love then _G.love = require("tests.love_stub") end

local Graft = require("mods.mapamap.func.graft")
local Undo = require("mods.mapamap.func.undo")
local Save = require("mods.mapamap.func.save")

-- A tileset whose atlas ImageData reports 8x8 px = 2 native 8px tile slots
-- (the numbers are irrelevant; the structure is what the mapping math reads).
local function atlas(id, blockCount)
  local blocks = {}
  for i = 1, blockCount do
    local t = {}
    for c = 1, 16 do t[c] = (i - 1) * 16 + (c - 1) end
    blocks[i] = t
  end
  return { id = id, image = "assets/generated/tilesets/" .. id .. ".png", blocks = blocks }
end

-- A map def sharing a tileset, with an injectable graft list.
local function mapDef(tilesetId, width, height, graftBlocks)
  return {
    tileset = tilesetId, width = width, height = height,
    blocks = {}, graftBlocks = graftBlocks,
  }
end

-- Quick two-tileset data fixture with one editable map on TS_A.
local function dataWith()
  return {
    tilesets = { TS_A = atlas("TS_A", 4), TS_B = atlas("TS_B", 8) },
    maps = { MAP1 = mapDef("TS_A", 10, 10) },
  }
end

function test_importBlockReturnsNativePlusIndex()
  local data = dataWith()
  local def = data.maps.MAP1
  local id = Graft.importBlock(data, "TS_A", def, "TS_B", 2)
  assert(id == 4 + 1, "first graft id = native count + 1, got " .. tostring(id))
  local id2 = Graft.importBlock(data, "TS_A", def, "TS_B", 5)
  assert(id2 == 4 + 2, "second graft id = native + 2, got " .. tostring(id2))
end

function test_importBlockReusesSameSource()
  local data = dataWith()
  local def = data.maps.MAP1
  local first = Graft.importBlock(data, "TS_A", def, "TS_B", 3)
  local again = Graft.importBlock(data, "TS_A", def, "TS_B", 3)
  assert(first == again, "same (srcTileset,srcBlock) must reuse the graft id")
  assert(#def.graftBlocks == 1, "no duplicate graft entries after a repeat import")
end

function test_foreignBlockGrantedOwnIdSpace()
  -- two maps on the same tileset each graft the same foreign block: both get
  -- the same map-local id because the graft is per-def and dedups by source
  local data = {
    tilesets = { TS_A = atlas("TS_A", 4), TS_B = atlas("TS_B", 8) },
    maps = { MAP1 = mapDef("TS_A", 10, 10), MAP2 = mapDef("TS_A", 10, 10) },
  }
  local id1 = Graft.importBlock(data, "TS_A", data.maps.MAP1, "TS_B", 1)
  local id2 = Graft.importBlock(data, "TS_A", data.maps.MAP2, "TS_B", 1)
  assert(id1 == 4 + 1 and id2 == 4 + 1,
    "both maps should reference native+1 via their own defs, got " .. id1 .. "/" .. id2)
end

function test_scanDedupsSourceGraphicsByKey()
  -- two maps graft the same source block; scan must slot each graphic once
  local data = dataWith()
  local m2 = {
    tileset = "TS_A", width = 10, height = 10, blocks = {},
    graftBlocks = {}, -- starts empty; import appends
  }
  data.maps.MAP2 = m2
  Graft.importBlock(data, "TS_A", data.maps.MAP1, "TS_B", 6)
  Graft.importBlock(data, "TS_A", data.maps.MAP2, "TS_B", 6)
  local m = Graft.mappingForTileset(data, "TS_A")
  local used = 0
  for _ in pairs(m.srcForSlot) do used = used + 1 end
  assert(used == 16, "16 source tiles across both defs dedup to 16 slots, got " .. used)
  assert(m.base == 1, "native slot count from the 8x8 stub atlas, got " .. m.base)
end

function test_blockIdBoundaryAndLookup()
  local data = dataWith()
  local def = data.maps.MAP1
  -- native ids are 0..3; anything >= 4 is a graft
  local gid = Graft.importBlock(data, "TS_A", def, "TS_B", 0)
  assert(gid >= 4, "graft id must sit above the native block space")
  local i, entry = Graft.graftFor(def, 4, gid)
  assert(i == 1 and entry and entry.srcTileset == "TS_B", "graftFor resolves the entry")
  assert(Graft.graftFor(def, 4, 3) == nil, "native id has no graft entry")
  assert(Graft.blockIdFor(def, 4, "TS_B", 0) == gid,
    "blockIdFor maps the source block back to the local id")
end

function test_mappingRebuildsFromDefsAfterReload()
  -- no registry is kept anywhere: mappingForTileset must derive everything
  -- from the defs, so a reload (fresh session, same defs) reproduces the atlas
  local data = dataWith()
  local def = data.maps.MAP1
  Graft.importBlock(data, "TS_A", def, "TS_B", 2)
  local first = Graft.mappingForTileset(data, "TS_A")
  -- simulate a fresh process / new session with identical defs
  local data2 = {
    tilesets = data.tilesets,
    maps = { MAP1 = { tileset = "TS_A", width = 10, height = 10,
                      blocks = {}, graftBlocks = def.graftBlocks } },
  }
  local rebuilt = Graft.mappingForTileset(data2, "TS_A")
  assert(rebuilt.base == first.base, "base must match after reload")
  local a, b = {}, {}
  for k, v in pairs(first.srcForSlot) do a[k] = v end
  for k, v in pairs(rebuilt.srcForSlot) do b[k] = v end
  assert(next(a) and next(b), "both scans see grafted slots")
  assert(first.nextSlot == rebuilt.nextSlot, "nextSlot reproduces after reload")
end

function test_paintAndPatchRoundTrip()
  local data = dataWith()
  local def = data.maps.MAP1
  Graft.importBlock(data, "TS_A", def, "TS_B", 4)
  def.blocks[1] = 4 + 1 -- paint the grafted block into the map body
  -- buildPatch must carry graftBlocks (the tracked keys of func.save)
  local patch = Save.buildPatch(def, { blocks = {}, graftBlocks = {} })
  assert(patch.graftBlocks and #patch.graftBlocks == 1,
    "graftBlocks must be tracked by the patch")
  -- applying the patch re-targets data.maps[id] with the graft list
  local target = { MAP2 = { tileset = "TS_A", width = 10, height = 10, blocks = {} } }
  local applied = Save.applyPatchesToData({ MAP2 = patch }, { maps = target })
  assert(applied == 1, "patch applied")
  assert(target.MAP2.graftBlocks and #target.MAP2.graftBlocks == 1,
    "target map received the graft list")
  local id = Graft.blockIdFor(target.MAP2, 4, "TS_B", 4)
  assert(id == 4 + 1, "grafted id resolvable after patch apply")
end

function test_undoRestoresGraftBlocks()
  local data = dataWith()
  local def = data.maps.MAP1
  local undo = Undo.new()
  undo:captureFull(def, 0, 0, "MAP1")
  Graft.importBlock(data, "TS_A", def, "TS_B", 7)
  local after = def.graftBlocks and #def.graftBlocks or 0
  assert(after == 1, "import recorded one graft")
  undo:undo(def, 0, 0, "MAP1")
  local restored = def.graftBlocks and #def.graftBlocks or 0
  assert(restored == 0,
    "undo removed the grafted entry the snapshot predates, got " .. restored)
end

return {
  name = "MAPAMAP_GRAFT",
  tests = {
    "test_importBlockReturnsNativePlusIndex",
    "test_importBlockReusesSameSource",
    "test_foreignBlockGrantedOwnIdSpace",
    "test_scanDedupsSourceGraphicsByKey",
    "test_blockIdBoundaryAndLookup",
    "test_mappingRebuildsFromDefsAfterReload",
    "test_paintAndPatchRoundTrip",
    "test_undoRestoresGraftBlocks",
  },
}