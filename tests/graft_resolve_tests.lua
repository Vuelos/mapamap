-- Grafted (cross-tileset) block resolution tests: these are now BASE-engine
-- reads -- Map.blockTiles resolves a block id above the tileset's native
-- count through the map def's graftBlocks, and the collision/render paths that
-- used to be monkey-patched by the old func/engine_hooks module use it
-- natively (loaded Map:tileAt, unloaded Map.defCellTile, and the renderer's
-- window fill).  A grafted region must read real atlas slots (not crash the
-- collision/walk loop).

package.path = "../../../?.lua;" .. package.path

if not _G.love then _G.love = require("tests.love_stub") end

local Map = require("src.world.Map")
local TileRenderer = require("src.render.TileRenderer")

-- A tileset: native block ids 0..3, each a 16-tile array in the 4x4 pattern.
-- The image path is a real-looking string; the headless stub's newImage
-- falls back to an 8x8 px atlas (2 native tiles) when the file is missing,
-- which is enough for the renderer constructor to build quads for slots.
local function tileset(id, count)
  local blocks = {}
  for i = 1, count do
    local t = {}
    for c = 1, 16 do t[c] = i * 100 + c end
    blocks[i] = t
  end
  return { id = id, image = "assets/generated/tilesets/" .. id .. ".png",
           tilesPerRow = 4, blocks = blocks, walkable = { 101 } }
end

-- A 4x4 map; graft block id 5 (= native 4 + 1) at block (0,1), with 16
-- absolute atlas slots 1..16.
local function graftDef()
  local blocks = { 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }
  -- row-major: block (bx=0, by=1) is index 1*4 + 0 + 1 = 5
  blocks[1 * 4 + 0 + 1] = 5
  return {
    id = "MAP", tileset = "TS_A", width = 4, height = 4, borderBlock = 0,
    blocks = blocks,
    graftBlocks = {
      { srcTileset = "TS_B", srcBlock = 0, tiles = { 1, 2, 3, 4, 5, 6, 7, 8, 9, 10,
        11, 12, 13, 14, 15, 16 } },
    },
  }
end

function test_blockTilesResolvesNativeAndGrafted()
  local def = graftDef()
  local ts = tileset("TS_A", 4)
  assert(Map.blockTiles(def, ts, 3), "native block resolves through the tileset")
  local g = Map.blockTiles(def, ts, 5)
  assert(g and g[3] == 3, "grafted block resolves through def.graftBlocks, got "
         .. tostring(g and g[3]))
  assert(Map.blockTiles(def, ts, 99) == nil, "unknown block id fails closed")
end

function test_tileAtGraftedResolvesNoCrash()
  local def = graftDef()
  local map = Map.new(def, tileset("TS_A", 4))
  local safe = true
  for ty = 0, 15 do
    for tx = 0, 15 do
      local ok = pcall(Map.tileAt, map, tx, ty)
      if not ok then safe = false end
    end
  end
  assert(safe, "walking every tile must never throw on a grafted map")
  -- The grafted block (0,1) resolves through graftBlocks.
  assert(map:blockAt(0, 1) == 5, "grafted block id at (0,1) is 5")
  -- Tile (2,4) sits inside block (0,1): ci = (ty%4)*4 + (tx%4) + 1 =
  -- (0)*4 + (2) + 1 = 3 -> graft slot 3.
  local t = map:tileAt(2, 4)
  assert(t == 3, "grafted cell tile resolves through graftBlocks, got " .. tostring(t))
  -- Native cells resolve normally (block id 0 -> tileset block 1's tile 1 =
  -- 101, the walkable id this fixture keys).
  local nt = map:tileAt(0, 0)
  assert(nt == 101, "native cell tile resolves through the tileset, got " .. tostring(nt))
end

function test_defCellTileGraftedNoCrash()
  local def = graftDef()
  local ts = tileset("TS_A", 4)
  -- Cell (1,2): tx = cx*2 = 2, ty = cy*2+1 = 5 -> block (0,1) -> graft slot
  -- ci = (5%4)*4 + (2%4) + 1 = 1*4 + 2 + 1 = 7.
  local tile = Map.defCellTile(def, ts, 1, 2)
  assert(tile == 7, "defCellTile resolves grafted region, got " .. tostring(tile))
  local ok = pcall(Map.defCellTile, def, ts, 0, 1)
  assert(ok, "defCellTile over a grafted cell must not throw")
  local border = Map.defCellTile(def, ts, 20, 20)
  assert(border ~= nil, "out-of-body border collision still resolves")
end

function test_rendererBuildsAndDrawsGraftedBlock()
  local map = Map.new(graftDef(), tileset("TS_A", 4))
  local r = TileRenderer.new(map, nil)
  assert(r and r.image, "renderer built")
  assert(r.quads, "renderer quads present")
  -- The window fill walks every body tile; a grafted block (block id >= the
  -- native count, with a containing graftBlocks entry) never throws.
  local ok = pcall(TileRenderer.ensureWindow, r, 0, 0, 32, 32)
  assert(ok, "ensureWindow must not throw over a grafted map")
  assert(r.win, "window marked filled")
end

return {
  name = "MAPAMAP_GRAFT_RESOLVE",
  tests = {
    "test_blockTilesResolvesNativeAndGrafted",
    "test_tileAtGraftedResolvesNoCrash",
    "test_defCellTileGraftedNoCrash",
    "test_rendererBuildsAndDrawsGraftedBlock",
  },
}