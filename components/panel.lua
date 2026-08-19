-- Shared panel renderers and geometry helpers used by the overlay's
-- side-panel components (encounter editor, details, picker, inventory).
--
-- Extracts the repeated drawing primitives — panel backgrounds, tab rows,
-- title/hint chips, chevrons, selection/hover highlights — and the geometry
-- helpers (`over`, `hitRow`, `fitText`, `labelWidth`) that every panel
-- duplicates.  Components require this module and call its functions instead
-- of keeping local copies.

local Text = require("mods.mapamap.components.text")

local Panel = {}

-- ---------------------------------------------------------------------------
-- Layout constants (shared across all side panels)

Panel.PAD = 8
Panel.ROW_H = 24
Panel.TITLE_H = 20         -- height of the title chip row
Panel.TITLE_GAP = 6        -- vertical gap between title row and tabs/grid
Panel.TAB_H = 24
Panel.TAB_GAP = 4
Panel.TAB_PAD_X = 1

-- ---------------------------------------------------------------------------
-- Colour palette

Panel.COLOR_PANEL_BG     = { 0, 0, 0, 0.92 }
Panel.COLOR_PANEL_BG_DARK= { 0, 0, 0, 0.85 }
Panel.COLOR_PANEL_BORDER = { 0.55, 0.55, 0.6, 0.5 }
Panel.COLOR_DROPDOWN_BG  = { 0, 0, 0, 0.94 }
Panel.COLOR_SEL          = { 0.25, 0.5, 1, 0.9 }
Panel.COLOR_HOVER        = { 1, 1, 1, 0.9 }
Panel.COLOR_HOVER_CELL   = { 1, 1, 1, 0.95 }
Panel.COLOR_CELL_BG      = { 0.2, 0.2, 0.24, 0.9 }
Panel.COLOR_CELL_BG2     = { 0.22, 0.22, 0.26, 0.92 }
Panel.COLOR_CHEVRON      = { 0.05, 0.05, 0.09, 1 }

-- Chip backgrounds for Text.label `bg` opts.
Panel.CHIP_TITLE  = { 0.92, 0.92, 0.95, 0.95 }
Panel.CHIP_ROW    = { 0.85, 0.85, 0.9, 0.9 }
Panel.CHIP_VALUE  = { 0.92, 0.92, 0.95, 0.95 }
Panel.CHIP_EDIT   = { 1, 1, 0.8, 0.95 }
Panel.CHIP_HINT   = { 0.2, 0.2, 0.25, 0.9 }

-- ---------------------------------------------------------------------------
-- Text helpers

-- Truncates `s` to fit `budgetPx` of screen width at `scale`, appending "..."
-- when clipped.  Used by every panel that renders label chips.
function Panel.fitText(font, s, budgetPx, scale)
  scale = scale or 2
  local function w(t)
    return ((font.width and font.width(t)) or (#t * 8)) * scale
  end
  if w(s) <= budgetPx then return s end
  while #s > 0 and w(s) > budgetPx do s = s:sub(1, #s - 1) end
  return s .. "..."
end

-- Scaled (2x) width of a label string in screen units, matching Text.label's
-- width math so buttons/tabs hug their drawn chips.
function Panel.labelWidth(font, label)
  local glyphW = (font and font.width and font.width(label))
    or (#tostring(label) * 8)
  return glyphW * 2
end

-- ---------------------------------------------------------------------------
-- Panel background drawing

-- Draws the standard dark panel background (fill + border).
-- `alpha` defaults to 0.92; pass 0.85 for the inventory's variant.
function Panel.drawBg(x, y, w, h, alpha)
  local a = alpha or 0.92
  love.graphics.setColor(0, 0, 0, a)
  love.graphics.rectangle("fill", x, y, w, h)
  love.graphics.setColor(0.55, 0.55, 0.6, 0.5)
  love.graphics.rectangle("line", x, y, w, h)
end

-- Draws the dropdown/pop-up background (slightly more opaque).
function Panel.drawDropdownBg(x, y, w, h)
  love.graphics.setColor(0, 0, 0, 0.94)
  love.graphics.rectangle("fill", x, y, w, h)
  love.graphics.setColor(0.55, 0.55, 0.6, 0.5)
  love.graphics.rectangle("line", x, y, w, h)
end

-- ---------------------------------------------------------------------------
-- Title / hint chips

-- Draws the title chip at the top of a panel.  `text` is the title string.
function Panel.drawTitle(font, text, x, y)
  Text.label(font, text, x + Panel.PAD, y + 6, 2, {
    bg = Panel.CHIP_TITLE, padX = 3, padY = 2,
  })
end

-- Returns the Y coordinate just below the title row + gap.  Pass the panel's
-- top Y (`y` from `rect()`).  Tabs and grid content should start at this Y.
function Panel.titleBottom(y)
  return y + Panel.TITLE_H + Panel.TITLE_GAP
end

-- Draws the hint/footer bar at the bottom of a panel.
function Panel.drawHint(font, hint, x, y, w, h)
  Text.label(font, Panel.fitText(font, hint, w - Panel.PAD * 2, 1),
    x + Panel.PAD, y + h - Panel.PAD - 8, 1,
    { bg = Panel.CHIP_HINT, padX = 2, padY = 1 })
end

-- ---------------------------------------------------------------------------
-- Tab row geometry

-- Computes the bounding rect for tab `i` (1-based) from a flat array of
-- `{ label = "..." }` entries.  Returns `nil` when `i` is out of range.
function Panel.tabRect(tabs, panelX, panelY, font, i)
  if i < 1 or i > #tabs then return nil end
  local tx = panelX + Panel.PAD
  for j = 1, i - 1 do
    tx = tx + Panel.labelWidth(font, tabs[j].label)
           + Panel.TAB_PAD_X * 2 + Panel.TAB_GAP
  end
  local tw = Panel.labelWidth(font, tabs[i].label) + Panel.TAB_PAD_X * 2
  return tx, panelY + Panel.PAD, tw, Panel.TAB_H
end

-- Which tab (1-based) a screen point is over, or nil.
function Panel.tabAt(tabs, panelX, panelY, font, mx, my)
  for i = 1, #tabs do
    local tx, ty, tw, th = Panel.tabRect(tabs, panelX, panelY, font, i)
    if tx and mx >= tx and mx < tx + tw and my >= ty and my < ty + th then
      return i
    end
  end
  return nil
end

-- Draws a tab row: one chip per tab, blue outline on the active tab, white
-- outline on hover.  `activeTab` is the currently-selected tab index.
function Panel.drawTabs(tabs, panelX, panelY, font, activeTab, mx, my)
  local hoverTab = Panel.tabAt(tabs, panelX, panelY, font, mx, my)
  for i = 1, #tabs do
    local tx, ty, tw, th = Panel.tabRect(tabs, panelX, panelY, font, i)
    if tx then
      Text.label(font, tabs[i].label, tx + 4, ty + 3, 2, {
        bg = Panel.CHIP_TITLE, padX = 2, padY = 1,
      })
      if i == activeTab then
        love.graphics.setColor(Panel.COLOR_SEL[1], Panel.COLOR_SEL[2],
          Panel.COLOR_SEL[3], Panel.COLOR_SEL[4])
        love.graphics.rectangle("line", tx + 1, ty + 1, tw - 2, th - 2)
      elseif hoverTab == i then
        love.graphics.setColor(Panel.COLOR_HOVER[1], Panel.COLOR_HOVER[2],
          Panel.COLOR_HOVER[3], Panel.COLOR_HOVER[4])
        love.graphics.rectangle("line", tx + 1, ty + 1, tw - 2, th - 2)
      end
    end
  end
end

-- ---------------------------------------------------------------------------
-- Hit-testing

-- True when (mx, my) is inside a panel rect returned by `rectFn(vw, vh)`.
function Panel.over(rectFn, vw, vh, mx, my)
  local x, y, w, h = rectFn(vw, vh)
  return mx >= x and mx < x + w and my >= y and my < y + h
end

-- Row index under (mx, my) given a panel rect and a `rowTopY` (the Y of the
-- first row).  Returns nil when outside the rows area.
function Panel.hitRow(vw, vh, mx, my, rectFn, rowTopY, rowH)
  local x, y, w, h = rectFn(vw, vh)
  if mx < x or mx >= x + w or my < y or my >= y + h then return nil end
  if my < rowTopY then return nil end
  local n = math.floor((my - rowTopY) / rowH) + 1
  if n < 1 then return nil end
  return n
end

-- ---------------------------------------------------------------------------
-- Drawing helpers

-- Selection highlight (blue outline) on a rectangular region.
function Panel.drawSel(x, y, w, h)
  love.graphics.setColor(Panel.COLOR_SEL[1], Panel.COLOR_SEL[2],
    Panel.COLOR_SEL[3], Panel.COLOR_SEL[4])
  love.graphics.rectangle("line", x, y, w, h)
end

-- Hover highlight (white outline) on a rectangular region.
function Panel.drawHover(x, y, w, h)
  love.graphics.setColor(Panel.COLOR_HOVER[1], Panel.COLOR_HOVER[2],
    Panel.COLOR_HOVER[3], Panel.COLOR_HOVER[4])
  love.graphics.rectangle("line", x, y, w, h)
end

-- Cell hover highlight (white outline, 1px outset).
function Panel.drawCellHover(x, y, size)
  love.graphics.setColor(Panel.COLOR_HOVER_CELL[1], Panel.COLOR_HOVER_CELL[2],
    Panel.COLOR_HOVER_CELL[3], Panel.COLOR_HOVER_CELL[4])
  love.graphics.rectangle("line", x - 1, y - 1, size + 2, size + 2)
end

-- Down-chevron polygon for dropdown buttons.  Draws at the right edge of a
-- region of width `w` starting at (x, y) with height `h`.
function Panel.drawChevron(x, y, w, h)
  love.graphics.setColor(Panel.COLOR_CHEVRON[1], Panel.COLOR_CHEVRON[2],
    Panel.COLOR_CHEVRON[3], Panel.COLOR_CHEVRON[4])
  love.graphics.polygon("fill",
    x + w - 16, y + 6,
    x + w - 8,  y + 6,
    x + w - 12, y + h - 7)
end

-- Resets the draw colour to white (safe default after drawing helpers).
function Panel.resetColor()
  love.graphics.setColor(1, 1, 1, 1)
end

-- ---------------------------------------------------------------------------
-- Dropdown button + list renderers
--
-- Two shared helpers that abstract the species dropdown (encounter editor)
-- and the tileset dropdown (picker).  Each component still owns its own
-- state (open/closed, scroll, filter) and hit-testing; these functions
-- handle the drawing only.

-- Renders a dropdown trigger button: a label chip on the left, a chevron on
-- the right, and a blue highlight when `isOpen` or hovered.  `btnX/btnY/
-- btnW/btnH` define the button rect; `label` is the display text; `font` is
-- the active font; `mx, my` the mouse position (for hover detection).
function Panel.renderDropdownButton(font, label, btnX, btnY, btnW, btnH,
                                    mx, my, isOpen, scale)
  scale = scale or 2
  Text.label(font, Panel.fitText(font, label, btnW - 24, scale),
    btnX + 4, btnY + 3, scale, { bg = Panel.CHIP_VALUE, padX = 3, padY = 2 })
  Panel.drawChevron(btnX, btnY, btnW, btnH)
  if isOpen or (mx >= btnX and mx < btnX + btnW
                and my >= btnY and my < btnY + btnH) then
    Panel.drawSel(btnX, btnY, btnW, btnH)
  end
  Panel.resetColor()
end

-- Renders an open dropdown list: a dark background, then one chip per
-- visible entry with selection (blue) and hover (white) highlights.
--
-- `listX, listY, listW, listH` — bounding rect of the open list.
-- `entries` — array of `{ label = "..." }`.
-- `firstVis, numVis` — 1-based index of the first visible entry and how
--   many rows fit (entries[firstVis .. firstVis+numVis-1] are drawn).
-- `selIdx` — 1-based index of the currently-selected entry (blue outline),
--   or nil for none.
-- `hoverIdx` — 1-based index of the hovered entry (white outline), or nil.
-- `rowH` — height of each row (default Panel.ROW_H).
function Panel.renderDropdownList(font, listX, listY, listW, listH,
                                  entries, firstVis, numVis, selIdx, hoverIdx,
                                  rowH)
  rowH = rowH or Panel.ROW_H
  Panel.drawDropdownBg(listX, listY, listW, listH)
  for i = 0, numVis - 1 do
    local idx = firstVis + i
    local e = entries[idx]
    if not e then break end
    local ey = listY + i * rowH
    local label = e.label or e[1] or "?"
    Text.label(font, Panel.fitText(font, label, listW - 12, 2),
      listX + 4, ey + 2, 2, { bg = Panel.CHIP_VALUE, padX = 2, padY = 1 })
    if idx == selIdx then
      Panel.drawSel(listX + 1, ey + 1, listW - 2, rowH - 2)
    elseif idx == hoverIdx then
      Panel.drawHover(listX + 1, ey + 1, listW - 2, rowH - 2)
    end
  end
  Panel.resetColor()
end

return Panel
