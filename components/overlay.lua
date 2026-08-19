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

local Coords = require("mods.mapamap.engine.coords")
local Input = require("mods.mapamap.controllers.input")
local EditorTools = require("mods.mapamap.controllers.editor_tools")
local Neighbors = require("mods.mapamap.domain.neighbors")
local Borders = require("mods.mapamap.components.mapborders")
local Item = require("mods.mapamap.components.item")
local Hotbar = require("mods.mapamap.components.hotbar")
local Picker = require("mods.mapamap.components.picker")
local Inventory = require("mods.mapamap.components.inventory")
local Text = require("mods.mapamap.components.text")

local Overlay = {}

-- Whether the overworld map is currently the front-most layer the player is
-- looking at.  Dialogs (TextBox), battles and the various menus all stack
-- ABOVE the overworld on the game's state stack; while one of them owns the
-- top, the world markers (warps/borders/cursor) must not draw over its UI.
-- Gen 1 pushes the OverworldState itself, so the map is front only when the
-- top IS that state.  Gen 2 keeps the World off the stack (it draws directly),
-- so ANY state on top obscures it -- and its battles are flagged straight on
-- the World (battleActive) even before the battle screen appears.
local function worldObscured(game)
  if not game then return false end
  -- Gen 2: the World carries the battle flag directly.
  local world = game.world
  if world and world.battleActive then return true end
  local stack = game.stack
  local states = stack and stack.states
  local top = states and states[#states]
  if not top then
    -- No covering state (Gen 2 free walk, or the headless draw harness): the
    -- map is the front layer.
    return false
  end
  if game.overworld and top == game.overworld then return false end
  if game.world and top == game.world then return false end
  return true
end

-- --- world cursor highlight ------------------------------------------------

local function drawCursor(session, game)
  local t = Coords.transform(game)
  if not t then return end
  local item = Input.selectedItem()
  if item and item.kind == "blueprint" then
    -- The blueprint preview (with its footprint outline) replaces the plain
    -- cursor highlight while a stamp is selected.
    return
  end
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
  if not session.map then return end
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

-- --- blueprint placement preview -------------------------------------------

-- Draws one blueprint cell as its tile block (4x4 atlas tiles) at the screen
-- block rect, faded.  Falls back to a translucent neutral square when the tile
-- cannot be resolved.  Returns true when something was drawn.
local function drawPreviewBlock(session, bid, srcTs, x, y, sx, sy)
  local r = session.map and session.map.renderer
  local image, quads, aliasMap, block
  local bundle
  if srcTs and session.tileset and srcTs ~= session.tileset.id then
    local tsDef = session.data and session.data.tilesets and session.data.tilesets[srcTs]
    if tsDef and session.thumbnailBundle then bundle = session:thumbnailBundle(tsDef) end
  end
  if not bundle and session.tileset and session.thumbnailBundle then
    bundle = session:thumbnailBundle(session.tileset)
  end
  if bundle then
    image, quads, aliasMap = bundle.image, bundle.quads, bundle.aliasMap
    block = bundle.blocks and bundle.blocks[bid + 1]
  elseif r and r.image then
    image, quads, aliasMap = r.image, r.quads, r.aliasMap
    block = session.tileset and session.tileset.blocks and session.tileset.blocks[bid + 1]
  else
    return false
  end
  if not image or not quads or not block then return false end
  love.graphics.push()
  love.graphics.scale(sx, sy)
  love.graphics.setColor(1, 1, 1, 0.55)
  for rr = 0, 3 do
    for cc = 0, 3 do
      local ci = rr * 4 + cc + 1
      local tile = block[ci]
      local remap = aliasMap and aliasMap[bid]
      if remap and remap[ci - 1] then tile = remap[ci - 1] end
      local quad = quads[tile]
      if quad then love.graphics.draw(image, quad, x / sx + cc * 8, y / sy + rr * 8) end
    end
  end
  love.graphics.pop()
  return true
end

-- While a blueprint is selected, draw a translucent ghost of the stamp on the
-- world at the cursor block, exactly where the next LMB would place it (same
-- anchor math as Blueprints.paint), with a green footprint outline.  Cells
-- over open void are skipped -- they paint nothing.
local function drawBlueprintPreview(session, game)
  local item = Input.selectedItem()
  if not item or item.kind ~= "blueprint" then return end
  local t = Coords.transform(game)
  if not t then return end
  local bp = item
  local bx0 = math.floor(session.cursorBx / 2)
  local by0 = math.floor(session.cursorBy / 2)
  for row = 0, bp.h - 1 do
    for col = 0, bp.w - 1 do
      local cell = bp.tiles[row * bp.w + col + 1]
      if cell ~= nil and cell ~= false then
        local bid = type(cell) == "table" and cell.id or cell
        local srcTs = type(cell) == "table" and cell.tileset or nil
        local _, def = Neighbors.mapAt(session.def, session.neighbors,
          (bx0 + col) * 2, (by0 + row) * 2)
        if def then
          local x, y, w, h = Coords.blockRect(t, (bx0 + col) * 2, (by0 + row) * 2)
          if x and not drawPreviewBlock(session, bid, srcTs, x, y, t.sx, t.sy) then
            love.graphics.setColor(1, 1, 1, 0.3)
            love.graphics.rectangle("fill", x, y, w, h)
          end
        end
      end
    end
  end
  -- Green footprint outline over the whole anchored stamp.
  local lx, ly, _, _ = Coords.blockRect(t, bx0 * 2, by0 * 2)
  if lx then
    local w = bp.w * 32 * t.sx
    local h = bp.h * 32 * t.sy
    love.graphics.setColor(0.3, 1, 0.5, 0.85)
    love.graphics.setLineWidth(1)
    love.graphics.rectangle("line", lx, ly, w, h)
  end
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
  -- A dialog/battle/menu on top of the overworld hides the warp circles: the
  -- markers would draw over the game's own UI, not the map.
  if worldObscured(game) then return {} end
  local ow = game and (game.overworld or game.world)
  local out = {}
  local function collect(def, ox, oy)
    for _, w in ipairs(def and def.warps or {}) do
      out[#out + 1] = { warp = w, ox = ox, oy = oy }
    end
  end
  if ow and ow.map and ow.map.def then
    collect(ow.map.def, 0, 0)
    for _, nb in ipairs(ow.neighbors or {}) do
      if nb and nb.map and nb.map.def then
        collect(nb.map.def, nb.ox, nb.oy)
      elseif nb and nb.id and nb.ox ~= nil then
        local def = session.data and session.data.maps and session.data.maps[nb.id]
        collect(def, nb.ox, nb.oy)
      end
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

-- Ghost indicator while dragging a warp or object to a new cell (RMB drag).
-- Draws a translucent circle at the cursor cell so the user sees where the
-- entity will land on release.
local function drawEntityDrag(session, game)
  local drag = EditorTools.draggingEntity
  if not drag then return end
  local t = Coords.transform(game)
  if not t then return end
  local mx, my = love.mouse.getPosition()
  local tx, ty = Coords.toWorldCell(t, mx, my)
  if not tx then return end
  -- Snap the ghost to the target cell center.
  local wx = drag.ox + tx * 16
  local wy = drag.oy + ty * 16
  local sx, sy = Coords.toScreen(t, wx, wy)
  if not sx then return end
  local cx, cy = sx + 8 * t.sx, sy + 8 * t.sy
  local r = 6 * t.sx
  if drag.kind == "warp" then
    love.graphics.setColor(0.2, 0.7, 1, 0.55)
    love.graphics.circle("fill", cx, cy, r)
    love.graphics.setColor(1, 1, 1, 0.6)
    love.graphics.setLineWidth(1)
    love.graphics.circle("line", cx, cy, r)
  else
    -- Object ghost: small filled square (NPC marker style).
    local s = 10 * t.sx
    love.graphics.setColor(0.2, 0.9, 0.3, 0.5)
    love.graphics.rectangle("fill", cx - s / 2, cy - s, s, s)
    love.graphics.setColor(1, 1, 1, 0.6)
    love.graphics.rectangle("line", cx - s / 2, cy - s, s, s)
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

  -- Wrap the draw body so love.graphics.pop() always runs even when a sub-
  -- draw throws; without this, an error skips the pop and the graphics state
  -- stack accumulates one level per errored frame until it overflows.
  local ok, err = pcall(function()
    -- World markers first so the HUD panels always render above them.  They
    -- are skipped while a dialog/battle/menu covers the map -- drawing warp
    -- circles/borders/cursor over the game's own UI would look broken.
    if not worldObscured(game) then
      Borders.draw(session, game)
      drawCursor(session, game)
      drawBlueprintPreview(session, game)
      drawSelection(session, game)
      drawWarps(session, game)
      drawEntityDrag(session, game)
      drawDestPick(session, game)
    end
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
    if Input.encEditor then
      local EncEditor = require("mods.mapamap.components.encounter_editor")
      EncEditor.draw(session, Input.encEditor, vw, vh, session.font)
    end

    -- A picked-up item (picker or hotbar drag) floats under the cursor above
    -- every panel, faded, so the drop target stays visible underneath.
    if Input.dragItem then
      local mx, my = love.mouse.getPosition()
      local size = 40
      love.graphics.setColor(0, 0, 0, 0.25)
      love.graphics.rectangle("fill", mx - size / 2 + 3, my - size / 2 + 3, size, size)
      Item.draw(session, Input.dragItem, mx - size / 2, my - size / 2, size, nil, 0.8)
    end
  end)

  love.graphics.pop()
  if not ok then error(err) end
end

return Overlay