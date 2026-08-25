-- EditOps tests: the placement idioms shared by objects/signs/warps --
-- next-index resolution and the walk-grid bounds check.

package.path = "../../../?.lua;" .. package.path

if not _G.love then _G.love = require("tests.love_stub") end

local EditOps = require("mods.mapamap.domain.edit_ops")

function test_nextIndex_emptyList()
  assert(EditOps.nextIndex(nil) == 1, "nil list starts at 1")
  assert(EditOps.nextIndex({}) == 1, "empty list starts at 1")
end

function test_nextIndex_afterHighest()
  local list = { { index = 1 }, { index = 7 }, { index = 3 } }
  assert(EditOps.nextIndex(list) == 8,
    "the next index follows the highest, not the length")
end

function test_nextIndex_toleratesMissingIndices()
  local list = { {}, { index = 4 }, {} }
  assert(EditOps.nextIndex(list) == 5,
    "entries without an index count as zero")
end

function test_cellIn_walkGridBounds()
  local def = { width = 10, height = 9 } -- 20 x 18 walk cells
  assert(EditOps.cellIn(def, 0, 0), "origin is inside")
  assert(EditOps.cellIn(def, 19, 17), "last cell is inside")
  assert(not EditOps.cellIn(def, 20, 0), "past the east edge is outside")
  assert(not EditOps.cellIn(def, 0, 18), "past the south edge is outside")
  assert(not EditOps.cellIn(def, -1, 5), "negative x is outside")
  assert(not EditOps.cellIn(def, 5, -1), "negative y is outside")
end

return {
  name = "MAPAMAP_EDIT_OPS",
  tests = {
    "test_nextIndex_emptyList",
    "test_nextIndex_afterHighest",
    "test_nextIndex_toleratesMissingIndices",
    "test_cellIn_walkGridBounds",
  },
}
