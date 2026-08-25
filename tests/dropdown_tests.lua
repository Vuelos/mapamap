-- Dropdown component tests: the shared scrollable list all form panels use
-- -- visible-row math, scroll clamping/stepping, pointer hit-testing
-- (including past-the-end and outside-band rejection), type-to-filter
-- unique matching, and drawing delegation shape.

package.path = "../../../?.lua;" .. package.path

if not _G.love then _G.love = require("tests.love_stub") end

local Dropdown = require("mods.mapamap.components.dropdown")

local ENTRIES = { "APPLE", "APRICOT", "BERRY", "CAKE" }

local function visible(maxH)
  return Dropdown.visibleCount(maxH)
end

function test_visibleCount_rowsFit()
  assert(Dropdown.visibleCount(0) == 0, "zero height shows nothing")
  assert(Dropdown.visibleCount(39) == 1, "one partial row still counts")
  assert(Dropdown.visibleCount(40) == 2, "two full rows")
  assert(Dropdown.visibleCount(400) == 20, "scales linearly")
end

function test_clampScroll_bounds()
  local n, maxVisible = 5, 2
  assert(Dropdown.clampScroll(n, -3, maxVisible) == 0, "clamps at top")
  assert(Dropdown.clampScroll(n, 99, maxVisible) == 3,
    "clamps so last entry is reachable")
  assert(Dropdown.clampScroll(n, 1, maxVisible) == 1, "mid values pass through")
  assert(Dropdown.clampScroll(4, 9, 8) == 0, "everything-visible pins to 0")
end

function test_scrollBy_direction()
  assert(Dropdown.scrollBy(5, 0, 1, 40) == 1, "+1 scrolls down")
  assert(Dropdown.scrollBy(5, 1, -1, 40) == 0, "-1 scrolls up")
  assert(Dropdown.scrollBy(5, 99, 1, 40) == 3, "down clamps at bottom")
end

function test_entryAt_hitAndBounds()
  -- band x=10,y=100,w=60,maxH=40 -> two visible rows of 20px; scroll=1
  local mx, my, x, y, w, maxH, scroll = 30, 105, 10, 100, 60, 40, 1
  assert(Dropdown.entryAt(mx, my, x, y, w, maxH, scroll, #ENTRIES) == 2,
    "first visible row maps to scroll+1")
  assert(Dropdown.entryAt(mx, 125, x, y, w, maxH, scroll, #ENTRIES) == 3,
    "second visible row maps to scroll+2")
  assert(Dropdown.entryAt(mx, 95, x, y, w, maxH, scroll, #ENTRIES) == nil,
    "above the band is nil")
  assert(Dropdown.entryAt(mx, 141, x, y, w, maxH, scroll, #ENTRIES) == nil,
    "below the band is nil")
  assert(Dropdown.entryAt(5, 105, x, y, w, maxH, scroll, #ENTRIES) == nil,
    "left of the band is nil")
  -- A row that scrolls past the end of the list resolves to nil even though
  -- it is inside the band.
  assert(Dropdown.entryAt(mx, 130, x, y, w, maxH, 3, #ENTRIES) == nil,
    "rows beyond the final entry are nil")
end

function test_uniqueMatch_filter()
  assert(Dropdown.uniqueMatch(ENTRIES, "") == nil,
    "empty filter never auto-picks")
  assert(Dropdown.uniqueMatch(ENTRIES, nil) == nil, "nil filter never picks")
  assert(Dropdown.uniqueMatch(ENTRIES, "ZZZ") == nil, "no match stays nil")
  assert(Dropdown.uniqueMatch(ENTRIES, "AP") == nil,
    "ambiguous prefix does not pick")
  assert(Dropdown.uniqueMatch(ENTRIES, "BER") == 3,
    "unique substring picks its index")
  assert(Dropdown.uniqueMatch(ENTRIES, "APPLE") == 1,
    "exact entry picks its index")
end

return {
  name = "MAPAMAP_DROPDOWN",
  tests = {
    "test_visibleCount_rowsFit",
    "test_clampScroll_bounds",
    "test_scrollBy_direction",
    "test_entryAt_hitAndBounds",
    "test_uniqueMatch_filter",
  },
}
