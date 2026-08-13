-- Blueprint book component: the centered strip above the hotbar listing
-- captured block grids, plus the rectangle-select capture overlay.
--
-- Owns its layout and the book panel draw; the capture-selection overlay that
-- draws over the world sits in the overlay orchestrator since it needs the
-- live camera transform (Coords).

local Item = require("mods.mapamap.components.item")
local Inventory = require("mods.mapamap.components.inventory")
local Text = require("mods.mapamap.components.text")

local Blueprints = {}

Blueprints.SLOT = 48
Blueprints.GAP = 6
Blueprints.PAD = 10
Blueprints.HEAD = 40   -- matches the picker's header row height

-- Truncates a label to fit `budgetPx` once drawn at `scale`.
local function fitText(font, s, budgetPx, scale)
  scale = scale or 2
  local function w(t)
    return ((font.width and font.width(t)) or (#t * 8)) * scale
  end
  if w(s) <= budgetPx then return s end
  while #s > 0 and w(s) > budgetPx do s = s:sub(1, #s - 1) end
  return s .. "..."
end

-- Panel rect: the same size as the inventory, sitting at its right side.
function Blueprints.rect(vw, vh)
  return Inventory.sideRect(vw, vh)
end

-- Entries per page (a single row), based on the side panel width.
function Blueprints.perPage(vw, vh)
  local _, _, w = Inventory.sideRect(vw, vh)
  return math.max(1, math.floor((w - Blueprints.PAD * 2 + Blueprints.GAP)
    / (Blueprints.SLOT + Blueprints.GAP)))
end

-- Which blueprint index is under (mx,my), or nil.  scroll is a page number.
function Blueprints.itemAt(vw, vh, mx, my, scroll)
  local px, py, pw, ph = Blueprints.rect(vw, vh)
  if mx < px or mx >= px + pw or my < py or my >= py + ph then return nil end
  local per = Blueprints.perPage(vw, vh)
  local startX = px + Blueprints.PAD
  for i = 1, per do
    local x = startX + (i - 1) * (Blueprints.SLOT + Blueprints.GAP)
    if mx >= x and mx < x + Blueprints.SLOT and my >= py + Blueprints.HEAD
       and my < py + Blueprints.HEAD + Blueprints.SLOT then
      return ((scroll or 1) - 1) * per + i
    end
  end
  return nil
end

-- Draws the blueprint book.  `bp` is the array of blueprints, `scroll` the
-- page, `font` the UI font, and `selectedItem` the active hotbar item (for the
-- selection badge).  Styling matches the tileset picker (same backdrop, cell
-- fills, and hover/selection rings).
function Blueprints.draw(session, vw, vh, bp, scroll, font, selectedItem)
  local ix, iy, iw, ih = Blueprints.rect(vw, vh)
  love.graphics.setColor(0, 0, 0, 0.92)
  love.graphics.rectangle("fill", ix, iy, iw, ih)
  love.graphics.setColor(0.55, 0.55, 0.6, 0.5)
  love.graphics.rectangle("line", ix, iy, iw, ih)
  local head = fitText(font,
    "BLUEPRINTS (B)  " .. tostring(#bp) .. " saved  pg " .. tostring(scroll),
    iw - Blueprints.PAD * 2, 2)
  Text.label(font, head, ix + Blueprints.PAD, iy + 6, 2, {
    bg = { 0.92, 0.92, 0.95, 0.95 }, padX = 3, padY = 2,
  })
  love.graphics.setColor(1, 1, 1, 1)
  local mx, my = love.mouse.getPosition()
  local hoverIdx = Blueprints.itemAt(vw, vh, mx, my, scroll)
  local per = Blueprints.perPage(vw, vh)
  local pageStart = (scroll - 1) * per
  local x = ix + Blueprints.PAD
  local sy = iy + Blueprints.HEAD
  for i = 1, per do
    local entry = bp[pageStart + i]
    if not entry then break end
    love.graphics.setColor(0.22, 0.22, 0.26, 0.92)
    love.graphics.rectangle("fill", x, sy, Blueprints.SLOT, Blueprints.SLOT)
    Item.draw(session, { kind = "blueprint", id = entry.id }, x + 2, sy + 2,
      Blueprints.SLOT - 4, bp)
    local isSelected = selectedItem and selectedItem.kind == "blueprint"
      and selectedItem.id == entry.id
    if hoverIdx == pageStart + i then
      love.graphics.setColor(1, 1, 1, 0.95)
      love.graphics.rectangle("line", x - 1, sy - 1, Blueprints.SLOT + 2, Blueprints.SLOT + 2)
    elseif isSelected then
      love.graphics.setColor(1, 0.3, 0.3, 0.8)
      love.graphics.rectangle("line", x - 1, sy - 1, Blueprints.SLOT + 2, Blueprints.SLOT + 2)
    end
    x = x + Blueprints.SLOT + Blueprints.GAP
  end
  love.graphics.setColor(1, 1, 1, 1)
end

return Blueprints