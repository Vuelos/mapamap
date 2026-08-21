-- Shared constants and helpers for the map editor modules.

local Common = {}

Common.MODES = { MAP = 1, ENT = 2, ENC = 3 }
Common.CELL_PX = 16
Common.BLOCK_PX = 32
Common.PAL_W = 112
Common.PAL_COLS = 3
Common.PAL_SPRITE_COLS = 4

function Common.deepCopy(a)
  if type(a) ~= "table" then return a end
  local out = {}
  for k, v in pairs(a) do out[k] = Common.deepCopy(v) end
  return out
end

function Common.tablesEqual(a, b)
  if a == b then return true end
  if type(a) ~= "table" or type(b) ~= "table" then return false end
  local ka, kb = 0, 0
  for k, v in pairs(a) do
    ka = ka + 1
    if not Common.tablesEqual(v, b[k]) then return false end
  end
  for k in pairs(b) do
    kb = kb + 1
  end
  return ka == kb
end

Common.DIRS = { "north", "south", "west", "east" }
Common.RECIP = { north = "south", south = "north", west = "east", east = "west" }

-- Gen 2 tileset records always carry 128 metatile slots because the
-- extractor reads a fixed METATILE_COUNT*16 bytes -- but the real
-- *_metatiles.bin files are SHORTER and vary per tileset, so the tail is
-- over-read bank garbage (CAVE really ends at 77, MART at 80, JOHTO fills
-- all 128).  The atlas bounds the ids real metatiles can reference: every
-- Gen2 sheet is imageWidth x imageHeight = 96 8px tiles, so a slot whose
-- 16 tile ids do not ALL stay below that count cannot be real content.
-- The count is therefore the LEADING run of fully-in-atlas blocks -- maps
-- index the untouched full array, so this only bounds editor listings.
-- Gen 1 block arrays are exact and pass through.
function Common.effectiveBlockCount(ts)
  local blocks = ts and ts.blocks
  if not blocks then return 0 end
  local n = #blocks
  if ts.generation ~= 2 then return n end
  local iw, ih = ts.imageWidth, ts.imageHeight
  if not (iw and ih and iw > 0 and ih > 0) then return n end
  local tiles = (iw / 8) * (ih / 8)
  local count = 0
  for i = 1, n do
    local b = blocks[i]
    local ok = b and #b > 0
    if ok then
      for _, t in ipairs(b) do
        if (t or 0) >= tiles then ok = false; break end
      end
    end
    if not ok then break end
    count = i
  end
  return math.max(count, 1)
end

return Common
