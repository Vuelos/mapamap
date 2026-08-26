-- Toolbar component: a horizontal strip of toggle buttons at the right of
-- the bottom hotbar.  Buttons cycle the editor surfaces: Inventory, Encounters,
-- Borders, Tileset, Blueprint.  The background is dark when the surface is
-- closed and yellow when open.
--
-- The overlay orchestrator calls Toolbar.draw; Input queries Toolbar.at and
-- dispatches through the same handlers that the hotkeys use.

local Hotbar = require("mods.mapamap.components.hotbar")
local Text = require("mods.mapamap.components.text")
local Gui = require("mods.mapamap.components.gui")

local Toolbar = {}

-- Base metrics at scale 1 (the default window tier).
Toolbar.SIZE = 48
Toolbar.GAP = 8
Toolbar.PAD = 10

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
  { key = "V", id = "slots",      on = function(ui) return ui.slotsOpen end },
}

-- Colours: yellow when the button's surface is open, dark otherwise.
local ON_COLOR = { 1, 0.85, 0.2, 0.95 }   -- yellow-ish
local OFF_COLOR = { 0.15, 0.15, 0.2, 0.95 } -- dark

-- Layout: buttons flow left-to-right in rows.  Wide windows place the strip
-- BESIDE the hotbar's right edge (bottom row aligned); narrow windows wrap
-- it into a compact grid ABOVE the hotbar, right-aligned -- either way it
-- never runs off-screen.  Returns per-button rects plus the union box.
function Toolbar.layout(vw, vh)
  local s = Gui.s(vw, vh)
  local size = math.max(22, math.floor(Toolbar.SIZE * s))
  local gap = math.max(2, math.floor(Toolbar.GAP * s))
  local pad = math.max(2, math.floor(Toolbar.PAD * s))
  local n = #Toolbar.BUTTONS
  local hbX, hbY, hbW = Hotbar.rect(vw, vh)
  local besideX = hbX + hbW + gap
  local availBeside = vw - 8 - besideX

  local cols, x0, baseTop, dir
  if availBeside >= size + pad then
    -- Budget: leading hotbar gap + per-column stride + trailing pad must
    -- stay inside the window (the union box pads both sides).
    cols = math.max(1, math.min(n,
      math.floor((availBeside - pad) / (size + gap))))
    x0 = besideX + pad
    baseTop = vh - size - pad   -- bottom row aligns with the hotbar
    dir = -1                    -- extra rows stack UPWARD
  else
    -- Narrow window: compact grid pinned to the TOP-RIGHT corner (clear of
    -- the inventory column below and any docked side panel).
    cols = math.max(1, math.floor((vw - 2 * pad + gap) / (size + gap)))
    cols = math.min(cols, n)
    x0 = vw - pad - cols * (size + gap) + gap
    baseTop = pad
    dir = 1                     -- extra rows stack DOWNWARD
  end
  local rows = math.ceil(n / cols)

  local rects, union = {}, nil
  for i = 1, n do
    local row = math.floor((i - 1) / cols)          -- 0 = first row
    local col = (i - 1) % cols
    local bx = x0 + col * (size + gap)
    local by = baseTop + dir * row * (size + gap)
    rects[i] = { x = bx, y = by, w = size, h = size }
    if union then
      union.x = math.min(union.x, bx)
      union.y = math.min(union.y, by)
      union.r = math.max(union.r, bx + size)
      union.b = math.max(union.b, by + size)
    else
      union = { x = bx, y = by, r = bx + size, b = by + size }
    end
  end
  return rects,
    { x = union.x - pad, y = union.y - pad,
      w = union.r - union.x + pad * 2, h = union.b - union.y + pad * 2 },
    pad
end

-- Union bounding rect of the whole toolbar strip.
function Toolbar.rect(vw, vh)
  local _, box = Toolbar.layout(vw, vh)
  return box.x, box.y, box.w, box.h
end

-- Which button index (1..#BUTTONS) a screen point falls over, or nil.
function Toolbar.at(vw, vh, mx, my)
  local rects = Toolbar.layout(vw, vh)
  for i, r in ipairs(rects) do
    if mx >= r.x and mx < r.x + r.w and my >= r.y and my < r.y + r.h then
      return i
    end
  end
  return nil
end

-- Draws the toolbar strip.  `ui` is the Input controller table whose fields
-- the button predicates read to decide yellow/dark backgrounds.
function Toolbar.draw(ui, vw, vh, font)
  local rects, box, pad = Toolbar.layout(vw, vh)
  love.graphics.setColor(0.05, 0.05, 0.08, 0.82)
  love.graphics.rectangle("fill", box.x, box.y, box.w, box.h)
  love.graphics.setColor(0.5, 0.5, 0.55, 0.4)
  love.graphics.rectangle("line", box.x, box.y, box.w, box.h)

  local mx, my = love.mouse.getPosition()
  for i, b in ipairs(Toolbar.BUTTONS) do
    local r = rects[i]
    if b.on and b.on(ui) then
      love.graphics.setColor(ON_COLOR[1], ON_COLOR[2], ON_COLOR[3], ON_COLOR[4])
    else
      love.graphics.setColor(OFF_COLOR[1], OFF_COLOR[2], OFF_COLOR[3],
        OFF_COLOR[4])
    end
    love.graphics.rectangle("fill", r.x, r.y, r.w, r.h)

    if mx >= r.x and mx < r.x + r.w and my >= r.y and my < r.y + r.h then
      love.graphics.setColor(1, 1, 1, 0.95)
    else
      love.graphics.setColor(0.5, 0.5, 0.55, 0.5)
    end
    love.graphics.rectangle("line", r.x, r.y, r.w, r.h)

    -- Center the letter inside the button.
    if font then
      local label = b.key
      local glyphW = (font.width and font.width(label)) or (#label * 8)
      local tw = glyphW * 2
      local ox = r.x + (r.w - tw) / 2
      local oy = r.y + (r.h - 16) / 2
      love.graphics.setColor(0.05, 0.05, 0.09, 1)
      love.graphics.push()
      love.graphics.scale(2, 2)
      font.draw(label, ox / 2, oy / 2)
      love.graphics.pop()
    end
  end
  love.graphics.setColor(1, 1, 1, 1)
end

return Toolbar