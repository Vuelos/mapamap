-- Tree-block resolvers for the CUT TREE / HEADBUTT TREE paint tools.
--
-- Both field moves are tile/block-level mechanics with no object state:
--   * CUT scans data.field.cutTreeSwaps ({before, after} block ids) against
--     the block under the cursor (src/world/OverworldController.lua).
--   * HEADBUTT (gen 2) checks the facing cell's collision tile against the
--     fixed {0x15, 0x1d} set (World.isHeadbuttTree) and rolls the encounter
--     from the map's own tree table.
-- The tools therefore just paint the right block for the edited tileset and
-- the field move does the rest.  Kept a leaf module (no component requires)
-- so both Paint and Item.draw can resolve without dependency cycles.

local Common = require("mods.mapamap.common")

local TreeBlocks = {}

local HEADBUTT_TILES = { [0x15] = true, [0x1d] = true }

-- First cutTreeSwaps.before that exists in the edited tileset and differs
-- from its after (the actual tree -> stump pair).  nil when none.
function TreeBlocks.cutBlockFor(session)
  local swaps = session.data and session.data.field
    and session.data.field.cutTreeSwaps
  local ts = session.tileset
  if not (swaps and ts) then return nil end
  local count = Common.effectiveBlockCount(ts)
  for _, sw in ipairs(swaps) do
    local b = sw.before
    if b and b >= 1 and b <= count and sw.after and sw.after ~= b then
      return b
    end
  end
  return nil
end

-- First block of the edited tileset whose bottom-left collision tile is a
-- headbutt-able tree tile.  nil when none.
function TreeBlocks.headbuttBlockFor(session)
  local ts = session.tileset
  if not ts then return nil end
  local okM, MapM = pcall(require, "src.world.Map")
  if not okM or not MapM.blockTiles then return nil end
  local count = Common.effectiveBlockCount(ts)
  for b = 1, count do
    local tiles = MapM.blockTiles(session.def, ts, b)
    -- The bottom-left 8px tile decides a block's collision.
    local coll = tiles and tiles[13]
    if coll and HEADBUTT_TILES[coll % 256] then return b end
  end
  return nil
end

return TreeBlocks
