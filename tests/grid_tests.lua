-- MapGrid unit tests on a synthetic map graph: layout composition (the BFS
-- rects mirror Neighbors.compute's strip offsets), candidate voids (dedup +
-- connectivity scoring), the highest-connectivity pick with a deterministic
-- tie-break, directional expansion, createMap overlap rejection + reciprocal
-- wiring + persistence tracking, and the autofill depth/cap safety.

package.path = "../../../?.lua;" .. package.path

if not _G.love then _G.love = require("tests.love_stub") end

local MapGrid = require("mods.mapamap.func.map_grid")
local Common = require("mods.mapamap.func.common")

local BACK = { north = "south", south = "north", east = "west", west = "east" }

-- A minimal map def enough for MapGrid.layout / NewMap.buildDef.
local function miniMap(id, w, h, conns)
  local blocks = {}
  for i = 1, w * h do blocks[i] = 0 end
  return {
    id = id, name = id, width = w, height = h, blocks = blocks,
    borderBlock = 0, tileset = "ts", palette = nil,
    connections = conns or {}, warps = {}, objects = {}, signs = {},
    encounters = { grass = {}, water = {}, indoor = {} },
  }
end

-- A session-shaped object with the pieces MapGrid touches, minus the world
-- (rebuildWorldNeighbors is stubbed; grid tests only check data).
local function gridSession(maps, mapId)
  return {
    data = { maps = maps },
    mapId = mapId,
    def = maps[mapId],
    _newMaps = {},
    neighborDirty = {},
    mapChanged = false,
    rebuildNeighbors = function() end,
    rebuildWorldNeighbors = function() end,
  }
end

local function conn(def, dir)
  return (def.connections or {})[dir]
end

local function assertReciprocal(maps, def, where)
  for dir, c in pairs(def.connections or {}) do
    local other = maps[c.map]
    local r = other and (other.connections or {})[BACK[dir]]
    assert(other, where .. ": " .. def.id .. " -> " .. c.map .. " missing def")
    assert(r, where .. ": " .. def.id .. "->" .. c.map .. " missing reciprocal "
      .. tostring(BACK[dir]))
    assert(r.map == def.id, where .. ": reciprocal back-points " .. r.map
      .. " not " .. def.id)
    assert(r.offset == -(c.offset or 0), where .. ": offset mismatch "
      .. (r.offset or 0) .. " vs " .. (-(c.offset or 0)))
  end
end

local function findRect(layout, id)
  for _, r in ipairs(layout) do if r.id == id then return r end end
end

-- BFS over a synthetic graph composes the same strip offsets as
-- Neighbors.compute (north/south shift horizontally, west/east vertically),
-- relative to the root at (0,0).
function test_layoutComposition()
  local maps = {
    A = miniMap("A", 10, 9, {}),
    B = miniMap("B", 10, 18, {}),
    C = miniMap("C", 12, 5, {}),
    D = miniMap("D", 10, 9, {}),
  }
  maps.A.connections.north = { map = "B", offset = 0 }
  maps.A.connections.east = { map = "C", offset = 0 }
  maps.A.connections.south = { map = "D", offset = 3 }
  maps.B.connections.south = { map = "A", offset = 0 }
  maps.C.connections.west = { map = "A", offset = 0 }
  maps.D.connections.north = { map = "A", offset = 3 }

  local layout = MapGrid.layout(maps, "A", math.huge)
  local b, c, d = findRect(layout, "B"), findRect(layout, "C"), findRect(layout, "D")
  assert(b and b.x == 0 and b.y == -18 and b.w == 10 and b.h == 18,
    "B should sit north of A at (0,-18), got "
    .. (b and b.x .. "," .. b.y or "nil"))
  assert(c and c.x == 10 and c.y == 0 and c.w == 12 and c.h == 5,
    "C should sit east of A at (10,0)")
  assert(d and d.x == 3 and d.y == 9 and d.w == 10 and d.h == 9,
    "D should sit south of A at offset 3 -> (3,9)")
  -- Depth limit: layout(..., 1) stops at the root's direct connections.
  local one = MapGrid.layout(maps, "A", 1)
  assert(#one == 1 + 3, "depth-1 layout holds root + 3 direct maps, got " .. #one)
end

-- A lone map offers exactly four open voids (one per side), all scoring one
-- flush neighbour, deduped by position.
function test_candidatesLoneMap()
  local maps = { A = miniMap("A", 10, 9, {}) }
  local s = gridSession(maps, "A")
  local cs = MapGrid.candidates(s, 1)
  assert(#cs == 4, "lone 10x9 map has 4 open voids, got " .. #cs)
  local seen = {}
  for _, c in ipairs(cs) do
    assert(c.conns == 1, "each void touches exactly one map")
    seen[c.bx .. "," .. c.by] = true
  end
  assert(seen["0,-9"] and seen["0,9"] and seen["-10,0"] and seen["10,0"],
    "north/south/west/east voids all present")
end

-- A corner void shared by two maps scores highest (2) and wins the fill.
function test_cornerVoidScoresHighest()
  local maps = {
    A = miniMap("A", 10, 9, {}),
    B = miniMap("B", 10, 9, {}),
    C = miniMap("C", 10, 9, {}),
  }
  maps.A.connections.north = { map = "B", offset = 0 }
  maps.B.connections.south = { map = "A", offset = 0 }
  maps.A.connections.east = { map = "C", offset = 0 }
  maps.C.connections.west = { map = "A", offset = 0 }
  local s = gridSession(maps, "A")
  local corner
  for _, c in ipairs(MapGrid.candidates(s, 1)) do
    if c.bx == 10 and c.by == -9 then corner = c end
  end
  assert(corner, "corner void east-of-B / north-of-C should be a candidate")
  assert(corner.conns == 2, "corner void should touch B and C, got " .. corner.conns)
  local best = MapGrid.bestVoid(s, 1)
  assert(best and best.bx == 10 and best.by == -9,
    "highest-connectivity void wins, got "
    .. (best and best.bx .. "," .. best.by or "nil"))
end

-- Deterministic tie-break: among equal-connectivity voids the lowest bx then
-- lowest by wins (a lone map picks the west void).
function test_bestVoidTieBreak()
  local maps = { A = miniMap("A", 10, 9, {}) }
  local s = gridSession(maps, "A")
  local best = MapGrid.bestVoid(s, 1)
  assert(best, "a lone map always has a best void")
  assert(best.bx == -10 and best.by == 0 and best.dir == "west",
    "lowest bx then by picks the west void, got "
    .. best.bx .. "," .. best.by .. " dir " .. tostring(best.dir))
end

-- expandInDirection creates maps only on the requested side, wiring every map
-- it sits flush against reciprocally (a later create back-fills the earlier
-- map's reciprocal, so the graph never dangles).
function test_expandInDirection()
  local maps = { A = miniMap("A", 10, 9, {}) }
  local s = gridSession(maps, "A")
  assert(MapGrid.expandInDirection(s, "north", 1) == 1, "one north void to fill")
  local north = maps.A_EXT
  assert(north, "north expansion creates A_EXT")
  assert(conn(north, "south") and conn(north, "south").map == "A",
    "A_EXT points back to A")
  assert(conn(maps.A, "north") and conn(maps.A, "north").map == "A_EXT",
    "A points at A_EXT")

  -- West now has two voids: off A and off A_EXT (the corner).
  assert(MapGrid.expandInDirection(s, "west", 1) == 2,
    "west fills both the A and A_EXT west voids")
  assert(maps.A_EXT2 and maps.A_EXT3,
    "both west expansions create maps")
  -- The untouched sides of A stay open.
  assert(not conn(maps.A, "east") and not conn(maps.A, "south"),
    "untouched sides stay open")
  -- The whole graph stays reciprocal after the bulk expansion.
  for _, r in ipairs(MapGrid.layout(maps, "A", math.huge)) do
    assertReciprocal(maps, r.def, "post-" .. r.id)
  end
end

-- createMap rejects overlapping bodies, wires flush neighbours reciprocally,
-- tracks the new def whole for persistence, and marks wired maps dirty.
function test_createMapWiringAndPersistence()
  local maps = { A = miniMap("A", 10, 9, {}) }
  local s = gridSession(maps, "A")
  assert(MapGrid.createMap(s, 0, 0, 10, 9) == nil,
    "overlapping the root is rejected")
  assert(MapGrid.createMap(s, -5, 0, 10, 9) == nil,
    "partially overlapping the root is rejected")
  assert(maps.A_EXT == nil, "no map created for rejected bodies")

  local id = assert(MapGrid.createMap(s, 0, -9, 10, 9),
    "north void is free")
  assert(maps[id] and maps[id].width == 10 and maps[id].height == 9,
    "created map matches the requested footprint")
  assert(s.neighborDirty.A == true,
    "the root gets a reciprocal connection and is marked dirty")
  assert(s.mapChanged, "createMap marks the session changed")
  assert(s._newMaps[id], "new map tracked whole for persistence")
  assert(maps[id] ~= s._newMaps[id],
    "tracked copy is a separate table (deep copy)")
  assert(s._newMaps[id].connections.south
    and s._newMaps[id].connections.south.map == "A",
    "tracked copy carries the reciprocal wiring")
  assertReciprocal(maps, maps[id], "created")
end

-- autofill on a lone map tiles the whole depth-1 ring, reports no void left
-- once full, and never exceeds the safety cap.
function test_autofillDepthLimitedAndStops()
  local maps = { A = miniMap("A", 10, 9, {}) }
  local s = gridSession(maps, "A")
  local created = MapGrid.autofill(s, 1)
  assert(created >= 4, "at least the four root voids fill, got " .. created)
  assert(created <= 64, "autofill must respect its cap, got " .. created)
  assert(MapGrid.fillNextVoid(s, 1) == nil,
    "no depth-1 void remains once autofill finishes")
  for _, r in ipairs(MapGrid.layout(maps, "A", math.huge)) do
    assertReciprocal(maps, r.def, "ring-" .. r.id)
  end
end

-- autofill respects its safety cap even when every fill "succeeds".
function test_autofillRespectsCap()
  local maps = { A = miniMap("A", 10, 9, {}) }
  local s = gridSession(maps, "A")
  local realFill = MapGrid.fillNextVoid
  MapGrid.fillNextVoid = function() return "PALLET_TOWN_EXT" end
  local n = MapGrid.autofill(s, 1)
  MapGrid.fillNextVoid = realFill
  assert(n == 64, "autofill must stop at its 64-map cap, got " .. n)
end

return {
  name = "MAPAMAP_GRID",
  tests = {
    "test_layoutComposition",
    "test_candidatesLoneMap",
    "test_cornerVoidScoresHighest",
    "test_bestVoidTieBreak",
    "test_expandInDirection",
    "test_createMapWiringAndPersistence",
    "test_autofillDepthLimitedAndStops",
    "test_autofillRespectsCap",
  },
}
