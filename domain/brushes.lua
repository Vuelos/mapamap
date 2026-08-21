-- Terrain brush model: named multi-tile brushes (mountains, cliffs, water...)
-- whose slots cover every tiling position of a blob tileset.
--
-- A brush is an inventory item:
--   { kind = "brush", name = "Mountain",
--     tiles = { c = <block item>, n = ..., i_nw = ..., ... } }
-- Each slot stores a normal block item ({ kind = "block", id, srcTileset? })
-- so drag-drop from the picker/inventory works unchanged and graft tags ride
-- along.  Every slot except the center ("c") is OPTIONAL: painting resolves a
-- position through its fallback chain and lands on "c" when nothing better is
-- assigned, so a center-only brush degrades to a plain block brush.
--
-- Position keys:
--   core 3x3 ......... nw n ne / w c e / sw s se   (edges + outer corners)
--   inner corners .... i_nw i_ne i_sw i_se         (all sides joined, one
--                                                     diagonal open)
--   corridors ........ v (north+south open) / h (west+east open)
--   line edges ....... ln ls le lw                 (straight edge run: the
--                                                     edge continues on BOTH
--                                                     sides, so no end
--                                                     borders are drawn)
--   isolated ......... o                            (no join on any side)
--
-- This module is pure data/logic: no LÖVE, no session -- the world-write
-- orchestration lives in MapOps.paintBrush.

local Common = require("mods.mapamap.common")

local Brushes = {}

-- The 3x3 core grid, row-major (panel layout order).
Brushes.CORE = { "nw", "n", "ne", "w", "c", "e", "sw", "s", "se" }

-- Optional refinement groups shown around/below the core grid.
Brushes.INNER = { "i_nw", "i_ne", "i_sw", "i_se" }
Brushes.MISC = { "v", "h", "o" }
Brushes.LINES = { "ln", "ls", "lw", "le" }

-- Short slot labels for the editor panel.
Brushes.LABELS = {
  nw = "NW", n = "N", ne = "NE",
  w = "W", c = "C", e = "E",
  sw = "SW", s = "S", se = "SE",
  i_nw = "INW", i_ne = "INE", i_sw = "ISW", i_se = "ISE",
  v = "V", h = "H", o = "O",
  ln = "LN", ls = "LS", lw = "LW", le = "LE",
}

-- The only required slot: everything falls back toward it.
Brushes.REQUIRED = "c"

-- Fallback chain: when a position has no assigned tile, try this simpler
-- position next ("c" has none).  Chains end at the center so a sparse brush
-- still paints every cell.
local FALLBACK = {
  i_nw = "c", i_ne = "c", i_sw = "c", i_se = "c",
  nw = "n", ne = "n", sw = "s", se = "s",
  n = "c", s = "c", w = "c", e = "c",
  v = "w", h = "n",
  ln = "n", ls = "s", lw = "w", le = "e",
  o = "c",
}

-- Creates an empty brush draft.
function Brushes.new(name)
  return { kind = "brush", name = name or "Brush", tiles = {} }
end

-- Deep-copies a brush (tiles included) so saved brushes detach from drafts.
function Brushes.clone(brush)
  local out = Brushes.new(brush and brush.name)
  out.tiles = Common.deepCopy(brush and brush.tiles or {})
  return out
end

-- Number of assigned slots.
function Brushes.filled(brush)
  local n = 0
  for k in pairs(brush and brush.tiles or {}) do
    if brush.tiles[k] then n = n + 1 end
  end
  return n
end

function Brushes.slot(brush, key)
  return brush and brush.tiles and brush.tiles[key] or nil
end

-- Sets/clears a slot.  Passing nil removes the slot so optional positions
-- fall back instead of painting "empty".
function Brushes.setSlot(brush, key, item)
  if not brush then return end
  brush.tiles = brush.tiles or {}
  if item then
    brush.tiles[key] = item
  else
    brush.tiles[key] = nil
  end
end

-- Next simpler position in the fallback chain, or nil past the center.
function Brushes.fallback(key)
  return FALLBACK[key]
end

-- Resolves a position to an assigned slot by walking the fallback chain.
-- Returns key, item (the key where the tile was found) or nil.
function Brushes.resolve(brush, key)
  local k = key
  while k do
    local item = Brushes.slot(brush, k)
    if item then return k, item end
    k = FALLBACK[k]
  end
  return nil
end

-- Picks the position key for a join mask.  `mask` carries booleans for the
-- 8 neighbors (n/s/e/w sides + nw/ne/sw/se diagonals); true = same terrain.
-- Covers all 16 side combinations plus the refinements:
--   4 sides open ........ "o"
--   3 open .............. end-cap edge opposite the one joined side
--   2 open, opposite .... "v" (n+s) / "h" (w+e)
--   2 open, adjacent .... outer corner of the two open sides
--   1 open .............. borderless line tile (ln/ls/lw/le) when the edge
--                         run continues on BOTH sides (side neighbor AND its
--                         shared diagonal joined), else the bordered edge
--   0 open .............. inner corner of any missing diagonal, else "c"
function Brushes.pickKey(mask)
  mask = mask or {}
  local n, s, e, w = mask.n, mask.s, mask.e, mask.w
  local nw, ne, sw, se = mask.nw, mask.ne, mask.sw, mask.se
  local openN, openS, openE, openW = not n, not s, not e, not w
  local openCount = (openN and 1 or 0) + (openS and 1 or 0)
    + (openE and 1 or 0) + (openW and 1 or 0)

  if openCount == 4 then return "o" end
  if openCount == 3 then
    -- One joined side: the tile is the end cap facing away from it.
    if n then return "s" end
    if s then return "n" end
    if w then return "e" end
    return "w"
  end
  if openCount == 2 then
    -- Corridors are named for the direction they RUN: a vertical corridor
    -- joins north+south (west/east open), a horizontal one west+east.
    if openW and openE then return "v" end
    if openN and openS then return "h" end
    if openN and openW then return "nw" end
    if openN and openE then return "ne" end
    if openS and openW then return "sw" end
    return "se"
  end
  if openCount == 1 then
    -- Edge run: continue past both ends -> borderless straight line.
    if openN then
      if w and nw and e and ne then return "ln" end
      return "n"
    elseif openS then
      if w and sw and e and se then return "ls" end
      return "s"
    elseif openW then
      if n and nw and s and sw then return "lw" end
      return "w"
    else
      if n and ne and s and se then return "le" end
      return "e"
    end
  end
  -- Fully joined on all sides: refine by the diagonals.
  if not nw then return "i_nw" end
  if not ne then return "i_ne" end
  if not sw then return "i_sw" end
  if not se then return "i_se" end
  return "c"
end

-- The block item a brush paints for a join mask (fallback-resolved), or nil
-- when even the center is unassigned.
function Brushes.tileFor(brush, mask)
  if not brush then return nil end
  local _, item = Brushes.resolve(brush, Brushes.pickKey(mask))
  return item
end

-- Builds a join mask at a cell.  `read(dx, dy)` is called for the 8 offsets
-- and returns true when that neighbor joins the brush (same terrain).
function Brushes.maskFrom(read)
  return {
    n = read(0, -1) == true, s = read(0, 1) == true,
    w = read(-1, 0) == true, e = read(1, 0) == true,
    nw = read(-1, -1) == true, ne = read(1, -1) == true,
    sw = read(-1, 1) == true, se = read(1, 1) == true,
  }
end

-- True when the brush owns every visible tile it needs to blend with.
function Brushes.isComplete(brush)
  return Brushes.slot(brush, Brushes.REQUIRED) ~= nil
end

-- The (tileset, blockId) identity a slot item paints as.  srcTileset wins
-- (foreign picker tiles), then the hotbar tag, else the map's own tileset.
function Brushes.slotIdentity(item, defTileset)
  if not item then return nil end
  return item.srcTileset or item.tileset or defTileset, item.id
end

-- True when a map's block at (bid, def) was painted by this brush.  Native
-- ids compare against the map's tileset; grafted ids resolve back to their
-- source block through def.graftBlocks; any other id was written verbatim
-- (e.g. by this brush itself), so the raw id matches against the map's
-- tileset.
function Brushes.ownsBlock(brush, def, native, bid)
  if not (brush and def and bid) then return false end
  local ts, id
  if bid < native then
    ts, id = def.tileset, bid
  else
    local Graft = require("mods.mapamap.engine.graft")
    local _, entry = Graft.graftFor(def, native, bid)
    if entry then
      ts, id = entry.srcTileset, entry.srcBlock
    else
      ts, id = def.tileset, bid
    end
  end
  for _, item in pairs(brush.tiles or {}) do
    if item and item.id == id then
      local sts = Brushes.slotIdentity(item, def.tileset)
      if sts == ts then return true end
    end
  end
  return false
end

return Brushes
