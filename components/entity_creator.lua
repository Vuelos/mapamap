-- Entity Creator panel: the second half of the entity creation workflow.
--
-- A form panel (docked one slot right of the Entity Selector) holding ONLY
-- the fields the chosen entity type requires from the user:
--   npc      -> name, movement (stands/walks), facing-or-roam range, dialog
--               text, sprite SLOT (drag one in from the picker)
--   item     -> item id (dropdown)
--   battler  -> trainer class (dropdown), party #, sprite SLOT
--   mon      -> species (dropdown), level, sprite SLOT
--   sign     -> label, text
--   warp     -> dest map (dropdown), dest warp #
--
-- Sprite fields are DRAG SLOTS, not dropdowns: drag a sprite cell in from the
-- picker (People / Monsters / Balls tabs), click the slot with a sprite armed
-- on the hotbar, or RMB to clear.  Walk/dialog use friendly choice rows that
-- cycle with Left/Right or Enter -- no engine ids to type.
--
-- CREATE validates the form, builds the placement tool ({ kind = "entity",
-- ... create = {...} } or { kind = "item" }) and loads it into the selected
-- hotbar slot; the next LMB paint places the configured entity (routed
-- through domain/paint.lua into Objects:placeObjectSpec /
-- Signs:placeSignSpec / Warps.placeWarp).
--
-- Keyboard mirrors Details + the encounter editor: Up/Down move (the CREATE
-- button is the last row), Left/Right cycle choices / nudge numbers, Enter
-- edits text / opens the dropdown / runs CREATE (on a slot it opens the
-- picker), Escape backs out one level or closes the form.

local Common = require("mods.mapamap.common")
local Inventory = require("mods.mapamap.components.inventory")
local Item = require("mods.mapamap.components.item")
local Objects = require("mods.mapamap.domain.objects")
local Panel = require("mods.mapamap.components.panel")
local Text = require("mods.mapamap.components.text")
local Hotbar = require("mods.mapamap.components.hotbar")

local EntityCreator = {}

EntityCreator.DROP_H = 20

local PAD = Panel.PAD
local ROW_H = Panel.ROW_H

-- Friendly movement/range vocabularies (domain-owned; shared with Details).
local MOVEMENT_CHOICES = Objects.MOVEMENT_CHOICES
local RANGE_CHOICES = Objects.RANGE_CHOICES

local function rangeChoicesFor(movement)
  return RANGE_CHOICES[movement] or RANGE_CHOICES.STAY
end

-- ---------------------------------------------------------------------------
-- Catalog data (sorted id lists for the dropdowns)

local function sortedKeys(t)
  local out = {}
  for k in pairs(t or {}) do out[#out + 1] = tostring(k) end
  table.sort(out)
  return out
end

-- The id list a dropdown field browses, by list key.
function EntityCreator.listFor(session, listKey)
  local data = session and session.data or {}
  if listKey == "sprites" then return sortedKeys(data.sprites) end
  if listKey == "items" then return sortedKeys(data.items) end
  if listKey == "trainers" then return sortedKeys(data.trainers) end
  if listKey == "maps" then return sortedKeys(data.maps) end
  if listKey == "species" then
    if type(session.speciesList) == "function" then
      return session:speciesList()
    end
    local out = {}
    for k, v in pairs(data.pokemon or {}) do
      if type(v) == "table" and v.dex then out[#out + 1] = k end
    end
    table.sort(out)
    return out
  end
  return {}
end

local function firstOf(session, listKey)
  return EntityCreator.listFor(session, listKey)[1] or ""
end

-- ---------------------------------------------------------------------------
-- Form fields: exactly the user-required data per entity type

function EntityCreator.build(session, entityType)
  local fields = {}
  local function add(key, label, value, kind, list)
    fields[#fields + 1] = { key = key, label = label, value = value,
                            type = kind or "text", list = list }
  end
  local function addChoice(key, label, value, choices)
    fields[#fields + 1] = { key = key, label = label, value = value,
                            type = "choice", choices = choices }
  end
  if entityType == "npc" then
    add("label", "Name", "New NPC", "text")
    addChoice("movement", "Walks", "STAY", MOVEMENT_CHOICES)
    addChoice("range", "Facing", "DOWN", rangeChoicesFor("STAY"))
    add("text", "Dialog", "", "text")
    add("sprite", "Sprite", nil, "slot")
  elseif entityType == "item" then
    add("item", "Item", firstOf(session, "items"), "dropdown", "items")
  elseif entityType == "battler" then
    add("trainerClass", "Class", firstOf(session, "trainers"),
      "dropdown", "trainers")
    add("trainerParty", "Party #", "1", "number")
    add("sprite", "Sprite", nil, "slot")
  elseif entityType == "mon" then
    add("pokemon", "Species", firstOf(session, "species"), "dropdown", "species")
    add("level", "Level", "5", "number")
    add("sprite", "Sprite", nil, "slot")
  elseif entityType == "sign" then
    add("label", "Label", "New Sign", "text")
    add("text", "Text", "...", "text")
  elseif entityType == "warp" then
    add("destMap", "Dest map", session.mapId or "", "dropdown", "maps")
    add("destWarp", "Warp #", "0", "number")
  end
  return fields
end

-- The display text of a choice field's current value.
function EntityCreator.choiceLabel(f)
  for _, c in ipairs(f.choices or {}) do
    if c.id == f.value then return c.label end
  end
  return tostring(f.value)
end

-- Cycles a choice field's value by delta (wrapping).  Returns the new id.
-- When the movement field moves, the range field's vocabulary follows.
function EntityCreator.cycleChoice(d, f, delta)
  local choices = f.choices or {}
  if #choices == 0 then return f.value end
  local idx = 1
  for i, c in ipairs(choices) do
    if c.id == f.value then idx = i break end
  end
  idx = ((idx - 1 + delta) % #choices) + 1
  f.value = choices[idx].id
  if f.key == "movement" and d and d.fields then
    for _, other in ipairs(d.fields) do
      if other.key == "range" then
        other.choices = rangeChoicesFor(f.value)
        local ok = false
        for _, c in ipairs(other.choices) do
          if c.id == other.value then ok = true break end
        end
        if not ok then other.value = other.choices[1].id end
      end
    end
  end
  return f.value
end

function EntityCreator.title(d)
  local Selector = require("mods.mapamap.components.entity_selector")
  for _, t in ipairs(Selector.TYPES) do
    if t.key == (d and d.entityType) then return "NEW " .. t.label end
  end
  return "NEW ENTITY"
end

-- ---------------------------------------------------------------------------
-- Geometry

function EntityCreator.rect(vw, vh)
  local x, y, w, h = Inventory.sideRect(vw, vh)
  return x + w + Inventory.SIDE_GAP, y, w, h
end

function EntityCreator.over(vw, vh, mx, my)
  return Panel.over(EntityCreator.rect, vw, vh, mx, my)
end

-- Slot rows carry a square drag target (Inventory.SLOT), so they stride
-- taller than plain text rows.
local function strideOf(f)
  return (f and f.type == "slot") and (Inventory.SLOT + 6) or (ROW_H + 6)
end

-- Top Y of row i (fields = the open form's field list).
local function rowTop(fields, y, i)
  local top = y + PAD + 20
  for j = 1, i - 1 do top = top + strideOf(fields[j]) end
  return top
end

-- The field index whose row a screen point falls over, or nil.
function EntityCreator.hit(vw, vh, mx, my, d)
  local x, y, w, h = EntityCreator.rect(vw, vh)
  if mx < x or mx >= x + w or my < y or my >= y + h then return nil end
  local fields = d and d.fields or {}
  local top = rowTop(fields, y, 1)
  if my < top then return nil end
  for i = 1, #fields do
    if my < top + strideOf(fields[i]) then return i end
    top = top + strideOf(fields[i])
  end
  return nil
end

-- The CREATE button: a full-width bar pinned above the hint footer.
function EntityCreator.createBtnRect(vw, vh)
  local x, y, w, h = EntityCreator.rect(vw, vh)
  return x + PAD, y + h - PAD - 14 - ROW_H, w - PAD * 2, ROW_H
end

function EntityCreator.createBtnHit(vw, vh, mx, my)
  local bx, by, bw, bh = EntityCreator.createBtnRect(vw, vh)
  return mx >= bx and mx < bx + bw and my >= by and my < by + bh
end

-- Value-column rect for a field row (right half, like Details values).
local function valueAreaRect(d, vw, vh, rowIdx)
  local x, y, w = EntityCreator.rect(vw, vh)
  local ry = rowTop(d.fields or {}, y, rowIdx)
  return x + w / 2, ry, w / 2 - PAD, ROW_H
end

-- Square drag-slot rect for a "slot" field row (at the value column).
local function spriteSlotRect(d, vw, vh, rowIdx)
  local vx, vy = valueAreaRect(d, vw, vh, rowIdx)
  return vx + 2, vy, Inventory.SLOT, Inventory.SLOT
end

-- The sprite slot FIELD under a screen point while a form is open (drag-drop
-- target lookup for finishDragDrop).  Returns the field or nil.
function EntityCreator.slotAt(ui, vw, vh, mx, my)
  local d = ui and ui.entityCreator
  if not d then return nil end
  local idx = EntityCreator.hit(vw, vh, mx, my, d)
  local f = idx and d.fields[idx]
  if f and f.type == "slot" then return f end
  return nil
end

-- Bounding rect of the open dropdown list for the active row: directly below
-- it, clamped above the CREATE button.
function EntityCreator.dropRect(vw, vh, d, rowIdx, scrollOffset)
  local x, y, w, h = EntityCreator.rect(vw, vh)
  local ry = rowTop(d.fields or {}, y, rowIdx)
  local dropTop = ry + ROW_H + 6
  local _, by, _, _ = EntityCreator.createBtnRect(vw, vh)
  local maxDropH = by - 4 - dropTop
  if maxDropH < EntityCreator.DROP_H then return nil end
  return x + PAD, dropTop, w - PAD * 2, maxDropH, scrollOffset or 0
end

-- The dropdown entry (1-based, into the field's list) under (mx,my), or nil.
function EntityCreator.dropEntryAt(vw, vh, d, mx, my, rowIdx, scrollOffset)
  local dx, dy, dw, dh = EntityCreator.dropRect(vw, vh, d, rowIdx, scrollOffset)
  if not dx then return nil end
  if mx < dx or mx >= dx + dw or my < dy or my >= dy + dh then return nil end
  local row = math.floor((my - dy) / EntityCreator.DROP_H) + 1
  local maxVisible = math.floor(dh / EntityCreator.DROP_H)
  if row < 1 or row > maxVisible then return nil end
  return (scrollOffset or 0) + row
end

-- ---------------------------------------------------------------------------
-- Open / close

-- Types whose form carries a sprite SLOT: opening one auto-shows the picker
-- on the matching virtual catalog so a sprite can be dragged straight in.
local SLOT_PICKER_TAB = {
  npc = "person", battler = "person", mon = "monster",
}

function EntityCreator.hasSpriteSlot(entityType)
  return SLOT_PICKER_TAB[entityType] ~= nil or entityType == nil
end

-- Opens the picker on the virtual catalog tab id (`"person" | "monster"`),
-- hiding the selector: both want the sideRect column next to the inventory.
local function showPickerFor(ui, which)
  local Picker = require("mods.mapamap.components.picker")
  ui.showPicker = true
  ui.pickerDropOpen = false
  ui.pickerScroll = 1
  ui.pickerTilesetScroll = 1
  if which == "monster" then
    ui.pickerTileset = Picker.SPEC_MONSTER
  else
    ui.pickerTileset = Picker.SPEC_PERSON
  end
end

function EntityCreator.open(ui, session, entityType)
  local hadSlot = EntityCreator.hasSpriteSlot(entityType)
  -- The picker replaces the selector in the sideRect column while a sprite
  -- needs dragging; remember what we changed so close() can restore it.
  local hidSelector = hadSlot and ui.showEntitySelector or false
  local openedPicker = hadSlot and not ui.showPicker or false
  ui.showInventory = true
  ui.showEntitySelector = not hidSelector
  ui.details = nil
  ui.encEditor = nil
  if hadSlot then
    showPickerFor(ui, SLOT_PICKER_TAB[entityType])
  end
  ui.entityCreator = {
    session = session,
    entityType = entityType,
    fields = EntityCreator.build(session, entityType),
    index = 1,
    editing = nil,
    dropdown = nil,
    error = nil,
    hidSelector = hidSelector,
    openedPicker = openedPicker,
  }
  return ui.entityCreator
end

-- Restores the panels the form auto-swapped (selector hidden / picker shown)
-- when the form was opened on a sprite-slot type.
local function restorePanels(d, ui)
  if d.hidSelector then ui.showEntitySelector = true end
  if d.openedPicker then ui.showPicker = false end
end

-- Closes the form without creating anything.
function EntityCreator.close(ui)
  local d = ui.entityCreator
  if d then restorePanels(d, ui) end
  ui.entityCreator = nil
end

-- ---------------------------------------------------------------------------
-- Tool building: turns the form into a hotbar placement item.

function EntityCreator.toolItem(session, d)
  local vals = {}
  for _, f in ipairs(d.fields or {}) do vals[f.key] = f.value end
  local data = session and session.data or {}
  local et = d.entityType

  -- The sprite-slot value shared by npc / battler / mon.
  local function spriteOrError()
    if not (vals.sprite and data.sprites and data.sprites[vals.sprite]) then
      return nil, "drag a sprite into the slot"
    end
    return vals.sprite
  end
  -- Movement/range from the choice rows; an out-of-vocabulary range falls
  -- back to the vocabulary's first entry (should not happen through the UI).
  local movement = (vals.movement == "WALK") and "WALK" or "STAY"
  local range = nil
  for _, c in ipairs(rangeChoicesFor(movement)) do
    if c.id == vals.range then range = c.id break end
  end
  if not range then range = rangeChoicesFor(movement)[1].id end
  local dialog = (type(vals.text) == "string" and vals.text ~= "") and vals.text or nil

  if et == "npc" then
    local sprite, err = spriteOrError()
    if not sprite then return nil, err end
    return { kind = "entity", entityType = "object",
             create = { objectType = "npc", sprite = sprite,
                        movement = movement, range = range,
                        text = dialog,
                        label = (vals.label and vals.label ~= "")
                          and vals.label or nil } }
  elseif et == "item" then
    if not (vals.item and data.items and data.items[vals.item]) then
      return nil, "pick an item"
    end
    return { kind = "item", id = vals.item }
  elseif et == "battler" then
    local tdef = vals.trainerClass and data.trainers
      and data.trainers[vals.trainerClass]
    if not tdef then return nil, "pick a trainer class" end
    local maxParty = math.max(1, #(tdef.parties or {}))
    local sprite, err = spriteOrError()
    if not sprite then return nil, err end
    return { kind = "entity", entityType = "object",
             create = { objectType = "trainer",
                        trainerClass = vals.trainerClass,
                        trainerParty = math.max(1,
                          math.min(tonumber(vals.trainerParty) or 1, maxParty)),
                        movement = movement, range = range,
                        text = dialog, sprite = sprite } }
  elseif et == "mon" then
    if not (vals.pokemon and data.pokemon and data.pokemon[vals.pokemon]) then
      return nil, "pick a species"
    end
    local sprite, err = spriteOrError()
    if not sprite then return nil, err end
    return { kind = "entity", entityType = "object",
             create = { objectType = "mon", pokemon = vals.pokemon,
                        level = math.max(1, math.min(tonumber(vals.level) or 5, 100)),
                        movement = movement, range = range,
                        text = dialog, sprite = sprite } }
  elseif et == "sign" then
    return { kind = "entity", entityType = "sign",
             create = { text = (vals.text and vals.text ~= "") and vals.text
                        or "...",
                        label = vals.label or "" } }
  elseif et == "warp" then
    if not (vals.destMap and data.maps and data.maps[vals.destMap]) then
      return nil, "pick a destination map"
    end
    return { kind = "entity", entityType = "warp",
             create = { destMap = vals.destMap,
                        destWarp = math.max(0, tonumber(vals.destWarp) or 0) } }
  end
  return nil, "unknown entity type"
end

-- Validates + commits: builds the tool item, arms the selected hotbar slot
-- with it and files a copy in the inventory's Entities tab so the configured
-- tool stays available after leaving this map.  Returns true when the form
-- produced a valid tool (the form closes); on a validation failure the form
-- stays open with the reason.
function EntityCreator.commit(ui, session)
  local d = ui.entityCreator
  if not d then return false end
  local item, err = EntityCreator.toolItem(session, d)
  if not item then
    d.error = err
    return false
  end
  ui.hotbar[ui.selected] = item
  Hotbar.apply(ui, session)
  Inventory.add(ui, Common.deepCopy(item))
  restorePanels(d, ui)
  ui.entityCreator = nil
  return true
end

-- Drag-drop target: a sprite/item drag released over the form fills the
-- matching field.  Accepts { kind = "sprite" } (People cells), mon tools from
-- Monsters (their sprite seeds the slot AND the species), and item-ball tools
-- / plain items (the item field).  Returns true when the drop was consumed.
function EntityCreator.acceptDrop(ui, session, mx, my, dragItem)
  local d = ui.entityCreator
  if not d or not dragItem then return false end
  local vw, vh = love.graphics.getDimensions()
  if not Panel.over(EntityCreator.rect, vw, vh, mx, my) then return false end
  session = session or d.session
  local field
  if dragItem.kind == "sprite" then
    -- A person sheet fills any slot.
    field = EntityCreator.slotAt(ui, vw, vh, mx, my)
    if field then
      field.value = dragItem.id
    end
    return true -- consumed even off-slot: a stray drop must not reach the world
  elseif dragItem.kind == "item"
      or (dragItem.kind == "entity" and dragItem.create
          and dragItem.create.objectType == "itemball") then
    -- An item tool/plain item fills the Item dropdown on the item-ball form.
    local id = dragItem.kind == "item" and dragItem.id or dragItem.create.item
    for _, f in ipairs(d.fields) do
      if f.key == "item" then
        if session.data.items[id] then f.value = id end
        return true
      end
    end
    return true
  elseif dragItem.kind == "entity" and dragItem.entityType == "object" then
    -- Monster/person tools dropped on a slot seed it; a mon tool also
    -- carries its own species, which a mon form adopts wholesale.
    field = EntityCreator.slotAt(ui, vw, vh, mx, my)
    if field then
      local create = dragItem.create or {}
      if create.sprite and session.data.sprites[create.sprite] then
        field.value = create.sprite
      end
      if create.pokemon then
        for _, f in ipairs(d.fields) do
          if f.key == "pokemon"
              and session.data.pokemon[create.pokemon] then
            f.value = create.pokemon
          end
        end
      end
      return true
    end
  end
  return false
end

-- ---------------------------------------------------------------------------
-- Mouse

-- Handles a click while the form is open.  Returns true only when the click
-- landed inside the panel (so outside clicks fall through to the world and
-- the other panels).
function EntityCreator.mousepressed(ui, session, mx, my, button)
  local d = ui.entityCreator
  if not d then return false end
  local vw, vh = love.graphics.getDimensions()
  if not Panel.over(EntityCreator.rect, vw, vh, mx, my) then return false end

  -- Open dropdown: an entry click selects it; any other click just closes.
  if d.dropdown then
    local f = d.fields[d.index]
    local idx = EntityCreator.dropEntryAt(vw, vh, d, mx, my, d.index,
      d.dropdown.scroll)
    if idx then
      local list = EntityCreator.listFor(session, f.list)
      if list[idx] then f.value = list[idx] end
    end
    d.dropdown = nil
    return true
  end

  -- CREATE button.
  if button == 1 and EntityCreator.createBtnHit(vw, vh, mx, my) then
    EntityCreator.commit(ui, session)
    return true
  end

  -- Field rows: a click selects; dropdown fields pop their list open; slot
  -- fields clear on RMB, fill from a hotbar-held sprite on LMB, and grab
  -- their sprite onto the hotbar when clicked empty-handed (mirroring the
  -- Brush Maker's slots).  Text/number editing starts with Enter.
  local idx = EntityCreator.hit(vw, vh, mx, my, d)
  if idx and d.fields and idx <= #d.fields then
    d.index = idx
    d.error = nil
    local f = d.fields[idx]
    if f.type == "dropdown" and button == 1 then
      d.dropdown = { scroll = 0, filter = "" }
    elseif f.type == "slot" then
      local held = Hotbar.selected(ui)
      if button == 2 then
        f.value = nil
      elseif held and held.kind == "sprite"
          and session.data.sprites[held.id] then
        f.value = held.id
      elseif f.value then
        ui.hotbar[ui.selected] = { kind = "sprite", id = f.value }
        Hotbar.apply(ui, session)
      end
    end
  end
  return true
end

-- Wheel over the form: scroll the open dropdown list.
function EntityCreator.scroll(ui, dy)
  local d = ui.entityCreator
  if not d or not d.dropdown then return end
  local session = d.session
  local f = d.fields and d.fields[d.index]
  if not f then return end
  local list = EntityCreator.listFor(session, f.list)
  if #list == 0 then return end
  local vw, vh = love.graphics.getDimensions()
  local dx, _, _, dh = EntityCreator.dropRect(vw, vh, d, d.index,
    d.dropdown.scroll)
  if not dx then return end
  local maxVisible = math.floor(dh / EntityCreator.DROP_H)
  local maxScroll = math.max(0, #list - maxVisible)
  d.dropdown.scroll = math.max(0, math.min(d.dropdown.scroll + dy, maxScroll))
end

-- ---------------------------------------------------------------------------
-- Keyboard.  Returns true when consumed (the form owns the keyboard while
-- open, like Details).

function EntityCreator.key(ui, session, key)
  local d = ui.entityCreator
  if not d then return false end

  -- Dropdown navigation / filtering.
  if d.dropdown then
    local f = d.fields[d.index]
    local list = EntityCreator.listFor(session, f.list)
    if key == "up" then
      d.dropdown.scroll = math.max(0, d.dropdown.scroll - 1)
    elseif key == "down" then
      local vw, vh = love.graphics.getDimensions()
      local dx, _, _, dh = EntityCreator.dropRect(vw, vh, d, d.index,
        d.dropdown.scroll)
      local maxVisible = dh and math.floor(dh / EntityCreator.DROP_H) or 8
      local maxScroll = math.max(0, #list - maxVisible)
      d.dropdown.scroll = math.min(d.dropdown.scroll + 1, maxScroll)
    elseif key == "return" or key == "kpenter" then
      local pick = list[(d.dropdown.scroll or 0) + 1]
      if pick then f.value = pick end
      d.dropdown = nil
    elseif key == "escape" then
      d.dropdown = nil
    elseif #key == 1 then
      d.dropdown.filter = (d.dropdown.filter or "") .. key:upper()
      local matches = {}
      for _, s in ipairs(list) do
        if s:find(d.dropdown.filter, 1, true) then matches[#matches + 1] = s end
      end
      if #matches == 1 then
        f.value = matches[1]
        d.dropdown = nil
      end
    end
    return true
  end

  -- Text / number editing.
  if d.editing then
    local f = d.fields[d.editing.fieldIdx]
    if key == "return" or key == "kpenter" then
      if f then
        if f.type == "number" then
          f.value = tostring(math.max(0, tonumber(d.editing.buf) or 0))
        else
          f.value = d.editing.buf
        end
      end
      d.editing = nil
    elseif key == "backspace" then
      d.editing.buf = d.editing.buf:sub(1, #d.editing.buf - 1)
    elseif key == "escape" then
      d.editing = nil
    elseif #key == 1 then
      if f and f.type == "number" then
        if key >= "0" and key <= "9" and #d.editing.buf < 3 then
          d.editing.buf = d.editing.buf .. key
        end
      else
        d.editing.buf = d.editing.buf .. key
      end
    end
    return true
  end

  -- Row navigation; the CREATE button is the virtual last row.
  local lastRow = #(d.fields or {}) + 1
  if key == "up" then
    d.index = math.max(1, d.index - 1)
    d.error = nil
  elseif key == "down" then
    d.index = math.min(lastRow, d.index + 1)
    d.error = nil
  elseif key == "left" or key == "right" then
    local f = d.fields and d.fields[d.index]
    if f and f.type == "number" then
      local delta = (key == "right") and 1 or -1
      f.value = tostring(math.max(0, (tonumber(f.value) or 0) + delta))
    elseif f and f.type == "choice" then
      EntityCreator.cycleChoice(d, f, (key == "right") and 1 or -1)
    end
  elseif key == "return" or key == "kpenter" then
    if d.index > #(d.fields or {}) then
      EntityCreator.commit(ui, session)
    else
      local f = d.fields[d.index]
      if f.type == "dropdown" then
        d.dropdown = { scroll = 0, filter = "" }
      elseif f.type == "choice" then
        EntityCreator.cycleChoice(d, f, 1)
      elseif f.type == "slot" then
        -- Enter opens the picker so a sprite can be dragged in (the form
        -- stays open one column further right).
        ui.showEntitySelector = false
        showPickerFor(ui, SLOT_PICKER_TAB[d.entityType])
      else
        d.editing = { fieldIdx = d.index, buf = f.value or "" }
      end
    end
  elseif key == "escape" then
    EntityCreator.close(ui)
  end
  return true
end

-- ---------------------------------------------------------------------------
-- Draw

function EntityCreator.draw(session, state, vw, vh, font)
  local x, y, w, h = EntityCreator.rect(vw, vh)
  Panel.drawBg(x, y, w, h)
  Panel.drawTitle(font, EntityCreator.title(state), x, y)

  local mx, my = love.mouse.getPosition()
  for i, f in ipairs(state.fields or {}) do
    local ry = rowTop(state.fields or {}, y, i)
    Text.label(font, Panel.fitText(font, f.label .. ":", w / 2 - 6, 2),
      x + PAD, ry + (f.type == "slot" and 2 or 3), 2,
      { bg = Panel.CHIP_ROW, padX = 2, padY = 1 })

    if f.type == "slot" then
      -- Sprite drag slot: cell bg + thumbnail, yellow border while empty
      -- (like the Brush Maker's required center), hover ring.
      local sx, sy, ss = spriteSlotRect(state, vw, vh, i)
      love.graphics.setColor(Panel.COLOR_CELL_BG[1], Panel.COLOR_CELL_BG[2],
        Panel.COLOR_CELL_BG[3], Panel.COLOR_CELL_BG[4])
      love.graphics.rectangle("fill", sx, sy, ss, ss)
      if f.value then
        Item.draw(session, { kind = "sprite", id = f.value }, sx + 2, sy + 2,
          ss - 4)
      else
        Text.label(font, "drag a sprite in", sx + 4, sy + ss - 12, 1,
          { bg = Panel.CHIP_HINT, padX = 1, padY = 0 })
      end
      if not f.value then
        love.graphics.setColor(1, 0.85, 0.2, 0.9)
        love.graphics.rectangle("line", sx, sy, ss, ss)
      end
      if mx >= sx and mx < sx + ss and my >= sy and my < sy + ss then
        Panel.drawCellHover(sx, sy, ss)
      end
      if state.index == i and not (state.dropdown and state.index == i) then
        Panel.drawSel(x + 2, ry - 3, w - 4, strideOf(f))
      end
      Panel.resetColor()
    else
      local vx, vy, vw2 = valueAreaRect(state, vw, vh, i)
      if f.type == "dropdown" then
        Panel.renderDropdownButton(font, f.value, vx, vy, vw2, ROW_H,
          mx, my, state.dropdown and state.index == i)
        if state.index == i and not (state.dropdown and state.index == i) then
          Panel.drawSel(x + 2, ry - 3, w - 4, ROW_H)
        end
      elseif f.type == "choice" then
        -- Choice rows show the friendly label wrapped in cycle chevrons.
        local value = "< " .. EntityCreator.choiceLabel(f) .. " >"
        if state.editing and state.editing.fieldIdx == i then
          value = state.editing.buf .. "_"
        end
        Text.label(font, Panel.fitText(font, value, vw2 - 8, 2), vx + 4,
          vy + 3, 2, { bg = Panel.CHIP_VALUE, padX = 2, padY = 1 })
        if state.index == i and not (state.dropdown and state.index == i) then
          Panel.drawSel(x + 2, ry - 3, w - 4, ROW_H)
        end
      else
        local value = f.value or ""
        if state.editing and state.editing.fieldIdx == i then
          value = state.editing.buf .. "_"
          Text.label(font, Panel.fitText(font, value, vw2 - 8, 2), vx + 4,
            vy + 3, 2, { bg = Panel.CHIP_EDIT, padX = 2, padY = 1 })
        else
          Text.label(font, Panel.fitText(font, value, vw2 - 8, 2), vx + 4,
            vy + 3, 2, { bg = Panel.CHIP_VALUE, padX = 2, padY = 1 })
        end
        if state.index == i and not (state.dropdown and state.index == i) then
          Panel.drawSel(x + 2, ry - 3, w - 4, ROW_H)
        end
      end
    end
  end

  -- CREATE button (also the virtual keyboard row #fields+1).
  do
    local bx, by, bw, bh = EntityCreator.createBtnRect(vw, vh)
    local hovered = mx >= bx and mx < bx + bw and my >= by and my < by + bh
    love.graphics.setColor(0.16, 0.35, 0.18, 0.95)
    love.graphics.rectangle("fill", bx, by, bw, bh)
    if hovered or state.index > #(state.fields or {}) then
      love.graphics.setColor(0.3, 1, 0.4, 0.95)
    else
      love.graphics.setColor(0.5, 0.8, 0.5, 0.6)
    end
    love.graphics.rectangle("line", bx, by, bw, bh)
    Text.label(font, "CREATE", bx + 4, by + 3, 2,
      { bg = Panel.CHIP_TITLE, padX = 2, padY = 1 })
    Panel.resetColor()
  end

  -- Open dropdown list (drawn over the rows).
  if state.dropdown then
    local di = state.index
    local f = state.fields and state.fields[di]
    if f then
      local dx, dy, dw, dh = EntityCreator.dropRect(vw, vh, state, di,
        state.dropdown.scroll)
      if dx then
        local list = EntityCreator.listFor(session, f.list)
        local maxVisible = math.floor(dh / EntityCreator.DROP_H)
        local hoverEntry = EntityCreator.dropEntryAt(vw, vh, state, mx, my, di,
          state.dropdown.scroll)
        local entries = {}
        for k = 1, maxVisible do
          local id = list[(state.dropdown.scroll or 0) + k]
          if not id then break end
          entries[k] = { label = id }
        end
        local selIdx = nil
        for k, e in ipairs(entries) do
          if e.label == f.value then selIdx = (state.dropdown.scroll or 0) + k; break end
        end
        Panel.renderDropdownList(font, dx, dy, dw, dh, entries,
          1, maxVisible, selIdx, hoverEntry, EntityCreator.DROP_H)
      end
    end
  end

  local hint
  if state.dropdown then
    hint = "Up/Down: scroll  Enter: select  Esc: close  type: filter"
  elseif state.editing then
    hint = "Type a value  Enter: ok  Esc: cancel"
  elseif state.error then
    hint = "!! " .. state.error
  else
    hint = "L/R: +- / choices  drag a sprite into the slot  CREATE: arm hotbar"
  end
  Panel.drawHint(font, hint, x, y, w, h)
  Panel.resetColor()
end

return EntityCreator
