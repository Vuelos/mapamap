-- Toolbar component: a horizontal strip of toggle buttons at the right of
-- the bottom hotbar.  Buttons cycle the editor surfaces: Inventory, Encounters,
-- Borders, Tileset, Blueprint.  The background is dark when the surface is
-- closed and yellow when open.
--
-- The overlay orchestrator calls Toolbar.draw; Input queries Toolbar.at and
-- dispatches through the same handlers that the hotkeys use.

local Hotbar = require("mods.mapamap.components.hotbar")
local Text = require("mods.mapamap.components.text")

local Toolbar = {}

Toolbar.SIZE = Hotbar.SLOT           -- 48 px square, matching a hotbar slot
Toolbar.GAP = Hotbar.GAP             -- 8 px gap between buttons
Toolbar.PAD = Hotbar.PAD             -- 10 px from the hotbar border

-- Each button has a display key and a predicate that reads its on/off state
-- from the Input controller table.
Toolbar.BUTTONS = {
  { key = "I", id = "inventory",  on = function(ui) return ui.showInventory end },
  { key = "N", id = "encounters", on = function(ui) return ui.encEditor end },
  { key = "O", id = "borders",    on = function(ui) return ui.showMapBorders end },
  { key = "P", id = "entities",   on = function(ui) return ui.showEntityOverlays end },
  { key = "E", id = "tileset",    on = function(ui) return ui.showPicker end },
  { key = "R", id = "blueprint",  on = function(ui) return ui.blueprintMode end },
  { key = "M", id = "brushmaker", on = function(ui) return ui.showBrushEditor end },
  { key = "F", id = "factory",    on = function(ui) return ui.showEntitySelector end },
}

-- Colours: yellow when the button's surface is open, dark otherwise.
local ON_COLOR = { 1, 0.85, 0.2, 0.95 }   -- yellow-ish
local OFF_COLOR = { 0.15, 0.15, 0.2, 0.95 } -- dark

-- Bounding rect of the whole toolbar strip, placed flush against the hotbar's
-- right edge, vertically aligned with the hotbar's bottom row.
function Toolbar.rect(vw, vh)
  local hx, hy, hw, hh = Hotbar.rect(vw, vh)
  -- Buttons sit on the same bottom row as the hotbar slots:
  local by = vh - Hotbar.SLOT - Hotbar.PAD
  local bh = Hotbar.SLOT
  local w = Toolbar.PAD * 2 + #Toolbar.BUTTONS * Toolbar.SIZE
            + (#Toolbar.BUTTONS - 1) * Toolbar.GAP
  return hx + hw + Toolbar.GAP, by, w, bh
end

-- Returns the button index (1..#Toolbar.BUTTONS) a screen point falls over,
-- or nil when the point is outside the strip.
function Toolbar.at(vw, vh, mx, my)
  local x, y, w, h = Toolbar.rect(vw, vh)
  if mx < x or mx >= x + w or my < y or my >= y + h then return nil end
  for i = 1, #Toolbar.BUTTONS do
    local bx = x + Toolbar.PAD + (i - 1) * (Toolbar.SIZE + Toolbar.GAP)
    local by = y + Toolbar.PAD
    if mx >= bx and mx < bx + Toolbar.SIZE and my >= by and my < by + Toolbar.SIZE then
      return i
    end
  end
  return nil
end

-- Draws the toolbar strip.  `ui` is the Input controller table whose fields
-- the button predicates read to decide yellow/dark backgrounds.
function Toolbar.draw(ui, vw, vh, font)
  local x, y, w, h = Toolbar.rect(vw, vh)
  -- Dark panel background with a subtle border.
  love.graphics.setColor(0.05, 0.05, 0.08, 0.82)
  love.graphics.rectangle("fill", x, y, w, h)
  love.graphics.setColor(0.5, 0.5, 0.55, 0.4)
  love.graphics.rectangle("line", x, y, w, h)

  local mx, my = love.mouse.getPosition()
  for i = 1, #Toolbar.BUTTONS do
    local b = Toolbar.BUTTONS[i]
    local bx = x + Toolbar.PAD + (i - 1) * (Toolbar.SIZE + Toolbar.GAP)
    local by = y + Toolbar.PAD

    -- Decide the button's fill colour.
    if b.on and b.on(ui) then
      love.graphics.setColor(ON_COLOR[1], ON_COLOR[2], ON_COLOR[3], ON_COLOR[4])
    else
      love.graphics.setColor(OFF_COLOR[1], OFF_COLOR[2], OFF_COLOR[3], OFF_COLOR[4])
    end
    love.graphics.rectangle("fill", bx, by, Toolbar.SIZE, Toolbar.SIZE)

    -- Optional hover border (slightly lighter).
    if mx >= bx and mx < bx + Toolbar.SIZE and my >= by and my < by + Toolbar.SIZE then
      love.graphics.setColor(1, 1, 1, 0.95)
    else
      love.graphics.setColor(0.5, 0.5, 0.55, 0.5)
    end
    love.graphics.rectangle("line", bx, by, Toolbar.SIZE, Toolbar.SIZE)

    -- Center the letter inside the button.
    if font then
      local label = b.key
      local glyphW = (font and font.width and font.width(label)) or (#tostring(label) * 8)
      local tw = glyphW * 2
      local ox = bx + (Toolbar.SIZE - tw) / 2
      local oy = by + (Toolbar.SIZE - 8 * 2) / 2  -- 8px glyph @ scale 2 = 16px tall
      love.graphics.setColor(0.05, 0.05, 0.09, 1)      -- dark ink (readable on both)
      love.graphics.push()
      love.graphics.scale(2, 2)
      font.draw(label, ox / 2, oy / 2)
      love.graphics.pop()
    end
  end
  love.graphics.setColor(1, 1, 1, 1)
end

return Toolbar