-- Mouse/keyboard input for mapamap's direct-paint overlay.
--
-- While the overlay is active:
--   * LMB drag  -> paint the selected block (or place the selected sprite)
--   * LMB click on an entity -> copy it to the active hotbar slot
--   * RMB drag  -> erase back to the snapshot (blocks) / remove object (sprites)
--   * Q         -> pick the block under the cursor into the selected slot
--   * E         -> toggle the tileset picker panel
--   * wheel     -> scroll the open picker (or cycle hotbar when closed)
--   * digit keys -> select a hotbar slot directly
--   * dragging  -> from the picker onto a hotbar slot assigns that item
--   * R         -> toggle rectangle-select blueprint capture (LMB drag)
--   * E / M     -> tileset picker / Brush Maker
--
-- This module only routes input.  The UI controller state it reads and mutates
-- lives here on the Input table, the brush/tool drag state lives in
-- controllers/editor_tools.lua, and the actual work is delegated to focused
-- modules so the dispatchers stay thin:
--   * controllers/editor_tools.lua -- brush/tool drag state + paint/erase routing
--   * storage/config.lua     -- hotbar/inventory lifecycle + persistence
--   * domain/blueprints.lua  -- rectangle-select capture and stamping
--   * domain/paint.lua       -- paint / erase / pick / warp dest-pick
--   * components/hotbar.lua  -- selection model (tag/selected/apply/loadItem)
--   * components/inventory.lua -- collection model (add/list)
--   * components/details.lua -- modal Details open/close/keyboard
--   * components/picker.lua  -- catalog and item lists
--
-- All input is guarded by the active flag so the vanilla game is untouched
-- while the overlay is closed.  Coordinates arrive in LOVE screen units.

local Coords = require("mods.mapamap.engine.coords")
local Gen = require("mods.mapamap.engine.gen")
local Neighbors = require("mods.mapamap.domain.neighbors")
local Common = require("mods.mapamap.common")
local EditorTools = require("mods.mapamap.controllers.editor_tools")
local Hotbar = require("mods.mapamap.components.hotbar")
local Picker = require("mods.mapamap.components.picker")
local Toolbar = require("mods.mapamap.components.toolbar")
local Inventory = require("mods.mapamap.components.inventory")
local Details = require("mods.mapamap.components.details")
local EncEditor = require("mods.mapamap.components.encounter_editor")
local PartyEditor = require("mods.mapamap.components.party_editor")
local DialogEditor = require("mods.mapamap.components.dialog_editor")
local SlotPanel = require("mods.mapamap.components.slot_panel")
local WarpPreview = require("mods.mapamap.components.warp_preview")
local EntityCreator = require("mods.mapamap.components.entity_creator")

-- Self-contained modal panels with a uniform contract, in priority order.
-- MOUSE: component.mousepressed(ui, session, x, y, button) -> handled?;
-- closeOnOutside closes the panel when its handler declines the press.
-- KEYS: component.key(ui, session, key) (always treated as consumed).
local MOUSE_MODALS = {
  { key = "slotsOpen",    component = SlotPanel,    closeOnOutside = true },
  { key = "encEditor",    component = EncEditor,    closeOnOutside = true },
  { key = "partyEditor",  component = PartyEditor,  closeOnOutside = true },
  { key = "dialogEditor", component = DialogEditor },
}
local KEY_MODALS = {
  { key = "slotsOpen",    component = SlotPanel },
  { key = "encEditor",    component = EncEditor },
  { key = "partyEditor",  component = PartyEditor },
  { key = "dialogEditor", component = DialogEditor },
  { key = "details",      component = Details },
  { key = "entityCreator", component = EntityCreator },
}
local BrushEditor = require("mods.mapamap.components.brush_editor")
local EntitySelector = require("mods.mapamap.components.entity_selector")
local EntityCreator = require("mods.mapamap.components.entity_creator")
local Brushes = require("mods.mapamap.domain.brushes")
local Blueprints = require("mods.mapamap.domain.blueprints")
local Paint = require("mods.mapamap.domain.paint")
local State = require("mods.mapamap.storage.config")

-- Self-contained modal panels with a uniform contract, in priority order.
-- MOUSE: component.mousepressed(ui, session, x, y, button) -> handled?;
-- closeOnOutside closes the panel when its handler declines the press.
-- KEYS: component.key(ui, session, key) (always treated as consumed).
local MOUSE_MODALS = {
  { key = "slotsOpen",    component = SlotPanel,    closeOnOutside = true },
  { key = "encEditor",    component = EncEditor,    closeOnOutside = true },
  { key = "partyEditor",  component = PartyEditor,  closeOnOutside = true },
  { key = "dialogEditor", component = DialogEditor },
}
local KEY_MODALS = {
  { key = "slotsOpen",    component = SlotPanel },
  { key = "encEditor",    component = EncEditor },
  { key = "partyEditor",  component = PartyEditor },
  { key = "dialogEditor", component = DialogEditor },
  { key = "details",      component = Details },
  { key = "entityCreator", component = EntityCreator },
}

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
Input.showInventory = false
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

-- Brush Maker: the draft brush being assembled in the panel.  Slots are
-- filled by dragging in; SAVE stores it as an inventory brush item.  When the
-- draft was loaded from a saved brush (RMB on a Brushes-tab cell),
-- brushSource links back to that item: SAVE then updates it in place and
-- DELETE removes it from the collection.
Input.showBrushEditor = false
Input.brushDraft = Brushes.new("Brush")
Input.brushSource = nil

-- Entity creation workflow: the selector lists the creatable types and the
-- creator form (Input.entityCreator) holds the required-data fields for the
-- chosen one.  CREATE arms the selected hotbar slot with the configured tool.
Input.showEntitySelector = false
Input.entityCreator = nil

-- Map Slots panel (components/slot_panel.lua): save-slot management for the
-- whole edit-set.  slotSel is the selected slot name, slotRename the live
-- rename buffer while typing, slotMsg the panel's last status message.
Input.slotsOpen = false
Input.slotSel = nil
Input.slotRename = nil
Input.slotScroll = 1
Input.slotFileScroll = 1
Input.slotMsg = nil

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
Input.selectedItem = nil    -- a live def.objects, def.warps or def.signs entry, or nil
Input.warpDestPick = false    -- arm "pick destination" for the selected warp
Input.details = nil           -- { target, fields, index, editing } or nil
Input.encEditor = nil         -- { session, fields, index, editing } or nil
Input.partyEditor = nil       -- { session, class, partyIndex, obj, mode, ... } or nil
Input.dialogEditor = nil      -- { text, curLine, curCol, caps, onSave } or nil
-- MOVE button from Details arms this: the next world LMB relocates the entity
-- instead of painting.
Input.moveTarget = nil        -- { entity, entityType } or nil

-- One home for "put every floating panel away" (Tab toggle, pointer cancel).
-- Callers that need a specific subset clear their own fields instead.
local function closeOverlays()
  Input.details = nil
  Input.encEditor = nil
  Input.partyEditor = nil
  Input.dialogEditor = nil
  Input.showEntitySelector = false
  Input.entityCreator = nil
  Input.slotsOpen = false
  Input.moveTarget = nil
end

-- The mod's press/release flags are event-driven; a release can be lost to a
-- window focus flip, input recovery or a cancel, and then the brush would stay
-- armed forever.  Every move reconciles the flags against the physical mouse,
-- so letting the button up always ends the drag even if its event never
-- arrives.  No-op when love.mouse.isDown is unavailable (headless harnesses).

-- Settles an in-flight drag at (mx, my): drops onto a Brush Maker slot, an
-- Entity Creator field, a hotbar slot (swap / assign), or the inventory.
-- Returns true when the drag item was consumed.  This is THE drop path -- used
-- by both mousereleased and the lost-release reconcile below so the two can
-- never diverge again.
local function dropDragItem(session, mx, my)
  if not Input.dragItem then return false end
  local vw, vh = love.graphics.getDimensions()
  -- Dropping on a Brush Maker slot stores a copy of the tile there (only
  -- block items can be brush tiles; anything else is just consumed).
  if Input.showBrushEditor then
    local key = BrushEditor.slotKeyAt(vw, vh, mx, my)
    if key then
      if Input.dragItem.kind == "block" then
        Brushes.setSlot(Input.brushDraft, key, Common.deepCopy(Input.dragItem))
      end
      Input.dragItem, Input.dragFromSlot = nil, nil
      return true
    end
  end
  -- Dropping on an Entity Creator field (sprite slot / species / item).
  if Input.entityCreator
      and EntityCreator.acceptDrop(Input, session, mx, my, Input.dragItem) then
    Input.dragItem, Input.dragFromSlot = nil, nil
    return true
  end
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
    -- user's collection (the hotbar copy stays).  The panel stays put: the
    -- entry only shows on its respective tab.
    Input.addInventory(Input.dragItem, { silent = true })
  end
  Input.dragItem, Input.dragFromSlot = nil, nil
  return true
end

local function reconcileMouseHeld(session)
  local isDown = love.mouse.isDown
  if not isDown then return end
  if Input.mouseButtons[1] and not isDown(1) then
    Input.mouseButtons[1] = false
    EditorTools.stopPaint()
    if Input.dragItem then
      -- A physical release outside the UI can happen without the release event
      -- reaching us: settle the drag right here so it cannot remain stranded.
      local mx, my = love.mouse.getPosition()
      dropDragItem(session, mx, my)
    end
  end
  if Input.mouseButtons[2] and not isDown(2) then
    Input.mouseButtons[2] = false
    EditorTools.stopErase()
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
  closeOverlays()
  Input.dragItem = nil
  Input.dragFromSlot = nil
  EditorTools.cancelled()
end

-- ---------------------------------------------------------------------------
-- Model facades: thin delegation to the focused modules.  These keep the
-- controller's public API (used by main.lua, the overlay, and the tests)
-- stable while the implementations live next to their data models.

function Input.configure(initial) State.configure(Input, initial) end
function Input.serialize() return State.serialize(Input) end
function Input.addInventory(item, opts) Inventory.add(Input, item, opts) end
function Input.inventoryList(session) return Inventory.list(Input) end
function Input.openDetails(session, target)
  -- Details draws at the selector's spot: drop the creation form so the two
  -- never overlap.
  Input.entityCreator = nil
  Details.open(Input, session, target)
end
function Input.closeDetails() Details.close(Input) end
function Input.keyDetails(session, key) return Details.key(Input, session, key) end
function Input.reset()
  EditorTools.reset()
  State.reset(Input)
end
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
function Input.paintAt(session, mx, my) return EditorTools.apply(Input, session, mx, my) end
function Input.eraseAt(session, mx, my) return EditorTools.erase(Input, session, mx, my) end
function Input.commitVoidStroke(session) return EditorTools.commitVoidStroke(session) end
function Input.saveHotbar(mod) State.saveHotbar(Input, mod) end
function Input.saveInventory(mod) State.saveInventory(Input, mod) end
function Input.loadInventory(mod) State.loadInventory(Input, mod) end

-- Stores the Brush Maker draft as a brush item in the inventory (Brushes
-- tab).  Requires at least the center tile; everything else is optional.
-- A draft loaded from a saved brush updates that brush in place instead of
-- appending a duplicate.
function Input.saveBrushDraft()
  local draft = Input.brushDraft
  if not Brushes.isComplete(draft) then return false end
  if Input.brushSource then
    for i, it in ipairs(Input.inventory.items) do
      if it == Input.brushSource then
        Input.inventory.items[i] = Brushes.clone(draft)
        Input.brushSource = nil
        return true
      end
    end
    -- The source vanished from the collection: fall through to append.
    Input.brushSource = nil
  end
  local brush = Brushes.clone(draft)
  brush.name = "Brush " .. tostring(os.time() % 100000)
  Input.addInventory(brush)
  return true
end

-- Empties every draft slot (optional positions fall back again) and detaches
-- the draft from any saved brush it was loaded from.
function Input.clearBrushDraft()
  Input.brushDraft = Brushes.new(Input.brushDraft and Input.brushDraft.name or nil)
  Input.brushSource = nil
end

-- Removes the saved brush the draft was loaded from (DELETE button).  The
-- draft itself keeps its slots so it can be tweaked and re-saved; returns
-- false when there is nothing linked (or the item is already gone).
function Input.deleteBrushSource()
  local src = Input.brushSource
  if not src then return false end
  for i, it in ipairs(Input.inventory.items) do
    if it == src then
      table.remove(Input.inventory.items, i)
      Input.brushSource = nil
      return true
    end
  end
  Input.brushSource = nil
  return false
end

-- Loads an existing brush into the maker for editing (RMB on a Brushes-tab
-- cell).  The draft is a copy, so SAVE stores the result as a new entry and
-- the original stays untouched until then.
function Input.editBrush(item)
  if not item or item.kind ~= "brush" then return false end
  local copy = Common.deepCopy(item)
  copy.kind = "brush"
  Input.brushDraft = copy
  Input.brushSource = item
  Input.showBrushEditor = true
  Input.showInventory = true
  Input.inventory.tab = Inventory.tabFor(item)
  Input.inventory.scroll = 1
  return true
end

-- Opens the Entity Creator form for a selector type (the selector button
-- click routes here).
function Input.openCreator(session, typeKey)
  return EntityCreator.open(Input, session, typeKey)
end

-- ---------------------------------------------------------------------------
-- Toolbar toggle helpers (shared between keyboard and mouse)

local function toggleInventory()
  if Input.showInventory then
    Input.showPicker = false
    Input.showBrushEditor = false
    closeOverlays()
  end
  Input.showInventory = not Input.showInventory
end

local function toggleEncounters(session)
  Input.showPicker = false
  Input.showEntitySelector = false
  Input.entityCreator = nil
  Input.slotsOpen = false
  if Input.encEditor then
    Input.encEditor = nil
  else
    EncEditor.open(Input, session)
    Input.showInventory = true
  end
end

local function togglePicker()
  Input.showPicker = not Input.showPicker
  if Input.showPicker then
    -- The picker shares the selector's side-panel spot.
    Input.showEntitySelector = false
    Input.entityCreator = nil
    Input.slotsOpen = false
    Input.showInventory = true
  end
  Input.pickerScroll = 1
  Input.pickerTilesetScroll = 1
  Input.pickerDropOpen = false
end

-- Entity creation workflow: toggles the selector + creator panel pair.  The
-- picker/details/encounter editor share the selector's spot, so opening the
-- factory closes them.
local function toggleFactory(session)
  if Input.showEntitySelector then
    Input.showEntitySelector = false
    Input.entityCreator = nil
  else
    Input.showPicker = false
    Input.details = nil
    Input.encEditor = nil
    Input.slotsOpen = false
    Input.showEntitySelector = true
    Input.showInventory = true
  end
end

local function toggleBlueprint()
  Input.blueprintMode = not Input.blueprintMode
  Input.selectStart, Input.selectEnd = nil, nil
  Input._bpMoved = false
end

local function toggleBrushMaker()
  Input.showBrushEditor = not Input.showBrushEditor
  if Input.showBrushEditor then
    -- Tiles are dragged in from the inventory/picker, so make sure a source
    -- panel is open alongside the maker.
    Input.showInventory = true
  end
end

-- Map Slots surface: the save-slot manager shares the side-panel spot with
-- the picker/factory/encounter editor, so opening it closes those.
local function toggleSlots()
  Input.slotsOpen = not Input.slotsOpen
  if Input.slotsOpen then
    Input.showPicker = false
    Input.showEntitySelector = false
    Input.entityCreator = nil
    Input.details = nil
    Input.encEditor = nil
    Input.slotMsg = nil
    Input.showInventory = true
  end
end

-- Mapping from toolbar button index to the toggle action.
local TOOL_TOGGLES = {
  toggleInventory,
  toggleEncounters,
  function() Input.showMapBorders = not Input.showMapBorders end,
  function() Input.showEntityOverlays = not Input.showEntityOverlays end,
  togglePicker,
  toggleBlueprint,
  toggleBrushMaker,
  toggleFactory,
  toggleSlots,
}

-- ---------------------------------------------------------------------------
-- Dispatch

-- Handles love.mousepressed while active.  Returns true when consumed.
function Input.mousepressed(session, game, mx, my, button)
  if not session then return false end
  button = normalizeMouseButton(button)
  if button then Input.mouseButtons[button] = true end
  local vw, vh = love.graphics.getDimensions()
  -- Self-contained modals (uniform mousepressed contract), in priority
  -- order.  closeOnOutside: an outside click closes the panel; otherwise the
  -- handler owns the whole press (the composer cancels on outside itself).
  for _, m in ipairs(MOUSE_MODALS) do
    if Input[m.key] then
      if m.component.mousepressed(Input, session, mx, my, button) then
        return true
      end
      if m.closeOnOutside then
        if m.component.close then m.component.close(Input)
        else Input[m.key] = nil end
        return true
      end
    end
  end
  -- Warp destination preview panel (creator form / Details warp editing):
  -- LMB selects an existing destination warp or creates one on the clicked
  -- tile; RMB removes a marker.  Checked BEFORE the Details outside-close
  -- so clicking the panel never dismisses the editor.
  if (Input.entityCreator and Input.entityCreator.entityType == "warp")
      or (Input.details and Input.details.entityType == "warp"
          and Input.details.entity) then
    local hit, destMap = WarpPreview.interact(Input, session, mx, my)
    if hit then
      return WarpPreview.applyClick(Input, session, hit, destMap, button)
    end
  end
  -- A modal Details panel is open: clicks outside it close it; anything else
  -- (including clicks on the panel) is consumed so the world never paints
  -- underneath.
  if Input.details then
    if Details.over(vw, vh, mx, my) then
      if button == 1 then
        -- Bottom action strip (MOVE / EDIT / REMOVE) takes priority.
        local bid = Details.buttonAt(Input.details, vw, vh, mx, my)
        if bid then
          Details.pressButton(Input, session, Input.details, bid)
          return true
        end
        -- A click on a field row selects it; in-field actions (encounters,
        -- team) run on click. Text editing starts with Enter, so a mouse
        -- click never leaves an edit cursor stuck after release.
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
  -- Entity Creator form (docked next to the selector): consume clicks inside
  -- it so the world never paints underneath; outside clicks fall through so
  -- the hotbar/toolbar stay reachable while a form is open.
  if Input.entityCreator and button then
    if EntityCreator.mousepressed(Input, session, mx, my, button) then
      return true
    end
  end
  -- Entity Selector buttons: clicking a type opens/retargets the creator
  -- form (encounters are not creatable here; they keep the N/toolbar editor).
  if Input.showEntitySelector and button == 1 then
    local tIdx = EntitySelector.buttonAt(vw, vh, mx, my)
    if tIdx then
      local t = EntitySelector.typeAt(tIdx, Gen.isGen2())
      if t then Input.openCreator(session, t.key) end
      return true
    end
    if EntitySelector.over(vw, vh, mx, my) then return true end
  end
  -- Brush Maker panel: buttons run on click; a filled slot is picked back up
  -- as a drag copy (LMB) or cleared (RMB); any other press inside the panel
  -- is consumed so the world underneath never paints.
  if Input.showBrushEditor and button then
    local which = BrushEditor.buttonAt(vw, vh, mx, my)
    if which == "save" then
      Input.saveBrushDraft()
      return true
    elseif which == "clear" then
      Input.clearBrushDraft()
      return true
    elseif which == "delete" then
      Input.deleteBrushSource()
      return true
    end
    local key = BrushEditor.slotKeyAt(vw, vh, mx, my)
    if key then
      if button == 2 then
        Brushes.setSlot(Input.brushDraft, key, nil)
      elseif button == 1 then
        local held = Hotbar.selected(Input)
        if held and held.kind == "block" then
          -- A tile on the hotbar paints the slot directly (click or drag).
          Brushes.setSlot(Input.brushDraft, key, Common.deepCopy(held))
        else
          -- Nothing selected: click grabs the slot's tile onto the hotbar.
          local cur = Brushes.slot(Input.brushDraft, key)
          if cur then
            Input.hotbar[Input.selected] = Common.deepCopy(cur)
            Input.applySelection(session)
          end
        end
      end
      return true
    end
    if BrushEditor.over(vw, vh, mx, my) then return true end
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
          -- Brushes edit in the Brush Maker; everything else opens Details.
          if item.kind == "brush" then
            Input.editBrush(item)
          else
            Details.openForItem(Input, session, item)
          end
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
      -- The first grid cell of every tab is that tab's toolbar shortcut:
      -- [E] picker on Tiles, [F] factory on Entities, [R] blueprint
      -- rect-select on Blueprints, [M] Brush Maker on Brushes.
      local sc = Inventory.shortcutAt(vw, vh, mx, my)
      if sc then
        local tab = Input.inventory.tab
        if tab == 2 then
          toggleFactory(session)
        elseif tab == 3 then
          Input.showPicker = false
          toggleBlueprint()
        elseif tab == 4 then
          toggleBrushMaker()
        else
          togglePicker()
        end
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
  -- Toolbar toggle strip at the right of the hotbar.
  local toolIdx = Toolbar.at(vw, vh, mx, my)
  if toolIdx then
    if button == 1 then
      TOOL_TOGGLES[toolIdx](session)
    end
    return true
  end
  -- Hotbar selection.
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
    -- A pending MOVE from the Details strip: land the carried entity on this
    -- cell instead of painting/picking up.
    if Input.moveTarget then
      local mt = Input.moveTarget
      Input.moveTarget = nil
      local t = Coords.transform(session.game)
      if t then
        local tx, ty = Coords.toWorldCell(t, mx, my)
        -- Follows the laid-out map owning the destination cell (a MOVE can
        -- carry an entity across a seam).
        if tx and ty then
          session:relocateEntityWorld(mt.entity, mt.entityType, tx, ty)
        end
      end
      return true
    end
    -- Click on a world entity: copy it to the active hotbar slot instead of
    -- painting, so the user can pick it up with LMB.  Neighbor-aware: an
    -- entity on another laid-out map is picked up as a copy of itself.
    local t = Coords.transform(session.game)
    local pickedEntity, pickedType
    if t then
      local tx, ty = Coords.toWorldCell(t, mx, my)
      if tx and ty then
        session.cursorBx, session.cursorBy = tx, ty
        pickedEntity, pickedType = session:entityAtWorld(tx, ty)
      end
    end
    if pickedEntity then
      session.selectedItem = pickedEntity
      local slotItem
      if pickedType == "warp" then
        slotItem = { kind = "entity", entityType = "warp",
          destMap = pickedEntity.destMap, destWarp = pickedEntity.destWarp,
          warp = pickedEntity }
      elseif pickedType == "object" then
        slotItem = { kind = "entity", entityType = "object", obj = pickedEntity }
      else
        slotItem = { kind = "entity", entityType = "sign", sign = pickedEntity }
      end
      Input.hotbar[Input.selected] = slotItem
      Hotbar.apply(Input, session)
      return true
    end
    -- Graphical destination-pick: the next world click wires the selected
    -- warp to land on whatever laid-out map is under the cursor.
    if Input.warpDestPick and session.selectedItem then
      Paint.destPick(Input, session, mx, my)
      return true
    end
    -- Arm the paint brush (a press without a drag still places one block).
    EditorTools.armPaint()
    Input.applySelection(session)
    -- Paint the cell under the cursor immediately (a press without a drag
    -- must still place one block).
    if t then
      local tx, ty = Coords.toWorldCell(t, mx, my)
      if tx and ty then
        session.cursorBx, session.cursorBy = tx, ty
      end
      Input.paintAt(session, mx, my)
    end
    return true
  elseif button == 2 then
    local t = Coords.transform(session.game)
    local entity, entityType, mapId, mapDef
    if t then
      local tx, ty = Coords.toWorldCell(t, mx, my)
      if tx and ty then
        session.cursorBx, session.cursorBy = tx, ty
        -- ANY entity under a right-click opens its Details panel
        -- immediately and FULLY editable, wherever it lives: neighbor
        -- entities behave exactly like same-map ones (field edits write
        -- through, REMOVE lifts them off their owner map, MOVE lands them
        -- anywhere via relocateEntityWorld).
        local ent, et = session:entityAtWorld(tx, ty)
        if ent then
          Input.openDetails(session, { entity = ent, entityType = et })
          return true
        end
        mapId, mapDef = Neighbors.mapAt(session.def, session.neighbors,
          tx, ty)
      end
    end
    -- Right-click on a map body opens its Details (rename) on release.  A drag
    -- (detected in mousemoved) still erases; only a click opens the panel.
    if mapDef and Input.showMapBorders then
      EditorTools.deferMapClick(mx, my, mapId or session.mapId)
      return true
    end
    EditorTools.armErase()
    if t then
      local tx, ty = Coords.toWorldCell(t, mx, my)
      if tx and ty then
        session.cursorBx, session.cursorBy = tx, ty
      end
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
  if button == 1 and dropDragItem(session, mx, my) then
    return true
  end
  if button == 2 then
    -- Right-click on a map body opens its Details to rename it (the press
    -- deferred the click-vs-erase decision; entity Details already opened
    -- at press).
    local mc = EditorTools.takeMapClick()
    if mc then
      local def = (mc.mapId == session.mapId) and session.def
        or session.data.maps[mc.mapId]
      if def then
        Input.openDetails(session, { map = def, mapId = mc.mapId })
      end
      return true
    end
    -- A plain RMB release settles the erase brush.
    EditorTools.stopErase()
  end
  if button == 1 then
    EditorTools.stopPaint()
    -- A block-paint stroke that hit void buffered its cells; create one map
    -- covering the whole drag and paint them into it now.
    Input.commitVoidStroke(session)
  end
  return false
end

-- Handles love.mousemoved while active.  Returns true (consume) so the
-- vanilla mouse path never sees editing cursor/brush moves.
function Input.mousemoved(session, mx, my)
  if not session then return false end
  -- A release that was lost (focus flip, cancel) must still end the drag; the
  -- physical button state is the final word on whether the brush is live.
  reconcileMouseHeld(session)
  if Input.blueprintMode and Input.selectStart then
    -- Extend the selection rectangle (or preview under the cursor); marking the
    -- move distinguishes a drag-release capture from a two-click selection.
    local bx, by = Input.blockCellAt(session, mx, my)
    if bx then
      Input.selectEnd = { bx = bx, by = by }
      Input._bpMoved = true
    end
  elseif EditorTools.isPainting() and Input.mouseButtons[1] then
    Input.paintAt(session, mx, my)
  elseif Input.mouseButtons[2] then
    -- A right-drag over a map body is an erase, not a details click: once the
    -- pointer moves past the threshold, cancel the pending click and erase.
    if EditorTools.maybeEraseFromMap(mx, my) then
      Input.eraseAt(session, mx, my)
    elseif EditorTools.isErasing() then
      Input.eraseAt(session, mx, my)
    end
  end
  -- Track the cursor for the highlight; cheap and always useful.
  local t = Coords.transform(session.game)
  if t then
    local tx, ty = Coords.toWorldCell(t, mx, my)
    if tx and ty then
      session.cursorBx, session.cursorBy = tx, ty
    end
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
  -- Map Slots: scroll whichever section (slots list / export files) the
  -- wheel is over; consume so it never cycles the hotbar underneath.
  if Input.slotsOpen and SlotPanel.over(vw, vh, mx, my) then
    return SlotPanel.scroll(Input, session, dy)
  end
  -- The Brush Maker has nothing to scroll; consume the wheel so it never
  -- cycles the hotbar underneath.
  if Input.showBrushEditor and BrushEditor.over(vw, vh, mx, my) then
    return true
  end
  -- Entity Creator: scroll the open dropdown list when the wheel is over the
  -- form (consume so it never cycles the hotbar underneath).
  if Input.entityCreator and EntityCreator.over(vw, vh, mx, my) then
    EntityCreator.scroll(Input, dy)
    return true
  end
  if Input.showInventory and Inventory.over(vw, vh, mx, my) then
    local list = Inventory.list(Input)
    local per = Inventory.contentPerPage(vw, vh)
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
  -- Encounter editor: scroll the species dropdown when open and hovered.
  if Input.encEditor and Input.encEditor.dropdown
      and EncEditor.over(vw, vh, mx, my) then
    EncEditor.scrollSpecies(Input, dy)
    return true
  end
  -- Party editor: consume the wheel over the panel (scrolls the open
  -- species dropdown) so it never cycles the hotbar underneath.
  if Input.partyEditor and PartyEditor.over(vw, vh, mx, my) then
    PartyEditor.scroll(Input, dy)
    return true
  end
  return false
end

-- Keyboard: returns true when the key was consumed by the overlay.
function Input.keypressed(session, key)
  -- Modal panels own the keyboard while open, in priority order (all share
  -- the uniform key(ui, session, key) contract).
  for _, m in ipairs(KEY_MODALS) do
    if Input[m.key] then
      return m.component.key(Input, session, key) or true
    end
  end
  -- A pending MOVE relocation is cancelled by Escape (not intercepted by
  -- modals since Details was closed when MOVE was armed).
  if key == "escape" and Input.moveTarget then
    Input.moveTarget = nil
    return true
  end
  if key == "n" then
    toggleEncounters(session)
    return true
  elseif key == "f" then
    toggleFactory(session)
    return true
  elseif key == "c" then
    -- Arm graphical destination-pick for the selected warp: the next world
    -- click wires it to the laid-out map under the cursor.
    if session.selectedItem then
      Input.warpDestPick = not Input.warpDestPick
    end
    return true
  elseif key == "e" then
    togglePicker()
    return true
  elseif key == "m" then
    toggleBrushMaker()
    return true
  elseif key == "v" then
    toggleSlots()
    return true
  elseif key == "tab" then
    toggleInventory()
    return true
  elseif key == "r" then
    toggleBlueprint()
    return true
  elseif key == "o" then
    Input.showMapBorders = not Input.showMapBorders
    return true
  elseif key == "p" then
    Input.showEntityOverlays = not Input.showEntityOverlays
    return true
  elseif key == "q" then
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
    return true
  elseif key == "y" and (love.keyboard.isDown("lctrl") or love.keyboard.isDown("rctrl")) then
    session:restoreSnapshot("redo")
    session:refreshLiveRenderers()
    return true
  elseif key >= "0" and key <= "9" then
    local idx = tonumber(key)
    if idx == 0 then idx = 10 end
    if idx and idx >= 1 and idx <= Hotbar.SLOTS then
      Input.selected = idx
      Input.applySelection(session)
      return true
    end
  elseif key == "escape" then
    -- Esc NEVER closes the editor (that is Y alone): it tidies the overlay,
    -- dismissing the inventory surface when it is open.  Panels with their
    -- own Esc handling (Details, creators, dropdowns...) consumed the key
    -- before this tail ran.
    if Input.showInventory then toggleInventory() end
    return true
  end
  return false
end

-- Returns true if the mouse is over an entity
function Input.mouseHoveringSingleCellItem(session)
  local t = Coords.transform(session.game)
  local mx, my = love.mouse.getPosition()
  if not t then return false end
  local tx, ty = Coords.toWorldCell(t, mx, my)
  if tx and ty then
        session.cursorBx, session.cursorBy = tx, ty
      end
  -- Resolve the laid-out map that owns this cell first: the session's *At
  -- lookups scan only the edited map's def, so hovering an entity on any
  -- other visible map answered nil and the cursor stayed block-snapped.
  local mapId, def, ox, oy = Neighbors.mapAt(session.def, session.neighbors,
    tx, ty)
  if not def then return false end
  if not mapId then
    -- Current map: the session's unified entityAt (object > warp > sign).
    return session:entityAt(tx, ty) ~= nil
  end
  local lx = math.floor((tx * Common.CELL_PX - ox) / Common.CELL_PX)
  local ly = math.floor((ty * Common.CELL_PX - oy) / Common.CELL_PX)
  for _, w in ipairs(def.warps or {}) do
    if w.x == lx and w.y == ly then return true end
  end
  for _, o in ipairs(def.objects or {}) do
    if o.x == lx and o.y == ly then return true end
  end
  for _, s in ipairs(def.signs or {}) do
    if s.x == lx and s.y == ly then return true end
  end
  -- Gen 2 has no def.signs: readable background events are its signs
  -- (kinds 0-6; 7 ITEM / 8 COPY are not).
  for _, ev in ipairs(def.bgEvents or {}) do
    if (ev.kind or 0) <= 6 and ev.x == lx and ev.y == ly then return true end
  end
  return false
end

return Input
