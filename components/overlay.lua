-- mapamap overlay orchestrator: draws the editing HUD over the live frame via
-- the render.hud hook.
--
-- Draws, in LOVE screen units:
--   * a highlighted outline over the world block under the mouse
--   * the blueprint capture rectangle over the world
--   * the bottom hotbar (components/hotbar)
--   * the tileset picker panel (components/picker)
--   * the blueprint book panel (components/blueprints)
--
-- Thumbnails reuse the map renderer's tile atlas (blocks) and a lazily-built
-- SpriteRenderer (sprites) via components/item.lua.

local Coords = require("mods.mapamap.func.coords")
local Input = require("mods.mapamap.input")
local Item = require("mods.mapamap.components.item")
local Hotbar = require("mods.mapamap.components.hotbar")
local Picker = require("mods.mapamap.components.picker")
local Blueprints = require("mods.mapamap.components.blueprints")

local Overlay = {}

-- --- world cursor highlight ------------------------------------------------

local function drawCursor(session, game)
  local t = Coords.transform(game)
  if not t then return end
  local item = Input.selectedItem()
  local x, y, w, h
  if item and (item.kind == "sprite" or item.kind == "item") then
    -- Sprites place on a single 1x1 cell (object coords are walk-grid cells).
    x, y, w, h = Coords.cellRect(t, session.cursorBx, session.cursorBy)
  else
    -- Blocks are 2x2 cells; snap the highlight to whole blocks.
    local cx = session.cursorBx - (session.cursorBx % 2)
    local cy = session.cursorBy - (session.cursorBy % 2)
    x, y, w, h = Coords.blockRect(t, cx, cy)
  end
  if not x then return end
  local ok, r = pcall(function() return session.map and session.map.renderer end)
  if not ok or not r then return end
  -- white outline with a dark fill tint so the target cell reads over any
  -- palette; the fill is cheap so it stays readable at any zoom
  love.graphics.setColor(0, 0, 0, 0.18)
  love.graphics.rectangle("fill", x, y, w, h)
  love.graphics.setColor(1, 1, 1, 0.95)
  love.graphics.setLineWidth(1)
  love.graphics.rectangle("line", x, y, w, h)
  -- green accent for sprites so placement vs block-paint is obvious
  if item and (item.kind == "sprite" or item.kind == "item") then
    love.graphics.setColor(0.3, 1, 0.4, 0.9)
  else
    love.graphics.setColor(1, 0.9, 0.3, 0.9)
  end
  love.graphics.rectangle("line", x + 1, y + 1, w - 2, h - 2)
  love.graphics.setColor(1, 1, 1, 1)
end

-- --- blueprint capture selection (needs the live camera) -------------------

local function drawSelection(session, game)
  if not Input.blueprintMode then return end
  local t = Coords.transform(game)
  if not t then return end
  local a = Input.selectStart
  if not a then
    -- Pulldown hint while armed but not dragging yet.
    local mx, my = love.mouse.getPosition()
    local x, y, w, h = Coords.blockRect(t,
      session.cursorBx - (session.cursorBx % 2),
      session.cursorBy - (session.cursorBy % 2))
    if x then
      love.graphics.setColor(0.4, 1, 0.6, 0.25)
      love.graphics.rectangle("fill", x, y, w, h)
      love.graphics.setColor(0.4, 1, 0.6, 0.8)
      love.graphics.setLineWidth(1)
      love.graphics.rectangle("line", x, y, w, h)
      love.graphics.setColor(1, 1, 1, 1)
    end
    return
  end
  local b = Input.selectEnd or a
  local b0x, b1x = math.min(a.bx, b.bx), math.max(a.bx, b.bx)
  local b0y, b1y = math.min(a.by, b.by), math.max(a.by, b.by)
  -- a/selectStart carry BLOCK indices (from Input.blockCellAt: floor(cell/2)).
  -- blockRect expects the block's top-left CELL, so scale by 2 or the box
  -- lands on the neighbouring block instead of under the cursor.
  local lx, ly, _, _ = Coords.blockRect(t, b0x * 2, b0y * 2)
  local rx, ry, _, _ = Coords.blockRect(t, b1x * 2, b1y * 2)
  if not lx then return end
  local w = (rx + 32 * t.sx) - lx
  local h = (ry + 32 * t.sy) - ly
  love.graphics.setColor(0.3, 1, 0.5, 0.2)
  love.graphics.rectangle("fill", lx, ly, w, h)
  love.graphics.setColor(0.3, 1, 0.5, 0.8)
  love.graphics.setLineWidth(1)
  love.graphics.rectangle("line", lx, ly, w, h)
  love.graphics.setColor(1, 1, 1, 1)
end

-- --- main entry ------------------------------------------------------------

-- Draws the whole overlay.  Called from the render.hud hook only while the
-- mod is active.  game/`viewport` come from the hook signature.
function Overlay.draw(session, game, viewport)
  if not session then return end
  local vw, vh = love.graphics.getDimensions()
  love.graphics.push("all")
  love.graphics.origin()
  love.graphics.setColor(1, 1, 1, 1)

  drawCursor(session, game)
  Hotbar.draw(session, vw, vh, Input.hotbar, Input.selected, session.font)
  drawSelection(session, game)
  if Input.showBlueprints then
    Blueprints.draw(session, vw, vh, Input.blueprints, Input.blueprintScroll,
      session.font, Input.selectedItem())
  end
  if Input.showPicker then
    Picker.draw(session, vw, vh, {
      selection = Input.pickerTileset,
      scroll = Input.pickerScroll,
      listScroll = Input.pickerTilesetScroll,
    }, session.font)
  end

  love.graphics.pop()
end

return Overlay