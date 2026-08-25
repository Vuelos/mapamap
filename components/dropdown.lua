-- Dropdown: the shared scrollable picker list used by the side-panel forms
-- (party editor, entity creator, encounter editor).
--
-- A panel owns its state (`{ list = <catalog key>, anchorY = <px>,
-- scroll = 0, filter = "" }` plus whatever identifies the target field) and
-- resolves the ENTRIES array itself; this module owns everything generic --
-- hit-testing, scroll clamping, type-to-filter unique matching and drawing --
-- so each panel drops roughly a hundred duplicated lines.
--
-- Geometry contract: the panel calls dropRect-style math itself to get an
-- (x, y, w, maxH) band directly below the anchoring row, then:
--   * maxVisible = Dropdown.visibleCount(maxH)
--   * scroll     = Dropdown.clampScroll(#entries, scroll, maxVisible)
--   * pick       = Dropdown.entryAt(mx, my, x, y, w, maxH, scroll, #entries)
--   * match      = Dropdown.uniqueMatch(entries, filter)  (nil unless exactly one)
--   * Dropdown.draw(font, entries, x, y, w, maxH, scroll, selIdx, hoverIdx)

local Panel = require("mods.mapamap.components.panel")

local Dropdown = {}

Dropdown.H = 20   -- row height inside the list

function Dropdown.visibleCount(maxH)
  return math.floor((maxH or 0) / Dropdown.H)
end

function Dropdown.clampScroll(n, scroll, maxVisible)
  return math.max(0, math.min(scroll or 0, math.max(0, n - maxVisible)))
end

-- The absolute entry index under the pointer, or nil.
function Dropdown.entryAt(mx, my, x, y, w, maxH, scroll, n)
  if mx < x or mx >= x + w or my < y or my >= y + maxH then return nil end
  local row = math.floor((my - y) / Dropdown.H) + 1
  local maxVisible = Dropdown.visibleCount(maxH)
  if row < 1 or row > maxVisible then return nil end
  local idx = (scroll or 0) + row
  return (idx >= 1 and idx <= n) and idx or nil
end

-- Type-to-filter: returns the index of the single matching entry, or nil
-- when nothing (or more than one thing) matches.
function Dropdown.uniqueMatch(entries, filter)
  if not filter or filter == "" then return nil end
  local hits = {}
  for k, s in ipairs(entries) do
    if tostring(s):find(filter, 1, true) then hits[#hits + 1] = k end
  end
  return (#hits == 1) and hits[1] or nil
end

-- Wheel step over an open list.
function Dropdown.scrollBy(n, scroll, dy, maxH)
  local maxVisible = Dropdown.visibleCount(maxH)
  return Dropdown.clampScroll(n, (scroll or 0) + dy, maxVisible)
end

function Dropdown.draw(font, entries, x, y, w, maxH, scroll, selIdx, hoverIdx)
  local maxVisible = Dropdown.visibleCount(maxH)
  local list = {}
  for k = 1, maxVisible do
    local id = entries[(scroll or 0) + k]
    if not id then break end
    list[k] = { label = id }
  end
  Panel.renderDropdownList(font, x, y, w, maxH, list,
    (scroll or 0) + 1, maxVisible, selIdx, hoverIdx, Dropdown.H)
end

return Dropdown
