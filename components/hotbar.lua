-- Hotbar component: the 8-slot square strip along the bottom of the screen.
-- Owns its geometry (slot rects, hit-testing) and its draw routine, so the
-- overlay orchestrator only calls hotbar.draw and input queries hotbar.at.

local Common = require("mods.mapamap.common")
local Item = require("mods.mapamap.components.item")
local Text = require("mods.mapamap.components.text")

local Hotbar = {}

Hotbar.SLOTS = 10
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

-- ---------------------------------------------------------------------------
-- Selection model

-- Locks a block item to the tileset its numeric id belongs to.  Without a
-- source tag a block id is only meaningful inside one tileset, so crossing a
-- map border would silently reinterpret it; tagging keeps the SAME visual tile
-- and lets apply/paintAt graft it when the target map uses another tileset.
-- Mutates in place (drag/drop keeps reference identity) and returns the item.
function Hotbar.tag(session, item)
  if item and item.kind == "block" and not item.srcTileset and not item.tileset
     and session and session.tileset then
    item.tileset = session.tileset.id
  end
  return item
end

-- The currently selected hotbar item.
function Hotbar.selected(ui)
  return ui.hotbar[ui.selected]
end

-- Sets the session's paint target from the selected hotbar slot.  Returns
-- true when a valid item is selected.
function Hotbar.apply(ui, session)
  local item = Hotbar.selected(ui)
  if not item then return false end
  Hotbar.tag(session, item)
  if item.kind == "sprite" then
    session.selectedSprite = item.id
  elseif item.kind == "item" or item.kind == "blueprint"
         or item.kind == "brush" or item.kind == "entity" then
    -- Entity tools place entities and never map to a block/sprite brush.
    session.selectedSprite = nil
    session.selectedBlock = nil
  else
    local blockId = item.id
    local srcTileset = item.srcTileset or item.tileset
    if srcTileset and srcTileset ~= session.tileset.id then
      local gid = session:importBlock(srcTileset, blockId)
      if gid == nil then return false end
      blockId = gid
      session._needsGraftRebuild = true
    end
    session.selectedBlock = blockId
    session.selectedSprite = nil
  end
  return true
end

-- Loads an inventory cell into the selected hotbar slot.  A live entity
-- cell arms the copy tool for that entry (plus the fresh-NPC / new-warp / new-sign
-- templates); everything else loads as-is.
function Hotbar.loadItem(ui, session, item)
  if not item then return end
  if item.kind == "entity" then
    local et = item.entityType
    if et == "warp" then
      if item.newWarp then
        ui.hotbar[ui.selected] = { kind = "entity", entityType = "warp", newWarp = true }
      else
        ui.hotbar[ui.selected] =
          { kind = "entity", entityType = "warp", destMap = item.destMap, destWarp = item.destWarp,
            warp = item.warp }
        session.selectedItem = item.warp
      end
    elseif et == "object" then
      if item.newObject then
        ui.hotbar[ui.selected] = { kind = "entity", entityType = "object", newObject = true }
      else
        ui.hotbar[ui.selected] = { kind = "entity", entityType = "object", obj = item.obj }
        session.selectedItem = item.obj
      end
    elseif et == "sign" then
      ui.hotbar[ui.selected] = { kind = "entity", entityType = "sign", sign = item.sign }
      session.selectedItem = item.sign
    end
  else
    ui.hotbar[ui.selected] = item
  end
  Hotbar.apply(ui, session)
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
      -- Slot number: big, black on a light chip so it reads over any tile.
      if font then
        Text.label(font, tostring(i), x + 2, y + 2, 2, {
          bg = { 0.95, 0.95, 0.95, 0.88 }, padX = 2, padY = 0,
        })
      end
    end
  end
  love.graphics.setColor(1, 1, 1, 1)
end

return Hotbar