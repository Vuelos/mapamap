-- MapGrid unit tests on a synthetic map graph: layout composition (the BFS
-- rects mirror Neighbors.compute's strip offsets), candidate voids (dedup +
-- connectivity scoring), the highest-connectivity pick with a deterministic
-- tie-break, directional expansion, createMap overlap rejection + reciprocal
-- wiring + persistence tracking, and the autofill depth/cap safety.

package.path = "../../../?.lua;" .. package.path

if not _G.love then _G.love = require("tests.love_stub") end

local MapGrid = require("mods.mapamap.func.map_grid")
local Common = require("mods.mapamap.func.common")
local Connections = require("mods.mapamap.domain.connections")

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

-- Every connection on `def` (primary + extras) must mirror back on the far
-- map, with a negated offset (and the same size span).
local function assertReciprocal(maps, def, where)
  for _, dir in ipairs(Common.DIRS) do
    for _, c in ipairs(Connections.connectionsOn(def, dir)) do
      local other = maps[c.map]
      local back = Common.RECIP[dir]
      local r
      for _, rc in ipairs(Connections.connectionsOn(other, back)) do
        if rc.map == def.id then r = rc break end
      end
      assert(other, where .. ": " .. def.id .. " -> " .. c.map .. " missing def")
      assert(r, where .. ": " .. def.id .. "->" .. c.map .. " missing reciprocal "
        .. tostring(back))
      assert(r.map == def.id, where .. ": reciprocal back-points " .. r.map
        .. " not " .. def.id)
      assert(r.offset == -(c.offset or 0), where .. ": offset mismatch "
        .. (r.offset or 0) .. " vs " .. (-(c.offset or 0)))
      assert((r.size or 0) == (c.size or 0), where .. ": size mismatch on "
        .. def.id .. "->" .. c.map)
    end
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

-- A side with a partially-offset connection leaves a seam gap: B hangs off
-- A's south at offset 3 (covering blocks 3-10), so the seam's first 3 blocks
-- are a free gap.
function test_seamGapsPartialCoverage()
  local maps = { A = miniMap("A", 10, 9, {}) }
  maps.B = miniMap("B", 10, 9, {})
  maps.A.connections.south = { map = "B", offset = 3, size = 7 }
  maps.B.connections.north = { map = "A", offset = -3, size = 7 }
  local full = MapGrid.layout(maps, "A", math.huge)
  local rA
  for _, e in ipairs(full) do if e.id == "A" then rA = e end end
  local gaps = MapGrid.seamGaps(full, rA, "south")
  assert(#gaps == 1, "one gap left on A's south seam, got " .. #gaps)
  assert(gaps[1].start == 0 and gaps[1].width == 3,
    "gap should be blocks 0-3, got " .. gaps[1].start .. "+" .. gaps[1].width)
  -- The other seams stay fully free.
  assert(#MapGrid.seamGaps(full, rA, "north") == 1
    and #MapGrid.seamGaps(full, rA, "east") == 1,
    "uncovered seams keep their full gap")
end

-- The seam gap becomes a smaller candidate void that slots into the leftover
-- space, wired as a SECOND connection on A.south (extra) without overlapping
-- B's span, plus a plain reciprocal on B.west.
function test_gapVoidCreatesSecondConnection()
  local maps = { A = miniMap("A", 10, 9, {}) }
  maps.B = miniMap("B", 10, 9, {})
  maps.A.connections.south = { map = "B", offset = 3, size = 7 }
  maps.B.connections.north = { map = "A", offset = -3, size = 7 }
  local s = gridSession(maps, "A")

  local void
  for _, c in ipairs(MapGrid.candidates(s, 1)) do
    if c.bx == 0 and c.by == 9 and c.w == 3 and c.h == 9 then void = c end
  end
  assert(void, "the 3x9 gap void on A's south-west should be a candidate")
  assert(void.conns >= 2, "gap void touches A and B, got " .. void.conns)

  local id = assert(MapGrid.createMap(s, void.bx, void.by, void.w, void.h),
    "gap void should be creatable")
  local g = assert(maps[id], "created map should live in data.maps")
  assert(g.width == 3 and g.height == 9, "gap map keeps its sized footprint")

  -- A keeps B as its primary (first array entry) and stacks G as an extra on
  -- the same side.  The engine-readable connections[dir] is the merged array.
  assert(conn(maps.A, "south") and conn(maps.A, "south")[1].map == "B",
    "B stays the primary south connection")
  assert(maps.A.connectionsExtra and maps.A.connectionsExtra.south
    and maps.A.connectionsExtra.south[1].map == id,
    "G becomes an extra south connection on A")
  -- The spans do not overlap: B covers [3,10], G covers [0,3].
  local bSpan = conn(maps.A, "south")[1].size
  local gSpan = maps.A.connectionsExtra.south[1].size
  assert(bSpan + gSpan <= 10, "connection spans must not overlap ("
    .. bSpan .. "+" .. gSpan .. ")")

  -- G connects back to B on its east (offset 0, full height).
  assert(conn(g, "east") and conn(g, "east").map == "B"
    and conn(g, "east").offset == 0,
    "G should connect east to B at offset 0")
  assert(conn(g, "north") and conn(g, "north").map == "A"
    and conn(g, "north").offset == 0,
    "G should connect north to A at offset 0")
  assertReciprocal(maps, maps.A, "A-with-extra")
  assertReciprocal(maps, g, "G")
end

-- The multi-connection graph stays traversable: layout places both south
-- neighbours (B at offset 3, G at offset 0) and BFS walks the union so G is
-- reachable from the root, exactly where it sits.
function test_layoutTraversesExtraConnections()
  local maps = { A = miniMap("A", 10, 9, {}) }
  maps.B = miniMap("B", 10, 9, {})
  maps.A.connections.south = { map = "B", offset = 3, size = 7 }
  maps.B.connections.north = { map = "A", offset = -3, size = 7 }
  local s = gridSession(maps, "A")
  local id = MapGrid.createMap(s, 0, 9, 3, 9)
  assert(id, "gap map should be creatable")

  local b, g
  for _, r in ipairs(MapGrid.layout(maps, "A", math.huge)) do
    if r.id == "B" then b = r end
    if r.id == id then g = r end
  end
  assert(b and b.x == 3 and b.y == 9,
    "B should sit at (3,9), got " .. (b and b.x .. "," .. b.y or "nil"))
  assert(g and g.x == 0 and g.y == 9 and g.w == 3,
    "G should sit at (0,9) sized 3 wide, got "
    .. (g and g.x .. "," .. g.y .. " " .. g.w .. "x" .. g.h or "nil"))
end

-- The east seam works like the south seam on the vertical axis: a map hung at
-- a vertical offset leaves a y-gap above it, which becomes a sized gap void
-- wired as a second connection on A.east (extra) plus B.north.
function test_gapVoidOnEastSeam()
  local maps = { A = miniMap("A", 10, 9, {}) }
  maps.B = miniMap("B", 10, 9, {})
  maps.A.connections.east = { map = "B", offset = 3, size = 7 }
  maps.B.connections.west = { map = "A", offset = -3, size = 7 }
  local s = gridSession(maps, "A")

  -- A.east's free seam is y in [0,3] above B.
  local full = MapGrid.layout(maps, "A", math.huge)
  local gaps = MapGrid.seamGaps(full, findRect(full, "A"), "east")
  assert(#gaps == 1 and gaps[1].start == 0 and gaps[1].width == 3,
    "A.east should leave one 3-block y-gap, got "
    .. #gaps .. " (" .. (gaps[1] and gaps[1].start .. "+" .. gaps[1].width or "?") .. ")")

  local void
  for _, c in ipairs(MapGrid.candidates(s, 1)) do
    if c.bx == 10 and c.by == 0 and c.w == 10 and c.h == 3 then void = c end
  end
  assert(void, "the 10x3 gap void on A's east should be a candidate")
  assert(void.conns >= 2, "gap void touches A and B, got " .. void.conns)

  local id = assert(MapGrid.createMap(s, void.bx, void.by, void.w, void.h),
    "gap void should be creatable")
  local g = assert(maps[id], "created map should live in data.maps")
  assert(g.width == 10 and g.height == 3, "gap map keeps its sized footprint")

  -- A keeps B as its primary (first array entry); G stacks as an extra.
  assert(conn(maps.A, "east") and conn(maps.A, "east")[1].map == "B",
    "B stays the primary east connection")
  assert(maps.A.connectionsExtra and maps.A.connectionsExtra.east
    and maps.A.connectionsExtra.east[1].map == id,
    "G becomes an extra east connection on A")
  local bSpan = conn(maps.A, "east")[1].size
  local gSpan = maps.A.connectionsExtra.east[1].size
  assert(bSpan + gSpan <= 10, "vertical spans must not overlap ("
    .. bSpan .. "+" .. gSpan .. ")")

  -- G connects west to A and south to B; B reciprocates north to G.
  assert(conn(g, "west") and conn(g, "west").map == "A"
    and conn(g, "west").offset == 0,
    "G should connect west to A at offset 0")
  assert(conn(g, "south") and conn(g, "south").map == "B"
    and conn(g, "south").offset == 0,
    "G should connect south to B at offset 0")
  assert(conn(maps.B, "north") and conn(maps.B, "north").map == id,
    "B should connect north to G")
  assertReciprocal(maps, maps.A, "A-with-extra-east")
  assertReciprocal(maps, g, "G-east")
end

-- autofill closes a partially-covered side by slotting a map into the gap,
-- so no empty space remains beside a hanging map.
function test_autofillClosesPartialSeam()
  local maps = { A = miniMap("A", 10, 9, {}) }
  maps.B = miniMap("B", 10, 9, {})
  maps.A.connections.south = { map = "B", offset = 3, size = 7 }
  maps.B.connections.north = { map = "A", offset = -3, size = 7 }
  local s = gridSession(maps, "A")
  local created = MapGrid.autofill(s, 1)
  assert(created >= 2, "autofill should fill the gap plus more, got " .. created)
  -- The gap is gone: no 3-wide void remains on A's south-west.
  for _, c in ipairs(MapGrid.candidates(s, 1)) do
    assert(not (c.bx == 0 and c.by == 9 and c.w == 3),
      "the gap void should be closed after autofill")
  end
  for _, r in ipairs(MapGrid.layout(maps, "A", math.huge)) do
    assertReciprocal(maps, r.def, "ring-" .. r.id)
  end
end

-- Paint-time void creation: a block 1 step east of A creates a new map flush
-- against A's east seam, sized like A (host-sized, full-seam connections) --
-- not a 1x1 map span, with reciprocal wiring.
function test_createForPaintEastOfA()
  local maps = { A = miniMap("A", 10, 9, {}) }
  local s = gridSession(maps, "A")
  local id = MapGrid.createForPaint(s, 10, 4)
  assert(id, "creating a map 1 block east of A should succeed")
  local m = maps[id]
  assert(m and m.height == 9,
    "created map seam-parallel dimension matches A's height")
  assert(m.width == 10,
    "created map axis-parallel dimension matches A's width (host-sized), got "
      .. tostring(m.width))
  assert(m.connections.west and m.connections.west.map == "A",
    "created map connects west to A")
  assert(conn(maps.A, "east") and conn(maps.A, "east").map == id,
    "A connects east to the created map")
  assertReciprocal(maps, m, "created-east")
end

-- Painting far from any map (no flush contact) is a no-op.
function test_createForPaintFarAway()
  local maps = { A = miniMap("A", 10, 9, {}) }
  local s = gridSession(maps, "A")
  local id = MapGrid.createForPaint(s, 100, 100)
  assert(id == nil, "painting 100 blocks away should not create a map")
end

-- Paint-time rect creation: a 2x2 rect flush east of A creates a single map
-- containing the whole rect.
function test_createForBlocksEastRect()
  local maps = { A = miniMap("A", 10, 9, {}) }
  local s = gridSession(maps, "A")
  local id = MapGrid.createForBlocks(s, 10, 3, 2, 2)
  assert(id, "creating a 2x2 map east of A should succeed")
  local m = maps[id]
  assert(m and m.height == 9,
    "created rect map seam-parallel dimension matches A's height")
  assert(m.width == 2,
    "created rect map axis-parallel dimension spans the 2-block gap, got " .. tostring(m.width))
  assertReciprocal(maps, m, "created-rect-east")
end

-- When the rect is fully covered by existing maps, no creation happens.
function test_createForBlocksFullyCovered()
  local maps = { A = miniMap("A", 10, 9, {}) }
  local s = gridSession(maps, "A")
  local id = MapGrid.createForBlocks(s, 0, 0, 5, 5)
  assert(id == nil, "fully covered rect should not create a map")
end

-- Paint-time west creation: a block 1 step west of A creates a map flush
-- against A's west seam.
function test_createForPaintWestOfA()
  local maps = { A = miniMap("A", 10, 9, {}) }
  local s = gridSession(maps, "A")
  local id = MapGrid.createForPaint(s, -1, 4)
  assert(id, "creating a map 1 block west of A should succeed")
  local m = maps[id]
  assert(m and m.connections.east and m.connections.east.map == "A",
    "created map connects east to A")
  assertReciprocal(maps, m, "created-west")
end

-- A straight drag of several blocks east of A must yield ONE host-sized map,
-- not one 1x1 map per painted block.  After the first cell creates the
-- host-sized map, the rest of the drag falls inside it, so no further maps are
-- created.
function test_paintDragEastOfACreatesSingleMap()
  local maps = { A = miniMap("A", 10, 9, {}) }
  local s = gridSession(maps, "A")
  local id1 = MapGrid.createForPaint(s, 10, 4)
  local id2 = MapGrid.createForPaint(s, 11, 4)
  local id3 = MapGrid.createForPaint(s, 12, 4)
  assert(id1, "first cell creates a map")
  assert(id2 == nil, "second cell is inside the host-sized map; no 2nd map")
  assert(id3 == nil, "third cell is inside the host-sized map; no 3rd map")
  local count = 0
  for _ in pairs(s._newMaps or {}) do count = count + 1 end
  assert(count == 1, "only one map should be created, got " .. count)
  local m = maps[id1]
  assert(m.width == 10 and m.height == 9,
    "the created map is host-sized (10x9), got " .. m.width .. "x" .. m.height)
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
    "test_seamGapsPartialCoverage",
    "test_gapVoidCreatesSecondConnection",
    "test_gapVoidOnEastSeam",
    "test_layoutTraversesExtraConnections",
    "test_autofillClosesPartialSeam",
    "test_createForPaintEastOfA",
    "test_createForPaintFarAway",
    "test_createForBlocksEastRect",
    "test_createForBlocksFullyCovered",
    "test_createForPaintWestOfA",
    "test_paintDragEastOfACreatesSingleMap",
  },
}
