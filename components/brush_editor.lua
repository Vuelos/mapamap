-- Brush Maker panel: a pop-up where a terrain brush is assembled by dragging
-- tiles from the picker/inventory into slot cells.
--
-- Layout: a spatial 5x5 grid.  The core 3x3 (outer corners, edges, center)
-- sits centered; the four inner corners take the panel's own corners
-- (diagonally outside the core corner they refine), the vertical corridor v
-- caps the north axis, the horizontal corridor h ends at the west axis and
-- the isolated slot o closes the east axis -- each optional slot appears at
-- the position it describes.  Every slot except the center is optional;
-- unassigned positions fall back toward the center at paint time
-- (domain/brushes.lua).
--
-- SAVE stores the draft as a { kind = "brush" } inventory item (Brushes tab);
-- CLEAR empties every slot.  The draft itself lives on the Input controller
-- table; this module owns geometry + drawing only.

local Brushes = require("mods.mapamap.domain.brushes")
local Inventory = require("mods.mapamap.components.inventory")
local Item = require("mods.mapamap.components.item")
local Panel = require("mods.mapamap.components.panel")
local Text = require("mods.mapamap.components.text")

local BrushEditor = {}

BrushEditor.SLOT = Inventory.SLOT
BrushEditor.GAP = Inventory.GAP
BrushEditor.GROUP_GAP = 10     -- gap between the slot grid and the buttons
BrushEditor.BUTTON_H = 22

-- Spatial arrangement over TWO stacked layouts so every optional slot sits
-- WHERE it applies:
--   main 5x5 (rows 0-4): the core 3x3 (outer corners, edges, center) centered,
--     the four inner corners on the panel's own corners, diagonally outside
--     the core corner they refine (i_nw beyond NW, ...)
--   line cross (rows 6-10): a complete 5x5 cross for the straight-run family,
--     aligned to the main grid's axes --
--       ln/ls/lw/le  borderless edge runs at the arm tips
--       v / h        1-wide corridors inner on the vertical/horizontal axis
--       o            the isolated (no-join) tile at the cross center
--     The two join positions that do not exist in the model (east-inner and
--     south-inner of the cross) render as dim placeholders so the cross
--     silhouette stays complete.
-- Every slot except the center is optional; unassigned positions fall back
-- toward the center at paint time (domain/brushes.lua).
local LAYOUT = {
  -- main 5x5
  i_nw = { 0, 0 },                           i_ne = { 4, 0 },
                 nw = { 1, 1 }, n = { 2, 1 }, ne = { 3, 1 },
                 w  = { 1, 2 }, c = { 2, 2 }, e  = { 3, 2 },
                 sw = { 1, 3 }, s = { 2, 3 }, se = { 3, 3 },
  i_sw = { 0, 4 },                           i_se = { 4, 4 },
  -- line cross
                                ln = { 2, 6 },
                                v  = { 2, 7 },
  lw   = { 0, 8 }, h = { 1, 8 }, o = { 2, 8 }, le = { 4, 8 },
                                ls = { 2, 10 },
}

-- Placeholder cells: positions of the cross with no tile in the model.
local PLACEHOLDERS = { { 3, 8 }, { 2, 9 } }

-- Fixed draw/hit order (pairs() order is not stable across builds).
local ORDER = {
  "i_nw", "i_ne",
  "nw", "n", "ne",
  "w", "c", "e",
  "sw", "s", "se",
  "i_sw", "i_se",
  "ln", "v", "lw", "h", "o", "le", "ls",
}

BrushEditor.LAYOUT = LAYOUT

-- Rows past the main 5x5 start the line cross: one extra gap separates the
-- layouts.
local GROUP_ROW = 5

-- Panel width fits the 5-slot rows.
local PANEL_W = Panel.PAD * 2 + 5 * Inventory.SLOT + 4 * Inventory.GAP

-- Content height: title row, 11 grid rows (both layouts), buttons, hint.
local function contentH()
  local rowsH = 11 * BrushEditor.SLOT + 10 * BrushEditor.GAP
    + BrushEditor.GROUP_GAP
  return Panel.TITLE_H + Panel.TITLE_GAP + Panel.PAD + rowsH
    + BrushEditor.GROUP_GAP + BrushEditor.BUTTON_H + Panel.PAD + 12
end

-- Panel rect: anchored to the picker's right edge, bottom clamped above the
-- hotbar band.  Sits there whether or not the picker is open so it never
-- jumps around when panels toggle.
function BrushEditor.rect(vw, vh)
  local px, py, pw, ph = Inventory.sideRect(vw, vh)
  local x = px + pw + Inventory.SIDE_GAP
  local h = contentH()
  local y = py + ph - h
  if y < 8 then y = 8 end
  return x, y, PANEL_W, h
end

function BrushEditor.over(vw, vh, mx, my)
  local x, y, w, h = BrushEditor.rect(vw, vh)
  return mx >= x and mx < x + w and my >= y and my < y + h
end

-- Top-left of the core grid.
local function gridOrigin(x, y)
  return x + Panel.PAD, y + Panel.TITLE_H + Panel.TITLE_GAP + Panel.PAD
end

-- The rect of one slot cell by position key, relative to the panel rect.
local function slotRect(x, y, key)
  local cell = LAYOUT[key]
  if not cell then return nil end
  local gx, gy = gridOrigin(x, y)
  local groupGap = cell[2] > GROUP_ROW and BrushEditor.GROUP_GAP or 0
  return gx + cell[1] * (BrushEditor.SLOT + BrushEditor.GAP),
         gy + cell[2] * (BrushEditor.SLOT + BrushEditor.GAP) + groupGap,
         BrushEditor.SLOT, BrushEditor.SLOT
end

-- The position key of the slot under a screen point, or nil.
function BrushEditor.slotKeyAt(vw, vh, mx, my)
  local x, y = BrushEditor.rect(vw, vh)
  if not BrushEditor.over(vw, vh, mx, my) then return nil end
  for _, key in ipairs(ORDER) do
    local sx, sy, sw, sh = slotRect(x, y, key)
    if mx >= sx and mx < sx + sw and my >= sy and my < sy + sh then return key end
  end
  return nil
end

-- Button rects: SAVE / CLEAR / DELETE split the panel's inner width into
-- thirds with gaps between, on the row under the slot layouts.
function BrushEditor.buttonRect(vw, vh, which)
  local x, y = BrushEditor.rect(vw, vh)
  local gx, gy = gridOrigin(x, y)
  local by = gy + 11 * BrushEditor.SLOT + 10 * BrushEditor.GAP
    + BrushEditor.GROUP_GAP + BrushEditor.GROUP_GAP
  local bw = math.floor((PANEL_W - Panel.PAD * 2 - 2 * BrushEditor.GAP) / 3)
  local idx = (which == "save" and 0) or (which == "clear" and 1) or 2
  return gx + idx * (bw + BrushEditor.GAP), by, bw, BrushEditor.BUTTON_H
end

-- Which button ("save"/"clear"/"delete") a screen point is over, or nil.
function BrushEditor.buttonAt(vw, vh, mx, my)
  for _, which in ipairs({ "save", "clear", "delete" }) do
    local bx, by, bw, bh = BrushEditor.buttonRect(vw, vh, which)
    if mx >= bx and mx < bx + bw and my >= by and my < by + bh then
      return which
    end
  end
  return nil
end

-- Draws one slot cell: background, thumbnail, tiny position label, hover ring.
-- The required center gets a yellow border until it is filled.
local function drawSlot(session, draft, key, sx, sy, hoverKey, font)
  love.graphics.setColor(Panel.COLOR_CELL_BG[1], Panel.COLOR_CELL_BG[2],
    Panel.COLOR_CELL_BG[3], Panel.COLOR_CELL_BG[4])
  love.graphics.rectangle("fill", sx, sy, BrushEditor.SLOT, BrushEditor.SLOT)
  local item = Brushes.slot(draft, key)
  if item then
    Item.draw(session, item, sx + 2, sy + 2, BrushEditor.SLOT - 4)
  end
  Text.label(font, Brushes.LABELS[key] or key, sx + 2, sy + 2, 1,
    { bg = Panel.CHIP_HINT, padX = 1, padY = 0 })
  if key == Brushes.REQUIRED and not item then
    love.graphics.setColor(1, 0.85, 0.2, 0.9)
    love.graphics.rectangle("line", sx, sy, BrushEditor.SLOT, BrushEditor.SLOT)
  end
  if hoverKey == key then
    Panel.drawCellHover(sx, sy, BrushEditor.SLOT)
  end
end

-- Draws the panel.  `draft` is the Input-owned brush table being edited;
-- `hasSource` arms the DELETE button (the draft was loaded from a saved
-- brush).
function BrushEditor.draw(session, draft, vw, vh, font, hasSource)
  local x, y, w, h = BrushEditor.rect(vw, vh)
  Panel.drawBg(x, y, w, h)

  local filled = Brushes.filled(draft)
  Panel.drawTitle(font, "BRUSH MAKER " .. tostring(filled), x, y)

  local mx, my = love.mouse.getPosition()
  local hoverKey = BrushEditor.slotKeyAt(vw, vh, mx, my)

  for _, key in ipairs(ORDER) do
    local sx, sy = slotRect(x, y, key)
    drawSlot(session, draft, key, sx, sy, hoverKey, font)
  end
  -- Dim placeholders where the cross has no tile in the model, so the
  -- silhouette reads complete without offering dead slots.
  for _, cell in ipairs(PLACEHOLDERS) do
    local gx, gy = gridOrigin(x, y)
    local px = gx + cell[1] * (BrushEditor.SLOT + BrushEditor.GAP)
    local py = gy + cell[2] * (BrushEditor.SLOT + BrushEditor.GAP)
      + BrushEditor.GROUP_GAP
    love.graphics.setColor(Panel.COLOR_CELL_BG[1], Panel.COLOR_CELL_BG[2],
      Panel.COLOR_CELL_BG[3], 0.4)
    love.graphics.rectangle("fill", px, py, BrushEditor.SLOT, BrushEditor.SLOT)
    love.graphics.setColor(0.4, 0.4, 0.45, 0.35)
    love.graphics.rectangle("line", px, py, BrushEditor.SLOT, BrushEditor.SLOT)
  end
  Panel.resetColor()

  -- Buttons: SAVE (dimmed until the center is assigned), CLEAR, and DELETE
  -- (armed only while the draft is loaded from a saved brush).  Labels run
  -- at 1x so all three fit their thirds.
  local canSave = Brushes.isComplete(draft)
  for _, which in ipairs({ "save", "clear", "delete" }) do
    local bx, by, bw, bh = BrushEditor.buttonRect(vw, vh, which)
    local hovered = BrushEditor.buttonAt(vw, vh, mx, my) == which
    love.graphics.setColor(0.15, 0.15, 0.2, 0.95)
    love.graphics.rectangle("fill", bx, by, bw, bh)
    local border
    if which == "save" and not canSave then
      border = { 0.45, 0.45, 0.5, 0.6 }
    elseif which == "delete" then
      if hasSource then
        border = hovered and { 1, 0.55, 0.45, 1 } or { 1, 0.35, 0.3, 0.9 }
      else
        border = { 0.45, 0.45, 0.5, 0.6 }
      end
    elseif hovered then
      border = { 1, 1, 1, 0.95 }
    else
      border = Panel.COLOR_SEL
    end
    love.graphics.setColor(border[1], border[2], border[3], border[4])
    love.graphics.rectangle("line", bx, by, bw, bh)
    local label = which == "save" and "SAVE"
      or (which == "clear" and "CLEAR" or "DELETE")
    Text.label(font, label, bx + 4, by + 7, 1,
      { bg = Panel.CHIP_TITLE, padX = 2, padY = 1 })
  end

  Panel.drawHint(font, "slots sit where they join - only C is required", x, y, w, h)
  Panel.resetColor()
end

return BrushEditor
