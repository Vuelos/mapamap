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

Common.connectionsOn = function(def, dir)
  return require("mods.mapamap.func.connections").connectionsOn(def, dir)
end

Common.connectionList = function(value)
  return require("mods.mapamap.func.connections").connectionList(value)
end

Common.addConnection = function(def, otherDef, dir, offset, span)
  return require("mods.mapamap.func.connections").addConnection(def, otherDef, dir, offset, span)
end

return Common
