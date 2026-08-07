-- Hotbar component: the 8-slot square strip along the bottom of the screen.
-- Owns its geometry (slot rects, hit-testing) and its draw routine, so the
-- overlay orchestrator only calls hotbar.draw and input queries hotbar.at.

local Common = require("mods.mapamap.func.common")
local Item = require("mods.mapamap.components.item")

local Hotbar = {}

Hotbar.SLOTS = 8
Hotbar.SLOT = 48          -- square slot size
Hotbar.GAP = 8            -- gap between slots
Hotbar.PAD = 10           -- clearance from the bottom edge

local function boxMetrics(vw)
  local totalW = Hotbar.SLOTS * Hotbar.SLOT + (Hotbar.SLOTS - 1) * Hotbar.GAP
  return math.floor((vw - totalW) / 2), totalW
end

-- The slot rect for index i (1..SLOTS), or nil.
function Hotbar.slot(i, vw, vh)
  if i < 1 or i > Hotbar.SLOTS then return nil end
  local x0 = boxMetrics(vw)
  local x = x0 + (i - 1) * (Hotbar.SLOT + Hotbar.GAP)
  local y = vh - Hotbar.SLOT - Hotbar.PAD
  return x, y, Hotbar.SLOT, Hotbar.SLOT
end

-- Bounding rect of the whole hotbar strip.
function Hotbar.rect(vw, vh)
  local x0, totalW = boxMetrics(vw)
  local y = vh - Hotbar.SLOT - Hotbar.PAD
  return x0 - Hotbar.PAD, y - Hotbar.PAD, totalW + Hotbar.PAD * 2, Hotbar.SLOT + Hotbar.PAD * 2
end

-- Which slot (1..SLOTS) a screen point is over, or nil.
function Hotbar.at(vw, vh, mx, my)
  for i = 1, Hotbar.SLOTS do
    local x, y, w, h = Hotbar.slot(i, vw, vh)
    if mx >= x and mx < x + w and my >= y and my < y + h then return i end
  end
  return nil
end

-- Draws the hotbar.  `slots` is the item array (Input.hotbar), `selected` the
-- active index, `font` the UI font.
function Hotbar.draw(session, vw, vh, slots, selected, font)
  local hx, hy, hw, hh = Hotbar.rect(vw, vh)
  love.graphics.setColor(0.05, 0.05, 0.08, 0.82)
  love.graphics.rectangle("fill", hx, hy, hw, hh)
  love.graphics.setColor(0.5, 0.5, 0.55, 0.4)
  love.graphics.rectangle("line", hx, hy, hw, hh)

  for i = 1, Hotbar.SLOTS do
    local x, y, w, h = Hotbar.slot(i, vw, vh)
    local item = slots[i]
    love.graphics.setColor(0.2, 0.2, 0.24, 0.9)
    love.graphics.rectangle("fill", x, y, w, h)
    if i == selected then
      love.graphics.setColor(1, 1, 1, 0.95)
      love.graphics.rectangle("line", x - 1, y - 1, w + 2, h + 2)
    else
      love.graphics.setColor(0.6, 0.6, 0.65, 0.5)
      love.graphics.rectangle("line", x, y, w, h)
    end
    if item then
      local pad = 3
      local size = h - pad * 2
      Item.draw(session, item, x + pad, y + pad, size)
      if font then font.draw(tostring(i), x + 2, y + 1) end
    end
  end
  love.graphics.setColor(1, 1, 1, 1)
end

return Hotbar