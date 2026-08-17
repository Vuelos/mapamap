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
--   * B         -> open the inventory's Blueprints tab (preview panel)
--   * R         -> toggle rectangle-select blueprint capture (LMB drag)
--
-- This module only routes input.  The UI controller state it reads and mutates
-- lives here on the Input table; the actual work is delegated to focused
-- modules so the dispatchers stay thin:
--   * func/state.lua         -- hotbar/inventory lifecycle + persistence
--   * func/blueprints.lua    -- rectangle-select capture and stamping
--   * func/paint.lua         -- paint / erase / pick / warp dest-pick
--   * components/hotbar.lua  -- selection model (tag/selected/apply/loadItem)
--   * components/inventory.lua -- collection model (add/list)
--   * components/details.lua -- modal Details open/close/keyboard
--   * components/picker.lua  -- catalog and item lists
--
-- All input is guarded by the active flag so the vanilla game is untouched
-- while the overlay is closed.  Coordinates arrive in LOVE screen units.

local Coords = require("mods.mapamap.func.coords")
local Hotbar = require("mods.mapamap.components.hotbar")
local Picker = require("mods.mapamap.components.picker")
local Inventory = require("mods.mapamap.components.inventory")
local Details = require("mods.mapamap.components.details")
local Blueprints = require("mods.mapamap.func.blueprints")
local Paint = require("mods.mapamap.func.paint")
local State = require("mods.mapamap.func.state")

local Input = {}

local function normalizeMouseButton(button)
  if button == nil then return nil end
  if type(button) == "number" then return button end
  local v = tostring(button):lower()
  if v == "left" or v == "lmb" then return 1 end
  if v == "right" or v == "rmb" then return 2 end
  if v == "middle" or v == "mmb" then return 3 end
  return button
end

-- Hotbar: fixed-size array of item slots.  Each slot is
--   { kind = "block", id = <number> }  or  { kind = "sprite", id = <string> }
-- Empty slots are nil.
Input.hotbar = {}
Input.selected = 1
-- The inventory panel: a persistent collection of placeables (blocks,
-- sprites/items, warps, blueprints) stored flat, shown through one tab.
Input.inventory = { items = {}, tab = 1, scroll = 1 }
Input.showInventory = true
Input.mouseButtons = { [1] = false, [2] = false, [3] = false }
-- The tileset picker panel.
Input.showPicker = false
Input.pickerScroll = 1
Input.pickerScrollBase = 0
Input.pickerTilesetScroll = 1  -- page into the open tileset dropdown list
Input.pickerDropOpen = false   -- the tileset dropdown is expanded
-- Which tileset the picker is browsing (nil = the session's map tileset).
Input.pickerTileset = nil
-- Dragging a picker item onto a hotbar slot.
Input.dragItem = nil

-- Blueprint support: a rectangle-select capture mode.  Captured blueprints are
-- stored whole as items in the inventory's Blueprints tab (the inventory is
-- the single blueprint container; there is no separate book).
Input.blueprintMode = false  -- rectangle-select capture is armed
Input.selectStart = nil      -- {bx, by} world-block coords where selection began
Input.selectEnd = nil        -- {bx, by} current world-block selection anchor
Input._bpMoved = false       -- a move happened after the press (it was a drag)

-- Warp editing: a selected warp (from the Warps tab or a world right-click)
-- with a graphical destination-pick mode (C arms it; the next world click sets
-- the target) and a modal Details panel for field editing.
Input.selectedWarp = nil      -- a live def.warps entry, or nil
Input.selectedObject = nil    -- a live def.objects entry, or nil
Input.warpDestPick = false    -- arm "pick destination" for the selected warp
Input.details = nil           -- { target, fields, index, editing } or nil

-- Brush drag state (arm flags, drag anchors, dedupe cells).  Owned here, but
-- read and mutated by func/paint.lua through the `brush` argument.
local brush = {
  painting = false,
  erasing = false,
  draggingWarp = false,
  paintingMap = nil,   -- mapId painted on this drag (blocks only)
  lastBlockX = nil,    -- last painted block coord (re-paint dedupe)
  lastBlockY = nil,
  lastCellX = nil,
  lastCellY = nil,
}

-- The mod's press/release flags are event-driven; a release can be lost to a
-- window focus flip, input recovery or a cancel, and then the brush would stay
-- armed forever.  Every move reconciles the flags against the physical mouse,
-- so letting the button up always ends the drag even if its event never
-- arrives.  No-op when love.mouse.isDown is unavailable (headless harnesses).
local function finishDragDrop(mx, my)
  if not Input.dragItem then return false end
  local vw, vh = love.graphics.getDimensions()
  local slot = Hotbar.at(vw, vh, mx, my)
  local fromSlot = Input.dragFromSlot
  if slot then
    if fromSlot and fromSlot ~= slot then
      Input.hotbar[fromSlot], Input.hotbar[slot] =
        Input.hotbar[slot], Input.hotbar[fromSlot]
      Input.selected = slot
    elseif not fromSlot then
      Input.hotbar[slot] = Input.dragItem
      Input.selected = slot
    end
    Input.applySelection(session)
  elseif Input.showInventory and Inventory.over(vw, vh, mx, my) then
    Input.addInventory(Input.dragItem)
  end
  Input.dragItem = nil
  Input.dragFromSlot = nil
  return true
end

local function reconcileMouseHeld()
  local isDown = love.mouse.isDown
  if not isDown then return end
  if Input.mouseButtons[1] and not isDown(1) then
    Input.mouseButtons[1] = false
    brush.painting = false
    if Input.dragItem then
      -- A physical release outside the UI can happen without the release event
      -- reaching us: settle the drag right here so it cannot remain stranded.
      local mx, my = love.mouse.getPosition()
      finishDragDrop(mx, my)
    end
  end
  if Input.mouseButtons[2] and not isDown(2) then
    Input.mouseButtons[2] = false
    brush.erasing = false
    brush.draggingWarp = false
  end
end

-- True when a mouse button is pressed in the mod's event state and still
-- physically held.  Callers (cursor highlight, brush routing) use this so a
-- stale press flag can never leave the brush visibly armed after release.
function Input.mouseDown(button)
  if not Input.mouseButtons[button] then return false end
  local isDown = love.mouse.isDown
  if isDown then return isDown(button) end
  return true
end

-- The game reports a pointer as cancelled (focus loss, input recovery, window
-- hidden) instead of released: retire every held button and in-flight drag so
-- nothing stays armed waiting for a release that will never come.
function Input.cancelled()
  Input.mouseButtons = { [1] = false, [2] = false, [3] = false }
  brush.painting = false
  brush.erasing = false
  brush.draggingWarp = false
  Input.dragItem = nil
  Input.dragFromSlot = nil
end

-- ---------------------------------------------------------------------------
-- Model facades: thin delegation to the focused modules.  These keep the
-- controller's public API (used by main.lua, the overlay, and the tests)
-- stable while the implementations live next to their data models.

function Input.configure(initial) State.configure(Input, initial) end
function Input.serialize() return State.serialize(Input) end
function Input.addInventory(item) Inventory.add(Input, item) end
function Input.inventoryList(session) return Inventory.list(Input) end
function Input.openDetails(session, target) Details.open(Input, session, target) end
function Input.closeDetails() Details.close(Input) end
function Input.keyDetails(session, key) return Details.key(Input, session, key) end
function Input.reset() State.reset(Input, brush) end
function Input.onMapEntry(session) State.onMapEntry(Input, session) end
function Input.tagBlock(session, item) return Hotbar.tag(session, item) end
function Input.selectedItem() return Hotbar.selected(Input) end
function Input.applySelection(session) return Hotbar.apply(Input, session) end
function Input.blockCellAt(session, mx, my) return Blueprints.cellAt(session, mx, my) end
function Input.captureBlueprint(session) return Blueprints.capture(Input, session) end
function Input.paintBlueprint(session, bid, mx, my)
  return Blueprints.paint(Input, session, bid, mx, my)
end
function Input.pickUnder(session, game, mx, my) return Paint.pickUnder(session, game, mx, my) end
function Input.paintAt(session, mx, my) return Paint.paintAt(Input, brush, session, mx, my) end
function Input.eraseAt(session, mx, my) return Paint.eraseAt(Input, brush, session, mx, my) end
function Input.saveHotbar(mod) State.saveHotbar(Input, mod) end
function Input.saveInventory(mod) State.saveInventory(Input, mod) end
function Input.loadInventory(mod) State.loadInventory(Input, mod) end

-- ---------------------------------------------------------------------------
-- Dispatch

-- Handles love.mousepressed while active.  Returns true when consumed.
function Input.mousepressed(session, game, mx, my, button)
  if not session then return false end
  button = normalizeMouseButton(button)
  if button then Input.mouseButtons[button] = true end
  local vw, vh = love.graphics.getDimensions()
  -- A modal Details panel is open: clicks outside it close it; anything else
  -- (including clicks on the panel) is consumed so the world never paints
  -- underneath.
  if Input.details then
    if Details.over(vw, vh, mx, my) then
      -- A click on a field row selects it; only the DELETE row (an action
      -- button) runs on click. Text editing starts with Enter, so a mouse
      -- click never leaves an edit cursor stuck after release.
      if button == 1 then
        local idx = Details.hit(vw, vh, mx, my)
        local fields = Input.details.fields
        if idx and fields and idx <= #fields then
          Input.details.index = idx
          if fields[idx].type == "action" then
            Details.activate(Input, session, Input.details)
          end
        end
      end
      return true
    end
    Input.closeDetails()
    return true
  end
  -- Blueprint capture is armed.  The first LMB click anchors the rectangle's
  -- start corner; the second LMB click finalizes the end corner, captures the
  -- rectangle into the inventory, and closes the R tool.  A press-drag-release
  -- gesture also works: releasing after a drag captures immediately.
  if Input.blueprintMode and button == 1 then
    local bx, by = Input.blockCellAt(session, mx, my)
    if bx then
      if not Input.selectStart then
        Input.selectStart = { bx = bx, by = by }
        Input.selectEnd = nil
        Input._bpMoved = false
      else
        Input.selectEnd = { bx = bx, by = by }
        Input.captureBlueprint(session)
      end
    end
    return true
  end
  -- Picker drags: start dragging a picker item (LMB over the panel).
  if Input.showPicker and button == 1 then
    -- Tileset dropdown: clicking the button expands/collapses it; picking an
    -- entry from the open list switches the browsed catalog.
    if Picker.dropAt(vw, vh, mx, my) then
      Input.pickerDropOpen = not Input.pickerDropOpen
      if Input.pickerDropOpen then Input.pickerTilesetScroll = 1 end
      return true
    end
    if Input.pickerDropOpen then
      local tsIdx = Picker.dropEntryAt(session, vw, vh, mx, my,
        Input.pickerTilesetScroll)
      if tsIdx then
        local names = Picker.catalog(session)
        if names[tsIdx] then
          Input.pickerTileset = names[tsIdx]
          Input.pickerScroll = 1
        end
        Input.pickerDropOpen = false
      else
        -- Click in the list band but off an entry: close without selecting.
        Input.pickerDropOpen = false
      end
      return true
    end
    local idx = Picker.itemAt(vw, vh, mx, my, Input.pickerScroll)
    if idx then
      local list = Picker.itemList(session, Input.pickerTileset)
      Input.dragItem = list[idx]
      if not Input.dragItem then return true end
      -- A plain click here replaces the current selected hotbar slot; if the
      -- press was also on a hotbar slot, that slot wins instead.
      local slot = Hotbar.at(vw, vh, mx, my)
      if slot then
        Input.hotbar[slot] = Input.dragItem
        Input.selected = slot
      else
        Input.hotbar[Input.selected] = Input.dragItem
      end
      Input.applySelection(session)
      return true
    end
  end
  -- Inventory panel: swap tabs, load a cell into the selected hotbar slot
  -- (Warps cells load a warp placement tool), or right-click for Details.
  if Input.showInventory and Inventory.over(vw, vh, mx, my) then
    if button == 2 then
      local idx = Inventory.itemAt(vw, vh, mx, my, Input.inventory.scroll)
      if idx then
        local item = Inventory.list(Input)[idx]
        if item then
          Details.openForItem(Input, session, item)
        end
      end
      return true
    end
    if button == 1 then
      local tabIdx = Inventory.tabAt(vw, vh, mx, my, session.font)
      if tabIdx then
        Input.inventory.tab = tabIdx
        Input.inventory.scroll = 1
        return true
      end
      local idx = Inventory.itemAt(vw, vh, mx, my, Input.inventory.scroll)
      if idx then
        local item = Inventory.list(Input)[idx]
        if item then
          Hotbar.loadItem(Input, session, item)
        end
        return true
      end
      -- Click inside the panel but outside any tab/cell: consume it so the
      -- world underneath is never painted.
      return true
    end
  end
  -- Hotbar selection.  An LMB press on a filled slot also arms a drag so the
  -- item can be swapped onto another slot or dropped into the inventory.
  local slot = Hotbar.at(vw, vh, mx, my)
  if slot then
    Input.selected = slot
    Input.applySelection(session)
    if button == 1 and Input.hotbar[slot] then
      Input.dragItem = Input.hotbar[slot]
      Input.dragFromSlot = slot
    end
    return true
  end
  -- World paint / erase.
  if button == 1 then
    brush.painting = true
    brush.erasing = false
    brush.lastCellX, brush.lastCellY = nil, nil
    -- Graphical destination-pick: the next world click wires the selected
    -- warp to land on whatever laid-out map is under the cursor.
    if Input.warpDestPick and session.selectedWarp then
      brush.painting = false
      Paint.destPick(Input, session, mx, my)
      return true
    end
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
    local t = Coords.transform(session.game)
    local obj, warp
    if t then
      local tx, ty = Coords.toWorldCell(t, mx, my)
      session.cursorBx, session.cursorBy = tx, ty
      -- Hovered object/warp: select it and open its Details panel.
      obj = session:objectAt(tx, ty)
      if not obj then warp = session:warpAt(tx, ty) end
    end
    if obj then
      session.selectedObject = obj
      Input.openDetails(session, { object = obj })
      return true
    end
    if warp then
      session.selectedWarp = warp
      Input.openDetails(session, { warp = warp })
      return true
    end
    -- A warp tool with a selected warp drags it to a new cell on release.
    local item = Input.selectedItem()
    if item and item.kind == "warp" and session.selectedWarp then
      brush.draggingWarp = true
      return true
    end
    brush.erasing = true
    brush.painting = false
    brush.lastCellX, brush.lastCellY = nil, nil
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
  button = normalizeMouseButton(button)
  if button then Input.mouseButtons[button] = false end
  if Input.blueprintMode and button == 1 and Input.selectStart then
    -- A press-drag-release captures on release; a two-click selection waits
    -- for the second click (handled in mousepressed), so a release without a
    -- drag does nothing but is still consumed so the world never paints.
    if Input._bpMoved then
      local bx, by = Input.blockCellAt(session, mx, my)
      if bx then Input.selectEnd = { bx = bx, by = by } end
      Input.captureBlueprint(session)
    end
    return true
  end
  if button == 1 and Input.dragItem then
    local vw, vh = love.graphics.getDimensions()
    local slot = Hotbar.at(vw, vh, mx, my)
    local fromSlot = Input.dragFromSlot
    if slot then
      if fromSlot and fromSlot ~= slot then
        -- Hotbar-to-hotbar: swap the two slots so nothing is lost.
        Input.hotbar[fromSlot], Input.hotbar[slot] =
          Input.hotbar[slot], Input.hotbar[fromSlot]
        Input.selected = slot
      elseif not fromSlot then
        -- A dragged picker/blueprint entry dropped on the hotbar takes the slot.
        Input.hotbar[slot] = Input.dragItem
        Input.selected = slot
      end
      Input.applySelection(session)
    elseif Input.showInventory and Inventory.over(vw, vh, mx, my) then
      -- A dragged hotbar/picker entry dropped on the inventory lands in the
      -- user's collection (the hotbar copy stays).
      Input.addInventory(Input.dragItem)
    end
    Input.dragItem = nil
    Input.dragFromSlot = nil
    return true
  end
  if button == 2 and brush.draggingWarp then
    -- Release a right-drag: relocate the selected warp to the cursor cell.
    brush.draggingWarp = false
    local t = Coords.transform(session.game)
    if t and session.selectedWarp then
      local tx, ty = Coords.toWorldCell(t, mx, my)
      session:moveWarp(session.selectedWarp, tx, ty)
    end
    return true
  end
  if button == 1 then brush.painting = false end
  if button == 2 then brush.erasing = false end
  return false
end

-- Handles love.mousemoved while active.  Returns true (consume) so the
-- vanilla mouse path never sees editing cursor/brush moves.
function Input.mousemoved(session, mx, my)
  if not session then return false end
  -- A release that was lost (focus flip, cancel) must still end the drag; the
  -- physical button state is the final word on whether the brush is live.
  reconcileMouseHeld()
  if Input.blueprintMode and Input.selectStart then
    -- Extend the selection rectangle (or preview under the cursor); marking the
    -- move distinguishes a drag-release capture from a two-click selection.
    local bx, by = Input.blockCellAt(session, mx, my)
    if bx then
      Input.selectEnd = { bx = bx, by = by }
      Input._bpMoved = true
    end
  elseif brush.painting and Input.mouseButtons[1] then
    Input.paintAt(session, mx, my)
  elseif brush.erasing and Input.mouseButtons[2] then
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
-- Wheel events over the map must pass through to the base game so the usual
-- world zoom behavior is preserved.  Only the overlay's own UI surfaces consume
-- the wheel: inventory, picker, and hotbar slots.
function Input.wheelmoved(session, dy)
  if not session then return false end
  local vw, vh = love.graphics.getDimensions()
  local mx, my = love.mouse.getPosition()
  if Input.showInventory and Inventory.over(vw, vh, mx, my) then
    local list = Inventory.list(Input)
    local per = Inventory.perPage(vw, vh)
    local max = math.max(1, math.ceil(#list / per))
    Input.inventory.scroll = math.max(1, math.min(Input.inventory.scroll + dy, max))
    return true
  end
  if Input.showPicker then
    if Input.pickerDropOpen then
      -- Scroll the open tileset dropdown list.
      local names = Picker.catalog(session)
      local perTs = Picker.dropPerPage(session, vw, vh)
      local maxTs = math.max(1, math.ceil(#names / perTs))
      Input.pickerTilesetScroll = math.max(1, math.min(Input.pickerTilesetScroll + dy, maxTs))
    else
      -- Scroll the item grid.
      local list = Picker.itemList(session, Input.pickerTileset)
      local per = Picker.perPage(vw, vh)
      local max = math.max(1, math.ceil(#list / per))
      Input.pickerScroll = math.max(1, math.min(Input.pickerScroll + dy, max))
    end
    return true
  end
  if Hotbar.at(vw, vh, mx, my) then
    local n = #Input.hotbar
    if n == 0 then return false end
    Input.selected = ((Input.selected - 1 + dy) % n) + 1
    Input.applySelection(session)
    return true
  end
  return false
end

-- Keyboard: returns true when the key was consumed by the overlay.
function Input.keypressed(session, key)
  -- Modal Details panel owns the keyboard while open.
  if Input.details then return Input.keyDetails(session, key) end
  if key == "c" then
    -- Arm graphical destination-pick for the selected warp: the next world
    -- click wires it to the laid-out map under the cursor.
    if session.selectedWarp then
      Input.warpDestPick = not Input.warpDestPick
    end
    return true
  elseif key == "e" then
    Input.showPicker = not Input.showPicker
    Input.pickerScroll = 1
    Input.pickerTilesetScroll = 1
    Input.pickerDropOpen = false
    return true
  elseif key == "b" then
    -- Blueprint preview: focus the inventory's Blueprints tab.  The inventory
    -- is the single blueprint container; B is not a separate book.
    Input.showPicker = false
    Input.inventory.tab = Input.inventory.tab == 4 and 1 or 4
    Input.inventory.scroll = 1
    return true
  elseif key == "tab" then
    Input.showInventory = not Input.showInventory
    return true
  elseif key == "r" then
    -- Toggle rectangle-select capture mode.
    Input.blueprintMode = not Input.blueprintMode
    Input.selectStart, Input.selectEnd = nil, nil
    Input._bpMoved = false
    return true
  elseif key == "o" then
    Input.showMapBorders = not Input.showMapBorders
    return true
  elseif key == "p" or key == "q" then
    -- Pick the block under the mouse into the selected slot.
    local mx, my = love.mouse.getPosition()
    local vw, vh = love.graphics.getDimensions()
    local b, tileset = Input.pickUnder(session, session.game, mx, my, vw, vh)
    if b ~= nil then
      Input.hotbar[Input.selected] = { kind = "block", id = b, tileset = tileset }
      Input.applySelection(session)
    end
    return true
  elseif key == "z" and (love.keyboard.isDown("lctrl") or love.keyboard.isDown("rctrl")) then
    session:restoreSnapshot("undo")
    session:refreshLiveRenderers()
    session:refreshObjects()
    return true
  elseif key == "y" and (love.keyboard.isDown("lctrl") or love.keyboard.isDown("rctrl")) then
    session:restoreSnapshot("redo")
    session:refreshLiveRenderers()
    session:refreshObjects()
    return true
  elseif key >= "0" and key <= "9" then
    local idx = tonumber(key)
    if idx == 0 then idx = 10 end
    if idx and idx >= 1 and idx <= Hotbar.SLOTS then
      Input.selected = idx
      Input.applySelection(session)
      return true
    end
  end
  return false
end

return Input
