-- mapamap overlay orchestrator: draws the editing HUD over the live frame via
-- the render.hud hook.
--
-- Draws, in LOVE screen units:
--   * a highlighted outline over the world block under the mouse
--   * the blueprint capture rectangle over the world
--   * warp circles for every warp on every visible laid-out map
--   * the destination-pick crosshair
--   * the bottom hotbar (components/hotbar)
--   * the left inventory panel (components/inventory)
--   * the tileset picker panel (components/picker)
--   * the Details modal (components/details)
--
-- World markers (cursor/selection/warps/dest-pick) draw first so the HUD
-- panels always render above them; panels draw in open/close order so the
-- Details modal (and picker) sit on top.
--
-- Thumbnails reuse the map renderer's tile atlas (blocks) and a lazily-built
-- SpriteRenderer (sprites) via components/item.lua.

local Coords = require("mods.mapamap.func.coords")
local Input = require("mods.mapamap.input")
local Item = require("mods.mapamap.components.item")
local Hotbar = require("mods.mapamap.components.hotbar")
local Picker = require("mods.mapamap.components.picker")
local Inventory = require("mods.mapamap.components.inventory")
local Text = require("mods.mapamap.components.text")

local Overlay = {}

-- --- world cursor highlight ------------------------------------------------

local function drawCursor(session, game)
  local t = Coords.transform(game)
  if not t then return end
  local item = Input.selectedItem()
  local x, y, w, h
  if item and (item.kind == "sprite" or item.kind == "item"
       or item.kind == "warp" or item.kind == "object") then
    -- Sprites/warps/objects place on a single 1x1 cell (map-object coords are
    -- walk-grid cells); blocks are 2x2 cells.
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
  -- The border is always drawn so the target cell is visible whether the
  -- brush is idle or mid-drag; the dark fill tint only marks an active
  -- press/drag and makes the target read over any palette.
  local pressed = Input.mouseDown(1) or Input.mouseDown(2)
  if pressed then
    love.graphics.setColor(0, 0, 0, 0.18)
    love.graphics.rectangle("fill", x, y, w, h)
  end
  love.graphics.setColor(1, 1, 1, 0.95)
  love.graphics.setLineWidth(1)
  love.graphics.rectangle("line", x, y, w, h)
  -- green accent for sprites so placement vs block-paint is obvious
  if item and (item.kind == "sprite" or item.kind == "item"
       or item.kind == "warp" or item.kind == "object") then
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

-- --- warp circles + destination-pick crosshair ------------------------------

-- Every warp to draw, in the frame the world is CURRENTLY rendered in.  The
-- overworld re-anchors the world to the map it is drawing (ow.map at offset
-- 0,0, neighbors at their strip offsets), so the overlay must use that same
-- frame or the circles float while walking across a border -- they stop being
-- glued to their tiles until the session reconciles on the next input event.
-- Falls back to the session's own layout when no live overworld is available.
function Overlay.visibleWarps(session, game)
  local ow = game and game.overworld
  local out = {}
  local function collect(def, ox, oy)
    for _, w in ipairs(def and def.warps or {}) do
      out[#out + 1] = { warp = w, ox = ox, oy = oy }
    end
  end
  if ow and ow.map and ow.map.def then
    collect(ow.map.def, 0, 0)
    for _, nb in ipairs(ow.neighbors or {}) do
      if nb and nb.map and nb.map.def then collect(nb.map.def, nb.ox, nb.oy) end
    end
  else
    for _, e in ipairs(session:visibleWarps()) do out[#out + 1] = e end
  end
  return out
end

-- Draws every warp on every map laid out around the one being rendered as a
-- blue circle (walk-grid cell centers, projected at each map's world offset),
-- with the selected warp ringed yellow.  Mirrors the map_editor entity marker
-- style (filled disc + line ring).  Only the edited map's warps can be the
-- selection; the ring follows a warp across a border because the offsets come
-- from the runtime frame, not the session's stale anchor.
local function drawWarps(session, game)
  local t = Coords.transform(game)
  if not t then return end
  local r = 6 * t.sx
  for _, e in ipairs(Overlay.visibleWarps(session, game)) do
    local w = e.warp
    local x, y = Coords.toScreen(t, e.ox + w.x * 16, e.oy + w.y * 16)
    if x then
      local cx, cy = x + 8 * t.sx, y + 8 * t.sy
      local selected = w == session.selectedWarp
      love.graphics.setColor(0.2, 0.45, 1, 0.85)
      love.graphics.circle("fill", cx, cy, r)
      love.graphics.setColor(1, 1, 1, 0.95)
      love.graphics.setLineWidth(1)
      love.graphics.circle("line", cx, cy, r)
      if selected then
        love.graphics.setColor(1, 0.9, 0.3, 0.95)
        love.graphics.setLineWidth(2)
        love.graphics.circle("line", cx, cy, r + 3 * t.sx)
      end
      if w.label and w.label ~= "" then
        love.graphics.setColor(1, 1, 1, 0.9)
        Text.label(session.font, w.label, cx + r + 2, cy - r - 8, 1, {
          bg = { 0.1, 0.1, 0.15, 0.75 }, padX = 2, padY = 1,
        })
      end
    end
  end
  love.graphics.setColor(1, 1, 1, 1)
end

-- Crosshair + hint while graphical destination-pick is armed (C).
local function drawDestPick(session, game)
  if not Input.warpDestPick then return end
  local t = Coords.transform(game)
  if t then
    local x, y, w, h = Coords.cellRect(t, session.cursorBx, session.cursorBy)
    if x then
      love.graphics.setColor(1, 0.9, 0.3, 0.5)
      love.graphics.rectangle("fill", x, y, w, h)
      love.graphics.setColor(1, 0.9, 0.3, 0.95)
      love.graphics.setLineWidth(1)
      love.graphics.rectangle("line", x, y, w, h)
      love.graphics.setColor(1, 1, 1, 1)
    end
  end
  local vw, vh = love.graphics.getDimensions()
  local label = "PICK DESTINATION FOR WARP"
  local fw = ((session.font.width and session.font.width(label)) or (#label * 8)) * 1
  Text.label(session.font, label, vw / 2 - fw / 2, 12, 1,
    { bg = { 0.9, 0.7, 0.2, 0.9 }, padX = 3, padY = 2 })
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

  -- World markers first so the HUD panels always render above them.
  drawCursor(session, game)
  drawSelection(session, game)
  drawWarps(session, game)
  drawDestPick(session, game)
  -- HUD panels on top, in open/close order so the picker and Details modal
  -- cover the inventory/hotbar rather than being hidden behind them.
  if Input.showInventory then
    Inventory.draw(session, Input.inventory, vw, vh, session.font, Input.selectedItem())
  end
  Hotbar.draw(session, vw, vh, Input.hotbar, Input.selected, session.font)
  if Input.showPicker then
    Picker.draw(session, vw, vh, {
      selection = Input.pickerTileset,
      scroll = Input.pickerScroll,
      listScroll = Input.pickerTilesetScroll,
      dropOpen = Input.pickerDropOpen,
    }, session.font)
  end
  if Input.details then
    local Details = require("mods.mapamap.components.details")
    Details.draw(session, Input.details, vw, vh, session.font)
  end

  love.graphics.pop()
end

return Overlay