-- Entity Creator panel: the second half of the entity creation workflow.
--
-- A form panel (docked one slot right of the Entity Selector) holding ONLY
-- the fields the chosen entity type requires from the user:
--   npc      -> name, movement (stands/walks), facing-or-roam range, dialog
--               text, sprite SLOT (drag one in from the picker)
--   item     -> item id (dropdown)
--   battler  -> trainer class (dropdown), TEAM row (opens the Party Editor
--               on that class's shared roster), sprite SLOT
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
local Dropdown = require("mods.mapamap.components.dropdown")

local EntityCreator = {}

EntityCreator.DROP_H = Dropdown.H

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
  -- Prize list: NONE first so "no recompense" is the explicit default.
  if listKey == "items_none" then
    local out = { "NONE" }
    for _, id in ipairs(sortedKeys(data.items)) do out[#out + 1] = id end
    return out
  end
  if listKey == "moves" then return sortedKeys(data.moves) end
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
    add("text", "Dialog", "", "action")
    add("prizeItem", "Gift item", "NONE", "dropdown", "items_none")
    add("sprite", "Sprite", nil, "slot")
  elseif entityType == "item" then
    add("item", "Item", firstOf(session, "items"), "dropdown", "items")
  elseif entityType == "hiddenitem" then
    add("item", "Item", firstOf(session, "items"), "dropdown", "items")
  elseif entityType == "battler" then
    add("trainerClass", "Class", firstOf(session, "trainers"),
      "dropdown", "trainers")
    add("team", "Team", "", "action")
    add("pretext", "Before battle", "", "action")
    add("wintext", "After win", "", "action")
    add("prizeItem", "Prize item", "NONE", "dropdown", "items_none")
    add("sight", "Sight", "0", "number")  -- clamped to MAX_SIGHT by objects.lua
    add("sprite", "Sprite", nil, "slot")
  elseif entityType == "mon" then
    add("pokemon", "Species", firstOf(session, "species"), "dropdown", "species")
    add("level", "Level", "5", "number")
    add("sprite", "Sprite", nil, "slot")
  elseif entityType == "shop" then
    add("sprite", "Sprite", nil, "slot")
    add("addItem", "Add item", firstOf(session, "items"), "dropdown", "items")
    add("shopItems", "Items (0)", "", "action")
  elseif entityType == "sign" then
    add("label", "Label", "New Sign", "text")
    add("text", "Text", "...", "action")
  elseif entityType == "warp" then
    add("destMap", "Dest map", session.mapId or "", "dropdown", "maps")
    add("destWarp", "Warp #", "0", "number")
    add("newmap", "New map", "", "action")
  elseif entityType == "pc" then
    add("label", "Name", "PC", "text")
    addChoice("movement", "Walks", "STAY", MOVEMENT_CHOICES)
    addChoice("range", "Facing", "DOWN", rangeChoicesFor("STAY"))
    add("text", "Dialog", "", "action")
    add("sprite", "Sprite", nil, "slot")
  elseif entityType == "healing" then
    add("sprite", "Sprite", nil, "slot")
  elseif entityType == "boulder" then
    -- no fields: fixed boulder sheet, strength-pushable
  elseif entityType == "headbutt" then
    -- no fields: gen-2 tree-tile block resolved at paint time
  elseif entityType == "blocker" then
    add("pokemon", "Species", firstOf(session, "species"), "dropdown", "species")
    add("level", "Level", "30", "number")
  elseif entityType == "berrytree" then
    add("berryItem", "Berry", firstOf(session, "items"), "dropdown", "items")
    add("berryCount", "Count", "1", "number")
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
    if t.key == (d and d.entityType) then
      return (d.editEntity and "EDIT " or "NEW ") .. t.label
    end
  end
  return (d.editEntity and "EDIT ENTITY" or "NEW ENTITY")
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
function EntityCreator.dropRect(vw, vh, d, rowIdx)
  local x, y, w, h = EntityCreator.rect(vw, vh)
  local ry = rowTop(d.fields or {}, y, rowIdx)
  local dropTop = ry + ROW_H + 6
  local _, by = EntityCreator.createBtnRect(vw, vh)
  local maxDropH = by - 4 - dropTop
  if maxDropH < EntityCreator.DROP_H then return nil end
  return x + PAD, dropTop, w - PAD * 2, maxDropH
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
  healing = "person", pc = "person", shop = "person",
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
    shopItems = (entityType == "shop") and {} or nil,
  }
  return ui.entityCreator
end

-- Restores the panels the form auto-swapped (selector hidden / picker shown)
-- when the form was opened on a sprite-slot type.
local function restorePanels(d, ui)
  if d.hidSelector then ui.showEntitySelector = true end
  if d.openedPicker then ui.showPicker = false end
end

-- ---------------------------------------------------------------------------
-- Edit mode: reopen a placed entity in the creator form (Details -> EDIT).

-- The creator form kind that edits a placed entity.  Object flavors are told
-- apart by their placement markers (object_type / pushable / blocker /
-- berryItem / isTrainer / pokemon).
function EntityCreator.editKindFor(session, entity, entityType)
  if entityType == "warp" then return "warp" end
  if entityType == "sign" then return "sign" end
  if not entity then return nil end
  if entity.object_type == "item" then
    return entity.hidden and "hiddenitem" or "item"
  end
  if entity.pushable then return "boulder" end
  if entity.blocker then return "blocker" end
  if entity.healing then return "healing" end
  if entity.berryItem then return "berrytree" end
  if entity.isTrainer then return "battler" end
  if entity.pokemon then return "mon" end
  if entity.mart or entity.objectType == "shop" then return "shop" end
  return "npc"
end

-- Seeds an open form's fields from a live entity's current values.  Only
-- keys the form actually carries are written, so form-shape changes never
-- leak stale rows.
function EntityCreator.prefillFrom(session, d, entity)
  if not (d and entity) then return d end
  local b = entity.blocker
  local src = {
    label = entity.label,
    movement = entity.movement,
    range = entity.range,
    text = entity.text,
    pretext = entity.text,
    sprite = entity.sprite,
    pokemon = entity.pokemon or (b and b.species),
    level = entity.level or (b and b.level),
    item = entity.item,
    berryItem = entity.berryItem,
    berryCount = entity.berryCount,
    trainerClass = entity.trainerClass,
    wintext = entity.winText,
    prizeItem = entity.prizeItem or "NONE",
    sight = entity.sight or 0,
    destMap = entity.destMap,
    destWarp = entity.destWarp,
    items = type(entity.items) == "table"
      and table.concat(entity.items, ", ") or nil,
  }
  for _, f in ipairs(d.fields) do
    local v = src[f.key]
    if v ~= nil then
      f.value = (type(v) == "number") and tostring(v) or v
    end
  end
  return d
end

-- Opens the creator prefilled with `target`'s live values ({ entity,
-- entityType }); CREATE writes the form back to that same entity instead of
-- arming a placement tool.
function EntityCreator.openForEdit(ui, session, target)
  local t = target or {}
  if not t.entity then return nil end
  local kind = EntityCreator.editKindFor(session, t.entity, t.entityType)
  if not kind then return nil end
  local d = EntityCreator.open(ui, session, kind)
  if not d then return nil end
  -- Seed the shop items list from the entity's item array.
  if kind == "shop" and type(t.entity.items) == "table" then
    d.shopItems = {}
    for _, id in ipairs(t.entity.items) do
      d.shopItems[#d.shopItems + 1] = id
    end
  end
  EntityCreator.prefillFrom(session, d, t.entity)
  -- Update the shopItems row label to reflect seeded count.
  if d.shopItems then
    for _, f in ipairs(d.fields or {}) do
      if f.key == "shopItems" then
        f.label = "Items (" .. #d.shopItems .. ")"
      end
    end
  end
  d.editEntity = { entity = t.entity, entityType = t.entityType }
  return d
end

-- Writes one edited form value back to a live object through the session's
-- validated setters.  Returns true when written.
local function applyObjectField(session, o, key, v)
  if key == "label" then
    return session:setObjectProperty(o, "name", v)
  elseif key == "pretext" then
    -- The battler/healing forms split dialog across named rows; they land
    -- on the object's single talk text.
    return session:setObjectProperty(o, "text", v or "")
  elseif key == "wintext" then
    return session:setObjectProperty(o, "winText", v or "")
  elseif o.blocker and (key == "pokemon" or key == "level") then
    -- Sleeping blockers keep their battle spec inside the blocker table;
    -- the NPC-level pokemon/level fields do not exist for them.
    if key == "pokemon" then
      if not (v and session.data.pokemon and session.data.pokemon[v]) then
        return false
      end
      o.blocker.species = v
    else
      o.blocker.level = math.max(1, math.min(tonumber(v) or 30, 100))
    end
    session.mapChanged = true
    return true
  elseif o.mart and key == "items" then
    -- Shop item list: comma-separated item IDs on the form, array on the obj.
    if type(v) ~= "string" then return false end
    local items = {}
    if v ~= "" then
      for item in v:gmatch("[^,]+") do
        local id = item:match("^%s*(.-)%s*$")
        if id ~= "" then
          if session.data.items and session.data.items[id] then
            items[#items + 1] = id
          else
            return false
          end
        end
      end
    end
    if #items == 0 then return false end
    o.items = items
    session.mapChanged = true
    return true
  end
  return session:setObjectProperty(o, key, v)
end

-- EDIT-mode commit: writes every form field back to the live entity the form
-- was opened for.  All writable fields are applied even when one fails; the
-- first failure is reported so the form can stay open with a reason.
function EntityCreator.applyEdit(ui, session, d)
  local ee = d.editEntity
  if not (ee and ee.entity) then return false, "nothing to edit" end
  local ent, et = ee.entity, ee.entityType
  local failKey
  for _, f in ipairs(d.fields) do
    local v = f.value
    local ok
    -- Shop items are managed as a list; skip the form fields that represent
    -- the picker and display rows â€” they're written from d.shopItems below.
    if f.key == "addItem" or f.key == "shopItems" then
      ok = true
    elseif et == "object" then
      ok = applyObjectField(session, ent, f.key, v)
    elseif et == "warp" then
      if f.key == "destMap" then
        ok = (v ~= "" and session.data.maps[v])
          and session:setWarpDest(ent, v) or false
      elseif f.key == "destWarp" then
        ok = session:setWarpDest(ent, nil, math.max(0, tonumber(v) or 0))
      elseif f.key == "label" then
        ok = session:setWarpLabel(ent, v)
      else
        ok = true
      end
    elseif et == "sign" then
      if f.key == "label" then
        ok = session:setSignLabel(ent, v)
      elseif f.key == "text" then
        ent.text = (v ~= "" and v) or "..."
        session.mapChanged = true
        ok = true
      else
        ok = true
      end
    else
      ok = true
    end
    if not ok and not failKey then failKey = f.label end
  end
  -- Write back the shop items list from the accumulated array.
  if et == "object" and d.shopItems and ent.mart then
    local items = {}
    for _, id in ipairs(d.shopItems) do
      if session.data.items and session.data.items[id] then
        items[#items + 1] = id
      end
    end
    if #items > 0 then
      ent.items = items
      session.mapChanged = true
    end
  end
  if failKey then return false, failKey:lower() .. ": invalid value" end
  return true
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
                          and vals.label or nil,
                        prizeItem = (type(vals.prizeItem) == "string"
                          and vals.prizeItem ~= "NONE"
                          and data.items and data.items[vals.prizeItem])
                          and vals.prizeItem or nil } }
  elseif et == "pc" then
    local sprite, err = spriteOrError()
    if not sprite then return nil, err end
    return { kind = "entity", entityType = "object",
             create = { objectType = "npc", sprite = sprite,
                        movement = movement, range = range,
                        text = dialog,
                        label = vals.label or "PC" } }
  elseif et == "item" then
    if not (vals.item and data.items and data.items[vals.item]) then
      return nil, "pick an item"
    end
    return { kind = "item", id = vals.item }
  elseif et == "hiddenitem" then
    if not (vals.item and data.items and data.items[vals.item]) then
      return nil, "pick an item"
    end
    -- An invisible item ball: the engine hides obj.hidden placements and
    -- the pickup ledger (itemsTaken) keeps it found.
    return { kind = "entity", entityType = "object",
             create = { objectType = "itemball", item = vals.item,
                        hidden = true } }
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
                        trainerParty = 1,
                        movement = movement, range = range,
                        sprite = sprite,
                        text = (type(vals.pretext) == "string"
                          and vals.pretext ~= "") and vals.pretext or nil,
                         winText = (type(vals.wintext) == "string"
                           and vals.wintext ~= "") and vals.wintext or nil,
                         prizeItem = (type(vals.prizeItem) == "string"
                           and vals.prizeItem ~= "NONE"
                           and data.items and data.items[vals.prizeItem])
                           and vals.prizeItem or nil,
sight = math.max(0,
                            math.min(math.floor(tonumber(vals.sight) or 0),
                              Objects.MAX_SIGHT)) } }
  elseif et == "healing" then
    local sprite, err = spriteOrError()
    if not sprite then return nil, err end
    return { kind = "entity", entityType = "object",
             create = { objectType = "npc",
                        healing = true,
                        sprite = sprite,
                        movement = movement, range = range,
                        label = "Healer" } }
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
  elseif et == "shop" then
    local sprite, err = spriteOrError()
    if not sprite then return nil, err end
    -- Build from the accumulated list; fall back to comma-separated text for
    -- legacy / prefillFrom compatibility.
    local shopItems = {}
    if d.shopItems and #d.shopItems > 0 then
      for _, id in ipairs(d.shopItems) do
        if data.items and data.items[id] then
          shopItems[#shopItems + 1] = id
        end
      end
    elseif type(vals.items) == "string" and vals.items ~= "" then
      for item in vals.items:gmatch("[^,]+") do
        local id = item:match("^%s*(.-)%s*$")
        if id ~= "" then
          if data.items and data.items[id] then
            shopItems[#shopItems + 1] = id
          else
            return nil, "unknown item: " .. id
          end
        end
      end
    end
    if #shopItems == 0 then return nil, "add at least one item" end
    return { kind = "entity", entityType = "object",
             create = { objectType = "shop", sprite = sprite,
                        movement = movement, range = range,
                        items = shopItems } }
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
  elseif et == "boulder" then
    return { kind = "entity", entityType = "object",
             create = { objectType = "boulder" } }
  elseif et == "headbutt" then
    -- Paint tool, not an entity: the gen-2 tree-tile block resolves from the
    -- edited tileset at paint time (Paint.headbuttBlockFor).
    return { kind = "headbutt" }
  elseif et == "blocker" then
    if not (vals.pokemon and data.pokemon and data.pokemon[vals.pokemon]) then
      return nil, "pick a species"
    end
    return { kind = "entity", entityType = "object",
             create = { objectType = "blocker",
                        pokemon = vals.pokemon,
                        level = math.max(1,
                          math.min(tonumber(vals.level) or 30, 100)) } }
  elseif et == "berrytree" then
    if not (vals.berryItem and data.items and data.items[vals.berryItem]) then
      return nil, "pick a berry"
    end
    return { kind = "entity", entityType = "object",
             create = { objectType = "berrytree",
                        berryItem = vals.berryItem,
                        berryCount = math.max(1,
                          tonumber(vals.berryCount) or 1) } }
  end
  return nil, "unknown entity type"
end

-- Validates + commits: builds the tool item, arms the selected hotbar slot
-- with it and files a copy in the inventory's Entities tab so the configured
-- tool stays available after leaving this map.  In EDIT mode (opened from the
-- Details panel) nothing is armed: the form's values are written back to the
-- live entity instead.  Returns true when the form produced a valid tool /
-- applied its edits (the form closes); on a validation failure the form
-- stays open with the reason.
function EntityCreator.commit(ui, session)
  local d = ui.entityCreator
  if not d then return false end
  if d.editEntity then
    local ok, err = EntityCreator.applyEdit(ui, session, d)
    if not ok then
      d.error = err
      return false
    end
    -- Like CREATE, editing ends with immediate world access: leave every
    -- panel that could swallow the next LMB closed.
    ui.showEntitySelector = false
    ui.showPicker = false
    ui.entityCreator = nil
    return true
  end
  local item, err = EntityCreator.toolItem(session, d)
  if not item then
    d.error = err
    return false
  end
  ui.hotbar[ui.selected] = item
  Hotbar.apply(ui, session)
  Inventory.add(ui, Common.deepCopy(item))
  -- On COMMIT the goal is immediate placement of the created tool: close the
  -- auto-swapped selector/picker instead of restoring them (a restored
  -- selector would eat the very click that should place the entity).
  ui.showEntitySelector = false
  ui.showPicker = false
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

-- Restores a previously-open creation form (same entity type, same typed
-- values) after the party editor borrowed the modal slot.  Values match by
-- field key, so form-shape changes never leak stale rows.
function EntityCreator.restoreDraft(ui, session, draft)
  if not draft then return nil end
  local d = EntityCreator.open(ui, session, draft.entityType)
  if not (d and draft.fields) then return d end
  for _, f in ipairs(d.fields) do
    for _, old in ipairs(draft.fields) do
      if old.key == f.key and old.value ~= nil then f.value = old.value end
    end
  end
  return d
end

-- NEW MAP action row (warp form): creates a brand-new map flush against the
-- edited grid on the first free edge and re-points the draft's destination
-- at it (warp # 0), so CREATE arms a warp leading to fresh space.  The new
-- map is laid out + persisted like any grid expansion, but the editor stays
-- on the current map (no adoption).
local function createNewDestMap(ui, session, d)
  local NewMap = require("mods.mapamap.domain.new_map")
  local newId = NewMap.createWarpDestination(session)
  if not newId then
    d.error = "no free edge for a new map"
    return true
  end
  for _, f in ipairs(d.fields or {}) do
    if f.key == "destMap" then f.value = newId end
    if f.key == "destWarp" then f.value = "0" end
  end
  d.error = nil
  d.status = "warp target: " .. tostring(newId)
  return true
end
-- Exposed for tests and keyboard/mouse dispatch.
EntityCreator.createNewDestMap = createNewDestMap

-- Opens the Party Editor on the battler form's selected class (shared roster,
-- party #1), parking the draft so closing the editor brings the form back.
local function openTeamEditor(ui, session, d)
  local class
  for _, f in ipairs(d.fields) do
    if f.key == "trainerClass" then class = f.value end
  end
  if not (class and session.data.trainers
          and session.data.trainers[class]) then
    d.error = "pick a trainer class first"
    return true
  end
  local Common = require("mods.mapamap.common")
  local PartyEditor = require("mods.mapamap.components.party_editor")
  local draft = { entityType = d.entityType,
                  fields = Common.deepCopy(d.fields) }
  ui.entityCreator = nil
  if PartyEditor.openShared(ui, session, class) then
    ui.partyEditor.returnCreator = { draft = draft }
  else
    -- Nothing editable: put the form back untouched.
    ui.entityCreator = d
  end
  return true
end

-- The creator fields that compose with the dialog editor: key -> title.
local DIALOG_TITLES = {
  text = "NPC DIALOG",
  pretext = "PRE-BATTLE TEXT",
  wintext = "AFTER-WIN TEXT",
  sign_text = "SIGN TEXT",
}

local function dialogTargetFor(entityType, key)
  if key == "text" and entityType == "sign" then return "sign_text" end
  if DIALOG_TITLES[key] then return key end
  return nil
end

-- Opens the Dialog Editor for a message field, parking the draft; DONE
-- restores the form with the composed text patched into the field.
local function openTextEditor(ui, session, d, fieldKey)
  local initial
  for _, f in ipairs(d.fields) do
    if f.key == fieldKey then initial = f.value or "" end
  end
  local Common = require("mods.mapamap.common")
  local DialogEditor = require("mods.mapamap.components.dialog_editor")
  local draft = { entityType = d.entityType,
                  fields = Common.deepCopy(d.fields) }
  ui.entityCreator = nil
  DialogEditor.open(ui, session, {
    title = DIALOG_TITLES[fieldKey] or "DIALOG",
    text = initial,
    returnCreator = { draft = draft, fieldKey = fieldKey },
  })
  return true
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
      if list[idx] then
        if f.key == "addItem" and d.shopItems then
          d.shopItems[#d.shopItems + 1] = list[idx]
          -- Update the shopItems row label to reflect count.
          for _, o in ipairs(d.fields or {}) do
            if o.key == "shopItems" then
              o.label = "Items (" .. #d.shopItems .. ")"
            end
          end
        else
          f.value = list[idx]
        end
      end
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
  -- Brush Maker's slots).  The TEAM action row opens the party editor.
  -- Text/number editing starts with Enter.
  local idx = EntityCreator.hit(vw, vh, mx, my, d)
  if idx and d.fields and idx <= #d.fields then
    d.index = idx
    d.error = nil
  d.status = nil
    local f = d.fields[idx]
    if f.type == "dropdown" and button == 1 then
      d.dropdown = { scroll = 0, filter = "" }
    elseif f.type == "action" and f.key == "shopItems" then
      if button == 2 and d.shopItems and #d.shopItems > 0 then
        table.remove(d.shopItems)
        for _, o in ipairs(d.fields or {}) do
          if o.key == "shopItems" then
            o.label = "Items (" .. #d.shopItems .. ")"
          end
        end
      end
    elseif f.type == "action" and button == 1 then
      if f.key == "team" then
        return openTeamEditor(ui, session, d)
      end
      if f.key == "newmap" then
        return createNewDestMap(ui, session, d)
      end
      return openTextEditor(ui, session, d, f.key)
    elseif f.key and dialogTargetFor(d.entityType, f.key) and button == 1 then
      return openTextEditor(ui, session, d,
        dialogTargetFor(d.entityType, f.key))
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
  local vw, vh = love.graphics.getDimensions()
  local _, _, _, dh = EntityCreator.dropRect(vw, vh, d, d.index)
  if not dh then return end
  d.dropdown.scroll =
    Dropdown.scrollBy(#list, d.dropdown.scroll, dy, dh)
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
      local _, _, _, dh = EntityCreator.dropRect(vw, vh, d, d.index)
      d.dropdown.scroll =
        Dropdown.scrollBy(#list, d.dropdown.scroll, 1, dh or Dropdown.H * 8)
    elseif key == "return" or key == "kpenter" then
      local pick = list[(d.dropdown.scroll or 0) + 1]
      if pick then f.value = pick end
      d.dropdown = nil
    elseif key == "escape" then
      d.dropdown = nil
    elseif #key == 1 then
      d.dropdown.filter = (d.dropdown.filter or "") .. key:upper()
      local pickIdx = Dropdown.uniqueMatch(list, d.dropdown.filter)
      if pickIdx then
        f.value = list[pickIdx]
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
  d.status = nil
  elseif key == "down" then
    d.index = math.min(lastRow, d.index + 1)
    d.error = nil
  d.status = nil
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
      elseif f.type == "action" then
        if f.key == "team" then
          return openTeamEditor(ui, session, d)
        end
        if f.key == "shopItems" then return true end
        if f.key == "newmap" then
          return createNewDestMap(ui, session, d)
        end
        return openTextEditor(ui, session, d, f.key)
      elseif f.key and dialogTargetFor(d.entityType, f.key) then
        return openTextEditor(ui, session, d,
          dialogTargetFor(d.entityType, f.key))
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
        local value = "" .. EntityCreator.choiceLabel(f) .. ""
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
        if f.key and dialogTargetFor(state.entityType, f.key) then
          -- Composable dialog fields show a one-line snippet.
          if #value > 0 then
            local firstLine = value:gsub("[\n\f].*$", "")
            value = firstLine .. ((#value > #firstLine) and " ..." or "")
          else
            value = "ENTER TO COMPOSE"
          end
        elseif f.type == "action" and f.key == "team" then
          -- The TEAM row names the class it will edit, live from the form.
          local cls
          for _, o in ipairs(state.fields or {}) do
            if o.key == "trainerClass" then cls = o.value end
          end
          value = "EDIT TEAM"
        elseif f.type == "action" and f.key == "shopItems" then
          if state.shopItems and #state.shopItems > 0 then
            value = table.concat(state.shopItems, ", ")
          else
            value = "RMB to remove | no items"
          end
        elseif f.type == "action" and f.key == "newmap" then
          -- Live feedback: once a fresh map was minted, the row names it.
          value = state.status and (state.status:match("warp target: (.+)$")
            or "+ NEW MAP") or "+ NEW MAP"
        elseif f.type == "action" then
          value = "SET"
        end
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
      local dx, dy, dw, dh = EntityCreator.dropRect(vw, vh, state, di)
      if dx then
        local list = EntityCreator.listFor(session, f.list)
        local hoverEntry = EntityCreator.dropEntryAt(vw, vh, state, mx, my,
          di, state.dropdown.scroll)
        -- Highlight the visible row matching the current value.
        local selIdx
        for k = 1, Dropdown.visibleCount(dh) do
          if list[(state.dropdown.scroll or 0) + k] == f.value then
            selIdx = (state.dropdown.scroll or 0) + k break
          end
        end
        Dropdown.draw(font, list, dx, dy, dw, dh, state.dropdown.scroll,
          selIdx, hoverEntry)
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
  elseif state.status then
    hint = state.status
  elseif state.editEntity then
    hint = "L/R: +- / choices  CREATE: write edits back to the entity"
  else
    hint = "L/R: +- / choices  drag a sprite into the slot  CREATE: arm hotbar"
  end
  Panel.drawHint(font, hint, x, y, w, h)
  Panel.resetColor()
end

return EntityCreator
