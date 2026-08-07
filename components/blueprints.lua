-- Blueprint book component: the centered strip above the hotbar listing
-- captured block grids, plus the rectangle-select capture overlay.
--
-- Owns its layout and the book panel draw; the capture-selection overlay that
-- draws over the world sits in the overlay orchestrator since it needs the
-- live camera transform (Coords).

local Item = require("mods.mapamap.components.item")

local Blueprints = {}

Blueprints.SLOT = 48
Blueprints.GAP = 6
Blueprints.PAD = 10
Blueprints.HEAD = 40   -- matches the picker's header row height

-- Panel rect: centered above the hotbar.  Width fits `perPage` current
-- entries, sized to the viewport so it never overruns the hotbar.
function Blueprints.rect(vw, vh)
  local available = vw * 0.66
  local per = Blueprints.perPage(vw, vh)
  local w = Blueprints.PAD * 2 + per * Blueprints.SLOT
            + (per - 1) * Blueprints.GAP
  w = math.max(w, math.min(available, Blueprints.SLOT * 5
                                        + Blueprints.GAP * 4 + Blueprints.PAD * 2))
  local x = math.floor((vw - w) / 2)
  local y = vh - Blueprints.SLOT - 10 - Blueprints.HEAD - 8
  return x, y, w, Blueprints.HEAD + Blueprints.SLOT + 8
end

-- Entries per page (a single row), based on the slot spacing.
function Blueprints.perPage(vw, vh)
  return math.max(1, math.floor((vw * 0.66) / (Blueprints.SLOT + Blueprints.GAP)))
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
  love.graphics.setColor(0.9, 0.9, 1, 0.9)
  font.draw("Blueprints (B to close)  " .. tostring(#bp) .. " saved", ix + 6, iy + 8)
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