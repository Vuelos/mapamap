-- Mouse/keyboard input for mapamap's direct-paint overlay.
--
-- While the overlay is active:
--   * LMB drag  -> paint the selected block (or place the selected sprite)
--   * RMB drag  -> erase back to the snapshot (blocks) / remove object (sprites)
--   * Q         -> pick the block under the cursor into the selected slot
--   * E         -> toggle the tileset picker panel
--   * wheel     -> scroll the open picker (or cycle hotbar when closed)
--   * digit keys -> select a hotbar slot directly
--   * dragging  -> from the picker onto a hotbar slot assigns that item
--
-- All input is guarded by the active flag so the vanilla game is untouched
-- while the overlay is closed.  Coordinates arrive in LOVE screen units.

local Common = require("mods.mapamap.func.common")
local Coords = require("mods.mapamap.func.coords")
local Neighbors = require("mods.mapamap.func.neighbors")
local NewMap = require("mods.mapamap.func.new_map")
local Hotbar = require("mods.mapamap.components.hotbar")
local Picker = require("mods.mapamap.components.picker")
local Blueprints = require("mods.mapamap.components.blueprints")

local Input = {}

-- Hotbar: fixed-size array of item slots.  Each slot is
--   { kind = "block", id = <number> }  or  { kind = "sprite", id = <string> }
-- Empty slots are nil.
Input.hotbar = {}
Input.selected = 1
-- The tileset picker panel.
Input.showPicker = false
Input.pickerScroll = 1
Input.pickerScrollBase = 0
Input.pickerTilesetScroll = 1  -- page into the left tileset-name list
-- Which tileset the picker is browsing (nil = the session's map tileset).
Input.pickerTileset = nil
-- Dragging a picker item onto a hotbar slot.
Input.dragItem = nil

-- Blueprint support: a book of saved block grids, plus a rectangle-select
-- capture mode.  Each entry is { id, w, h, tiles } where tiles is row-major
-- block ids.  Captures are taken straight from the map under a drag rectangle.
Input.blueprints = {}
Input.blueprintMode = false  -- rectangle-select capture is armed
Input.selectStart = nil      -- {bx, by} block coords where the selection began
Input.selectEnd = nil        -- {bx, by} current selection anchor (single cell)
Input.showBlueprints = false -- the blueprint book panel is open
Input.blueprintScroll = 1

local state = {
  painting = false,
  erasing = false,
  paintingMap = nil,   -- mapId painted on this drag (blocks only)
  lastBlockX = nil,    -- last painted block coord (re-paint dedupe)
  lastBlockY = nil,
  lastCellX = nil,
  lastCellY = nil,
}

-- Re-seeds the hotbar from a saved mod-save layout (or the default pick).
function Input.configure(initial)
  Input.hotbar = {}
  for i = 1, Hotbar.SLOTS do
    Input.hotbar[i] = initial and initial[i] or nil
  end
  Input.selected = 1
end

-- Serialized hotbar for persistence.
function Input.serialize()
  return Input.hotbar
end

function Input.reset()
  state.painting = false
  state.erasing = false
  state.paintingMap = nil
  state.lastBlockX = nil
  state.lastBlockY = nil
  state.lastCellX = nil
  state.lastCellY = nil
  Input.dragItem = nil
  Input.pickerTilesetScroll = 1
  Input.blueprintMode = false
  Input.selectStart = nil
  Input.selectEnd = nil
  Input.showBlueprints = false
  Input.blueprintScroll = 1
end

-- Re-points the picker and hotbar when the session switches to a new map
-- (walking across a border or adopting a created map).  The picker re-defaults
-- to the incoming map's tileset and block brushes are re-seeded onto that
-- tileset's palette so the same slot index never paints a stale tile id.
function Input.onMapEntry(session)
  -- Re-default the picker to the current map's tileset (featured first).
  Input.pickerTileset = nil
  Input.pickerScroll = 1
  Input.pickerTilesetScroll = 1
  -- Re-seed block slots onto the incoming tileset's palette.
  local palette = session.paletteList or {}
  for i = 1, Hotbar.SLOTS do
    local item = Input.hotbar[i]
    if item and item.kind == "block" and #palette > 0 then
      Input.hotbar[i] = { kind = "block", id = palette[(i - 1) % #palette + 1] }
    end
  end
  if Input.selectedItem() then Input.applySelection(session) end
end

-- The currently selected hotbar item.
function Input.selectedItem()
  return Input.hotbar[Input.selected]
end

-- Sets the session's paint target from the selected hotbar slot.  Returns
-- true when a valid item is selected.
function Input.applySelection(session)
  local item = Input.selectedItem()
  if not item then return false end
  if item.kind == "sprite" then
    session.selectedSprite = item.id
  elseif item.kind == "item" or item.kind == "blueprint" then
    session.selectedSprite = nil
    session.selectedBlock = nil
  else
    session.selectedBlock = item.id
    session.selectedSprite = nil
  end
  return true
end
-- Ordered catalog list for the picker's left column: the virtual "Items &
-- NPCs" entry first, then the real tilesets (current map's first).
function Input.tilesetNames(session)
  return Picker.catalog(session)
end

-- Full picker list for the currently-browsed catalog entry as { kind, id }
-- items.  `selection` lets callers browse a specific tileset / the virtual
-- catalog; nil uses the current map's tileset.
function Input.tilesetList(session, selection)
  return Picker.itemList(session, selection)
end

-- --- blueprint capture & paint ----------------------------------------------

-- Block coords (bx, by) on the session's primary map def under a screen point,
-- or nil when outside that map's body.
function Input.blockCellAt(session, mx, my)
  local t = Coords.transform(session.game)
  if not t then return nil end
  local tx, ty = Coords.toWorldCell(t, mx, my)
  local def = session.def
  local bx = math.floor((tx * 16) / Common.BLOCK_PX)
  local by = math.floor((ty * 16) / Common.BLOCK_PX)
  if bx < 0 or by < 0 or bx >= def.width or by >= def.height then return nil end
  return bx, by
end

-- Captures the block grid inside the current selection rectangle into the
-- blueprint book.  Returns the new blueprint id, or nil.
function Input.captureBlueprint(session)
  local a, b = Input.selectStart, Input.selectEnd
  if not a or not b then return nil end
  local x0, x1 = math.min(a.bx, b.bx), math.max(a.bx, b.bx)
  local y0, y1 = math.min(a.by, b.by), math.max(a.by, b.by)
  local w = x1 - x0 + 1
  local h = y1 - y0 + 1
  if w <= 0 or h <= 0 or w * h > 4096 then return nil end
  local def = session.def
  local tiles = {}
  for by = y0, y1 do
    for bx = x0, x1 do
      tiles[#tiles + 1] = def.blocks[by * def.width + bx + 1]
    end
  end
  local id = "blueprint_" .. os.time()
  table.insert(Input.blueprints, { id = id, w = w, h = h, tiles = tiles })
  Input.selectStart, Input.selectEnd = nil, nil
  return id
end

-- Paints a blueprint at the given screen point's cursor block on the primary
-- map.  Returns true when stamps were written.
function Input.paintBlueprint(session, bid, mx, my)
  local bp = nil
  for _, e in ipairs(Input.blueprints) do if e.id == bid then bp = e; break end end
  if not bp then return false end
  local t = Coords.transform(session.game)
  if not t then return false end
  local tx, ty = Coords.toWorldCell(t, mx, my)
  session.cursorBx = tx - (tx % 2)
  session.cursorBy = ty - (ty % 2)
  local def = session.def
  local bx0 = math.floor((session.cursorBx * 16) / Common.BLOCK_PX)
  local by0 = math.floor((session.cursorBy * 16) / Common.BLOCK_PX)
  local changed = false
  for row = 0, bp.h - 1 do
    for col = 0, bp.w - 1 do
      local bx = bx0 + col
      local by = by0 + row
      if bx >= 0 and by >= 0 and bx < def.width and by < def.height then
        def.blocks[by * def.width + bx + 1] = bp.tiles[row * bp.w + col + 1]
        changed = true
      end
    end
  end
  if changed then
    session.mapChanged = true
    session:refreshLiveRenderers()
  end
  return changed
end

-- The block / sprite id stored at a given screen point, for the cursor pick.
-- Returns nil when not over the world.
function Input.pickUnder(session, game, mx, my, vw, vh)
  local t = Coords.transform(game)
  if not t then return nil end
  local tx, ty = Coords.toWorldCell(t, mx, my)
  local mapId, def, ox, oy = require("mods.mapamap.func.neighbors")
    .mapAt(session.def, session.neighbors, tx, ty)
  if not def then return nil end
  local bx = math.floor((tx * 16 - (ox or 0)) / Common.BLOCK_PX)
  local by = math.floor((ty * 16 - (oy or 0)) / Common.BLOCK_PX)
  if bx < 0 or by < 0 or bx >= def.width or by >= def.height then return nil end
  return def.blocks[by * def.width + bx + 1]
end

-- Paints one block (or sprite) at the cursor if it has moved to a new cell.
-- Returns true when something changed.
function Input.paintAt(session, mx, my)
  local item = Input.selectedItem()
  if not item then return false end
  local t = Coords.transform(session.game)
  if not t then return false end
  local tx, ty = Coords.toWorldCell(t, mx, my)
  if tx == state.lastCellX and ty == state.lastCellY then return false end
  state.lastCellX, state.lastCellY = tx, ty

  -- Sprites place NPC objects, one per block cell.
  if item.kind == "sprite" then
    session.cursorBx = tx
    session.cursorBy = ty
    return session:placeSprite(item.id)
  end

  -- Items place map-item objects, one per block cell.
  if item.kind == "item" then
    session.cursorBx = tx
    session.cursorBy = ty
    return session:placeItem(item.id)
  end

  -- Blueprints stamp a block grid at the cursor block.
  if item.kind == "blueprint" then
    return Input.paintBlueprint(session, item.id, mx, my)
  end

  -- Blocks paint with the shared map_ops brush.  Cursor is snapped to whole
  -- blocks (2-cell) in MAP mode semantics.
  session.cursorBx = tx - (tx % 2)
  session.cursorBy = ty - (ty % 2)
  session.selectedBlock = item.id
  -- When the cursor is outside every laid-out map body (strictly beyond the
  -- map edge into open space), route through the edge expand-vs-create rule;
  -- otherwise paint normally (paintBlock handles in-body and neighbor cells).
  local side = session:cellEdgeSide(session.cursorBx, session.cursorBy)
  if side and not session:cellInsideNeighbor(session.cursorBx, session.cursorBy) then
    session:handleEdgePaint(session.cursorBx, session.cursorBy)
  else
    session:snapCursorToBlock()
    session:paintBlock()
  end
  session:refreshLiveRenderers()
  return session.mapChanged
end

-- Erases one cell back to the snapshot (blocks) or removes an object (sprite
-- slot).  Returns true when something changed.
function Input.eraseAt(session, mx, my)
  local t = Coords.transform(session.game)
  if not t then return false end
  local tx, ty = Coords.toWorldCell(t, mx, my)
  if tx == state.lastCellX and ty == state.lastCellY then return false end
  state.lastCellX, state.lastCellY = tx, ty
  local item = Input.selectedItem()
  if item and item.kind == "sprite" then
    session.cursorBx = tx
    session.cursorBy = ty
    return session:eraseObjectsAtCell()
  end
  session.cursorBx = tx - (tx % 2)
  session.cursorBy = ty - (ty % 2)
  session:snapCursorToBlock()
  session:revertBlock()
  session:refreshLiveRenderers()
  return session.mapChanged
end

-- Handles love.mousepressed while active.  Returns true when consumed.
function Input.mousepressed(session, game, mx, my, button)
  if not session then return false end
  local vw, vh = love.graphics.getDimensions()
  -- Blueprint capture is armed: LMB starts (or updates) a drag rectangle.
  if Input.blueprintMode and button == 1 then
    local bx, by = Input.blockCellAt(session, mx, my)
    if bx then
      Input.selectStart = { bx = bx, by = by }
      Input.selectEnd = { bx = bx, by = by }
      return true
    end
    return true
  end
  -- Blueprint book panel: click an entry to load it into the selected slot.
  if Input.showBlueprints and button == 1 then
    local idx = Blueprints.itemAt(vw, vh, mx, my, Input.blueprintScroll)
    if idx and Input.blueprints[idx] then
      local bpD = { kind = "blueprint", id = Input.blueprints[idx].id }
      Input.dragItem = bpD
      -- A plain click replaces the current selected hotbar slot; if the press
      -- was also on a hotbar slot, that slot wins instead.
      if Hotbar.at(vw, vh, mx, my) then
        local slot = Hotbar.at(vw, vh, mx, my)
        Input.hotbar[slot] = bpD
        Input.selected = slot
      else
        Input.hotbar[Input.selected] = bpD
      end
      Input.applySelection(session)
      return true
    end
  end
  -- Picker drags: start dragging a picker item (LMB over the panel).
  if Input.showPicker and button == 1 then
    -- Left tileset-name list first: click a name to browse that catalog entry.
    local tsIdx = Picker.nameAt(vw, vh, mx, my, Input.pickerTilesetScroll)
    if tsIdx then
      local names = Input.tilesetNames(session)
      if names[tsIdx] then
        Input.pickerTileset = names[tsIdx]
        Input.pickerScroll = 1
      end
      return true
    end
    local idx = Picker.itemAt(vw, vh, mx, my, Input.pickerScroll)
    if idx then
      local list = Input.tilesetList(session, Input.pickerTileset)
      Input.dragItem = list[idx]
      if not Input.dragItem then return true end
      -- A plain click here replaces the current selected hotbar slot; if the
      -- press was also on a hotbar slot, that slot wins instead.
      if Hotbar.at(vw, vh, mx, my) then
        local slot = Hotbar.at(vw, vh, mx, my)
        Input.hotbar[slot] = Input.dragItem
        Input.selected = slot
      else
        Input.hotbar[Input.selected] = Input.dragItem
      end
      Input.applySelection(session)
      return true
    end
  end
  -- Hotbar selection.
  local slot = Hotbar.at(vw, vh, mx, my)
  if slot then
    Input.selected = slot
    Input.applySelection(session)
    return true
  end
  -- World paint / erase.
  if button == 1 then
    state.painting = true
    state.erasing = false
    state.lastCellX, state.lastCellY = nil, nil
    Input.applySelection(session)
    -- Paint the cell under the cursor immediately (a press without a drag
    -- must still place one block).
    local t = Coords.transform(session.game)
    if t then
      local tx, ty = Coords.toWorldCell(t, mx, my)
      session.cursorBx, session.cursorBy = tx, ty
      Input.paintAt(session, mx, my)
    end
    return true
  elseif button == 2 then
    state.erasing = true
    state.painting = false
    state.lastCellX, state.lastCellY = nil, nil
    local t = Coords.transform(session.game)
    if t then
      local tx, ty = Coords.toWorldCell(t, mx, my)
      session.cursorBx, session.cursorBy = tx, ty
      Input.eraseAt(session, mx, my)
    end
    return true
  end
  return false
end

-- Handles love.mousereleased while active.
function Input.mousereleased(session, mx, my, button)
  if Input.blueprintMode and button == 1 and Input.selectStart then
    -- Finish a drag: capture the selected rectangle into the book.
    local bx, by = Input.blockCellAt(session, mx, my)
    if bx then Input.selectEnd = { bx = bx, by = by } end
    Input.captureBlueprint(session)
    return true
  end
  if button == 1 and Input.dragItem then
    local vw, vh = love.graphics.getDimensions()
    local slot = Hotbar.at(vw, vh, mx, my)
    if slot then
      Input.hotbar[slot] = Input.dragItem
      Input.selected = slot
    end
    Input.dragItem = nil
    return true
  end
  if button == 1 then state.painting = false end
  if button == 2 then state.erasing = false end
  return false
end

-- Handles love.mousemoved while active.  Returns true (consume) so the
-- vanilla mouse path never sees editing cursor/brush moves.
function Input.mousemoved(session, mx, my)
  if not session then return false end
  if Input.blueprintMode and Input.selectStart then
    -- Extend the selection rectangle while dragging.
    local bx, by = Input.blockCellAt(session, mx, my)
    if bx then Input.selectEnd = { bx = bx, by = by } end
  elseif state.painting then
    Input.paintAt(session, mx, my)
  elseif state.erasing then
    Input.eraseAt(session, mx, my)
  end
  -- Track the cursor for the highlight; cheap and always useful.
  local t = Coords.transform(session.game)
  if t then
    local tx, ty = Coords.toWorldCell(t, mx, my)
    session.cursorBx, session.cursorBy = tx, ty
  end
  return true
end

-- Handles love.wheelmoved while active.
function Input.wheelmoved(session, dy)
  if not session then return false end
  if Input.showBlueprints then
    local vw, vh = love.graphics.getDimensions()
    local per = Blueprints.perPage(vw, vh)
    local max = math.max(1, math.ceil(#Input.blueprints / per))
    Input.blueprintScroll = math.max(1, math.min(Input.blueprintScroll + dy, max))
    return true
  end
  if Input.showPicker then
    local vw, vh = love.graphics.getDimensions()
    local mx, my = love.mouse.getPosition()
    -- Scroll the left tileset-name list when the mouse is over it, else the
    -- item grid.
    local inList = Picker.nameAt(vw, vh, mx, my, Input.pickerTilesetScroll) ~= nil
    if inList then
      local names = Input.tilesetNames(session)
      local perTs = Picker.namesPerPage(vw, vh)
      local maxTs = math.max(1, math.ceil(#names / perTs))
      Input.pickerTilesetScroll = math.max(1, math.min(Input.pickerTilesetScroll + dy, maxTs))
    else
      local list = Input.tilesetList(session, Input.pickerTileset)
      local per = Picker.perPage(vw, vh)
      local max = math.max(1, math.ceil(#list / per))
      Input.pickerScroll = math.max(1, math.min(Input.pickerScroll + dy, max))
    end
    return true
  end
  -- Cycle hotbar selection when the picker is closed.
  local n = #Input.hotbar
  if n == 0 then return false end
  Input.selected = ((Input.selected - 1 + dy) % n) + 1
  Input.applySelection(session)
  return true
end

-- Keyboard: returns true when the key was consumed by the overlay.
function Input.keypressed(session, key)
  if key == "e" then
    Input.showPicker = not Input.showPicker
    Input.pickerScroll = 1
    Input.pickerTilesetScroll = 1
    return true
  elseif key == "b" then
    Input.showBlueprints = not Input.showBlueprints
    Input.blueprintScroll = 1
    return true
  elseif key == "r" then
    -- Toggle rectangle-select capture mode.
    Input.blueprintMode = not Input.blueprintMode
    Input.selectStart, Input.selectEnd = nil, nil
    return true
  elseif key == "p" or key == "q" then
    -- Pick the block under the mouse into the selected slot.
    local mx, my = love.mouse.getPosition()
    local vw, vh = love.graphics.getDimensions()
    local b = Input.pickUnder(session, session.game, mx, my, vw, vh)
    if b ~= nil then
      Input.hotbar[Input.selected] = { kind = "block", id = b }
      Input.applySelection(session)
    end
    return true
  elseif key == "z" and (love.keyboard.isDown("lctrl") or love.keyboard.isDown("rctrl")) then
    session:restoreSnapshot("undo")
    session:refreshLiveRenderers()
    return true
  elseif key == "y" and (love.keyboard.isDown("lctrl") or love.keyboard.isDown("rctrl")) then
    session:restoreSnapshot("redo")
    session:refreshLiveRenderers()
    return true
  elseif key >= "1" and key <= "8" then
    local idx = tonumber(key)
    if idx and idx >= 1 and idx <= Hotbar.SLOTS then
      Input.selected = idx
      Input.applySelection(session)
      return true
    end
  end
  return false
end

-- Persists the hotbar layout through the mod save system.
function Input.saveHotbar(mod)
  mod.save:set("mapamap_hotbar", Input.serialize())
end

-- Persists the blueprint book through the mod save system.
function Input.saveBlueprints(mod)
  mod.save:set("mapamap_blueprints", Input.blueprints)
end

-- Loads the saved blueprint book (a list of { id, w, h, tiles }).
function Input.loadBlueprints(mod)
  Input.blueprints = mod.save:get("mapamap_blueprints", {})
end

return Input
