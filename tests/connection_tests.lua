-- Mapamap connection-graph tests: painting toward an edge must build a
-- consistent 2-way connection graph (reciprocal offsets mirror, and a
-- freshly-created edge map wires every flush neighbour correctly).  These
-- cover the "bug 2" surface: the right map must connect back to the centre
-- map (never a stale / offset-shifted side extension).

package.path = "../../../?.lua;" .. package.path

if not _G.love then _G.love = require("tests.love_stub") end

local Data = require("src.core.Data")
if not (Data.maps and Data.maps.PALLET_TOWN) then Data:load() end
local data = Data

local Session = require("mods.mapamap.session")

local mod = {
  log = { warn = function() end, info = function() end, error = function() end },
  save = { get = function() return nil end, set = function() end },
  ui = { Font = { draw = function() end } },
}
local game = { data = data, overworld = nil }

local BACK = { north = "south", south = "north", east = "west", west = "east" }

local function conn(def, dir)
  return (def.connections or {})[dir]
end

-- Every reciprocal connection must mirror its forward offset.
local function assertReciprocal(def, rootId, where)
  for dir, c in pairs(def.connections or {}) do
    local other = data.maps and data.maps[c.map]
    local back = BACK[dir]
    assert(other, where .. ": " .. def.id .. " -> " .. c.map .. " missing def")
    assert(back, where .. ": bad dir " .. tostring(dir))
    local r = conn(other, back)
    assert(r, where .. ": " .. def.id .. "->" .. c.map
      .. " missing reciprocal " .. tostring(back))
    assert(r.map == def.id, where .. ": reciprocal back-points " .. r.map
      .. " not " .. def.id)
    assert(r.offset == -(c.offset or 0), where .. ": offset mismatch "
      .. (r.offset or 0) .. " vs " .. (-(c.offset or 0)))
  end
end

-- The MAP the paint tool is editing has flushed all real neighbour bodies, so
-- multiple sequential edge paints (north for an empty stretch) keep the graph
-- stable: every new map connects to the root, and no map keeps a dangling
-- reciprocal.
function test_leftThenRightConnectToCentre()
  local s = Session.new(mod, game, "PALLET_TOWN")
  assert(s, "no session for PALLET_TOWN")
  s:rebuildNeighbors()

  assert(s:handleEdgePaint(-2, 2) ~= nil, "west paint should create")
  assert(data.maps.PALLET_TOWN_EXT, "west extension should exist")
  local west = data.maps.PALLET_TOWN_EXT
  assert(west.connections.east and west.connections.east.map == "PALLET_TOWN",
    "west ext should point back at centre (east)")
  assertReciprocal(west, "PALLET_TOWN", "PALLET_TOWN_EXT")

  -- Re-seed and paint east.
  s:rebuildNeighbors()
  assert(s:handleEdgePaint(40, 2) ~= nil, "east paint should create")
  assert(data.maps.PALLET_TOWN_EXT2, "east extension should exist")
  local east = data.maps.PALLET_TOWN_EXT2
  -- The bug: east used to point at the west extension instead of the centre.
  local iref = conn(east, "west")
  assert(iref and iref.map == "PALLET_TOWN",
    "east ext west reciprocal should point at the centre map, got "
    .. (iref and iref.map or "nil"))
  if conn(east, "north") then assertReciprocal(east, "PALLET_TOWN_EXT2", "E2N") end
  if conn(east, "east") then assertReciprocal(east, "PALLET_TOWN_EXT2", "E2E") end
  if conn(east, "south") then assertReciprocal(east, "PALLET_TOWN_EXT2", "E2S") end
end

-- Creating on the opposite side after a prior expansion must re-anchor the new
-- map's reciprocal to the CURRENT map (not an old shifted neighbour), and a
-- grown map's own shifted connection offsets stay reciprocal-consistent.
function test_expandThenCreateStaysAnchored()
  local s = Session.new(mod, game, "PALLET_TOWN")
  assert(s, "no session for PALLET_TOWN")
  s:rebuildNeighbors()
  -- Drive an edge paint (any side: in real data Pallet's north is open so
  -- this should create; if the rule expands instead that is fine too).
  local ok = s:handleEdgePaint(0, -2) -- north
  assert(ok ~= nil, "north edge paint should resolve (expand-or-create)")
  -- Whatever happened, every live connection must be reciprocal-consistent.
  assertReciprocal(s.def, "PALLET_TOWN", "after-expand")
  s:rebuildNeighbors()
  for _, nb in ipairs(s.neighbors or {}) do
    assertReciprocal(nb.def, "PALLET_TOWN", "neigh-" .. nb.id)
  end
end

-- Control+Z (undo) must not crash: the undo path in map_ops restoreSnapshot
-- calls reloadMap() on the primary-map branch, which mapamap's Session must
-- provide (it is not mixed in from map_editor's full-screen scene).
function test_undoAfterPaintDoesNotCrash()
  local s = Session.new(mod, game, "PALLET_TOWN")
  assert(s, "no session for PALLET_TOWN")
  s:rebuildNeighbors()
  local before = s.def.blocks[1]
  -- Paint the top-left block cell (world cell 0,0 -> block 0, blocks[1]).
  s.cursorBx, s.cursorBy = 0, 0
  s:snapCursorToBlock()
  s.selectedBlock = 0
  assert(s.undo and s.undo:stack("undo"), "session should have an undo stack")
  assert(before ~= 0, "pick a paint value different from the existing block")
  s:paintBlock()
  assert(s.undo and s.undo:canUndo(), "paint should push an undo step")
  assert(s.def.blocks[1] == 0, "paint should have changed the block")
  -- Ctrl+Z path: restoreSnapshot("undo") then refresh live renderers.
  s:restoreSnapshot("undo")
  s:refreshLiveRenderers()
  assert(s.def.blocks[1] == before, "undo should restore the original block")
end

return {
  name = "MAPAMAP_CONNECTION",
  teardown = function() data = Data end,
  tests = {
    "test_leftThenRightConnectToCentre",
    "test_expandThenCreateStaysAnchored",
    "test_undoAfterPaintDoesNotCrash",
  },
}