-- Details panel component: a modal editor for a single inventory item or warp.
--
-- Right-clicking an inventory cell (or a warp circle in the world) opens it.
-- It lists the target's editable fields as rows; the active row is navigated
-- with the keyboard (Up/Down move, Left/Right nudge numbers, Enter opens a
-- text edit buffer, Backspace deletes, Escape closes or cancels).  DELETE runs
-- the field's action (removes the warp / inventory item).
--
-- Geometry mirrors the inventory/picker panels: same-sized box sitting at the
-- inventory's right, drawn only while Input.details is open.

local Inventory = require("mods.mapamap.components.inventory")
local Panel = require("mods.mapamap.components.panel")
local Text = require("mods.mapamap.components.text")
local Objects = require("mods.mapamap.domain.objects")

local Details = {}

-- The panel is the inventory's equal-sized side panel (the picker's spot; the
-- picker is closed while details are open).
function Details.rect(vw, vh)
  return Inventory.sideRect(vw, vh)
end

-- True when a screen point is inside the details panel.
function Details.over(vw, vh, mx, my)
  return Panel.over(Details.rect, vw, vh, mx, my)
end

-- The field index whose row a screen point is over (mouse hover / click), or
-- nil.  Rows mirror the keyboard's field list.
function Details.hit(vw, vh, mx, my)
  local x, y, w, h = Details.rect(vw, vh)
  if mx < x or mx >= x + w or my < y or my >= y + h then return nil end
  local rowY = y + Panel.PAD + 20
  local n = math.floor((my - rowY) / (Panel.ROW_H + 6)) + 1
  if n < 1 then return nil end
  return n
end

-- The field list for a target.  `target` is
--   { warp = <def.warps entry> }    a live warp on the edited map
--   { item = <inventory cell> }     a stored block/sprite/item/blueprint
--   { object = <def.objects entry> } a live object on the edited map
-- Field rows are { key, label, value, type, choices } where type is
-- "readonly", "text", "number", "choice" or "action" (DELETE); choice rows
-- carry their {id,label} vocabulary.
function Details.build(session, target)
  local fields = {}
  local function add(key, label, value, kind, choices)
    fields[#fields + 1] = { key = key, label = label, value = value,
                            type = kind or "text", choices = choices }
  end
  if target and target.map then
    local def = target.map
    add("name", "Name", (def and def.name) or target.mapId or "", "text")
    add("id", "Map ID", target.mapId or "-", "readonly")
    add("size", "Size", (def and def.width and def.height)
      and (def.width .. "x" .. def.height) or "-", "readonly")
    add("encounters", "Encounters", "", "action")
  elseif target and target.entity then
    local et = target.entityType
    if et == "warp" then
      local w = target.entity
      add("pos", "Pos", (w.x ~= nil and w.y ~= nil) and (w.x .. "," .. w.y) or "-",
        "readonly")
      add("destMap", "Dest map", w.destMap or "?", "text")
      add("destWarp", "Warp #", tostring(w.destWarp or 0), "number")
      add("label", "Label", w.label or "", "text")
    elseif et == "object" then
      local o = target.entity
      add("type", "Type", (o.object_type or "OBJECT"):upper(), "readonly")
      if o.object_type == "item" then
        add("name", "Name", o.item or o.label or "", "readonly")
        add("item", "Item", o.item or "", "text")
      else
        add("name", "Name", (o.label ~= nil and o.label ~= "") and o.label
          or o.sprite or "New Object", "text")
        add("movement", "Walks",
          (o.movement == "WALK") and "WALK" or "STAY", "choice",
          Objects.MOVEMENT_CHOICES)
        add("range", (o.movement == "WALK") and "Roams" or "Faces",
          tostring(o.range or ""), "choice",
          Objects.RANGE_CHOICES[(o.movement == "WALK") and "WALK" or "STAY"])
        add("text", "Dialog", o.text or "", "text")
        if o.pokemon ~= nil and o.pokemon ~= "" then
          add("pokemon", "Pokemon", tostring(o.pokemon), "text")
          add("level", "Level", tostring(o.level or 5), "number")
        end
        if o.item ~= nil and o.item ~= "" and o.item ~= "0" then
          add("item", "Item", tostring(o.item), "text")
        end
        if o.isTrainer then
          add("trainerClass", "Trainer class", o.trainerClass or "", "text")
          add("trainerParty", "Party #", tostring(o.trainerParty or 1),
            "number")
          local teamLabel = (o.customParty and #o.customParty > 0)
            and ("CUSTOM (" .. #o.customParty .. ")") or "shared"
          add("team", "Team", teamLabel, "action")
          add("winText", "After win", o.winText or "", "text")
          add("prizeItem", "Prize item", o.prizeItem or "NONE", "text")
          add("sight", "Sight", tostring(o.sight or 0), "number")
        end
        if o.mart and type(o.items) == "table" then
          add("items", "Items", table.concat(o.items, ", "), "readonly")
        end
      end
      add("pos", "Pos", (o.x ~= nil and o.y ~= nil) and (o.x .. "," .. o.y) or "-",
        "readonly")
    elseif et == "sign" then
      local s = target.entity
      add("type", "Type", "SIGN", "readonly")
      add("label", "Label", (s.label ~= nil and s.label ~= "") and s.label or "New Sign", "text")
      add("text", "Text", s.text or "", "text")
      add("pos", "Pos", (s.x ~= nil and s.y ~= nil) and (s.x .. "," .. s.y) or "-",
        "readonly")
    end
  else
    local it = target and target.item
    if not it then return fields end
    if it.kind == "block" then
      add("tile", "Tile", tostring(it.id), "readonly")
    elseif it.kind == "blueprint" then
      add("name", "Name", it.name or it.id, "text")
      add("size", "Size", (it.w and it.h) and (it.w .. "x" .. it.h) or "-",
        "readonly")
    else -- sprite / item
      add("name", "Name", it.name or it.id, "text")
      if it.kind == "entity" and it.create
          and it.create.objectType == "trainer" then
        local party = it.create.trainerParty or 1
        add("team", "Team",
          tostring(it.create.trainerClass or "?") .. " #" .. tostring(party),
          "action")
      end
    end
  end
  return fields
end

-- Panel title for a target.
function Details.title(state)
  local t = state and state.target
  if t and t.entity then
    local et = t.entityType
    if et == "warp" then
      local w = t.entity
      return ("WARP %d,%d"):format(w.x or 0, w.y or 0)
    end
    if et == "object" then
      local o = t.entity
      local n = (o.label ~= nil and o.label ~= "") and o.label
        or o.sprite or o.item or "OBJECT"
      return (o.object_type or "OBJECT"):upper() .. " " .. tostring(n)
    end
    if et == "sign" then
      local s = t.entity
      local n = (s.label ~= nil and s.label ~= "") and s.label or "New Sign"
      return "SIGN " .. tostring(n)
    end
  end
  if t and t.map then
    return "MAP " .. tostring(t.mapId or "")
  end
  if t and t.item then
    return (t.item.kind or "ITEM"):upper() .. " " .. tostring(t.item.id or "")
  end
  return "DETAILS"
end

-- ---------------------------------------------------------------------------
-- Editing operations (called from Details.key / the input dispatcher)

local function applyToWarp(session, d, key, value)
  if not (d and d.entity) then return false end
  if key == "destMap" then
    if value ~= "" and session.data and session.data.maps[value] then
      return session:setWarpDest(d.entity, value)
    end
    return false
  elseif key == "destWarp" then
    return session:setWarpDest(d.entity, nil, math.max(0, tonumber(value) or 0))
  elseif key == "label" then
    return session:setWarpLabel(d.entity, value)
  end
  return false
end

local function applyToItem(d, key, value)
  if not (d and d.item) then return false end
  if key == "name" then
    d.item.name = value
    return true
  end
  return false
end

-- Object fields all write through Objects:setObjectProperty (validation,
-- undo capture, live refresh happen there); "name" maps to the label setter.
local function applyToObject(session, d, key, value)
  if not (d and d.entity) then return false end
  return session:setObjectProperty(d.entity, key, value)
end

local function applyToSign(session, d, key, value)
  if not (d and d.entity) then return false end
  if key == "label" then
    return session:setSignLabel(d.entity, value)
  elseif key == "text" then
    d.entity.text = value
    return true
  end
  return false
end

local function applyToMap(session, d, key, value)
  if not (d and d.map) then return false end
  if key == "name" then
    return session:setMapName(d.mapId, value)
  end
  return false
end

-- Commits an edited value to the active field (writes through to the entity /
-- item / map).  Refreshes the field's display value on success.
function Details.commit(session, d, fieldIdx, value)
  local f = d and d.fields and d.fields[fieldIdx]
  if not f then return false end
  local ok
  if d.entity then
    local et = d.entityType
    if et == "warp" then ok = applyToWarp(session, d, f.key, value)
    elseif et == "object" then ok = applyToObject(session, d, f.key, value)
    elseif et == "sign" then ok = applyToSign(session, d, f.key, value)
    end
  elseif d.map then ok = applyToMap(session, d, f.key, value)
  else ok = applyToItem(d, f.key, value) end
  if ok then
    if d.entity and d.entityType == "object" then
      -- Live object state is authoritative (setObjectProperty validates and
      -- may coerce), so rebuild every row — conditional fields like trainer /
      -- pokemon / item must appear and disappear with the data.
      local keep = math.min(d.index or 1, #d.fields)
      d.fields = Details.build(session, d.target)
      d.index = math.min(keep, #d.fields)
    else
      f.value = value
    end
  end
  return ok
end

-- Cycles the active choice field by delta (wrapping) and commits the id.
local function cycleChoice(session, d, delta)
  local f = d and d.fields and d.fields[d.index]
  if not f or f.type ~= "choice" or not f.choices then return end
  local n = #f.choices
  local cur = 1
  for i, c in ipairs(f.choices) do
    if c.id == f.value then cur = i break end
  end
  local nextId = f.choices[((cur - 1 + delta) % n) + 1].id
  Details.commit(session, d, d.index, nextId)
end

-- Nudges a numeric field or cycles a choice (Left/Right).
function Details.nudge(session, d, delta)
  local f = d and d.fields and d.fields[d.index]
  if not f then return end
  if f.type == "choice" then
    cycleChoice(session, d, delta)
    return
  end
  if f.type ~= "number" then return end
  local v = math.max(0, (tonumber(f.value) or 0) + delta)
  Details.commit(session, d, d.index, tostring(v))
end

-- Enter on the active field: starts a text edit, cycles a choice, or runs an
-- action.
function Details.activate(ui, session, d)
  local f = d and d.fields and d.fields[d.index]
  if not f then return end
  if f.type == "text" then
    -- Dialog fields on placed entities compose in the dialog editor
    -- (multi-line + page breaks + live game preview); everything else edits
    -- inline.
    local composeKey = (f.key == "text" and d.entityType ~= nil)
      or (f.key == "winText" and d.entity)
    if composeKey and not d.readOnly then
      local DialogEditor =
        require("mods.mapamap.components.dialog_editor")
      local ent = d.entity
      local isWin = f.key == "winText"
      local title = isWin and "AFTER-WIN TEXT"
        or ((d.entityType == "sign") and "SIGN TEXT" or "DIALOG")
      ui.details = nil
      DialogEditor.open(ui, session, {
        title = title,
        text = (isWin and ent.winText or ent.text) or "",
        onSave = function(t)
          t = (t ~= "") and t or nil
          if isWin then ent.winText = t else ent.text = t end
          session.mapChanged = true
        end,
      })
    elseif not d.editing then
      d.editing = { fieldIdx = d.index, buf = f.value }
    end
  elseif f.type == "choice" then
    cycleChoice(session, d, 1)
  elseif f.type == "action" then
    if f.key == "encounters" then
      -- Open the encounter editor for this map.
      local EncEditor = require("mods.mapamap.components.encounter_editor")
      ui.details = nil
      EncEditor.open(ui, session)
    elseif f.key == "team" then
      -- Trainer team editing shares the Party Editor's modal slot (the
      -- details panel reopens on DONE).  Both live placements and stored
      -- trainer tools carry the row.
      local PartyEditor = require("mods.mapamap.components.party_editor")
      ui.details = nil
      PartyEditor.open(ui, session,
        d.item and { item = d.item } or { entity = d.entity })
    else
      Details.delete(ui, session, d)
    end
  end
end

-- Deletes the target (entity from the map, or the item from the inventory).
-- Read-only targets (entities on other maps) are never deleted.
function Details.delete(ui, session, d)
  if not d or d.readOnly then return end
  if d.entity then
    local et = d.entityType
    if et == "warp" then
      session:removeWarp(d.entity)
      if session.selectedItem == d.entity then session.selectedItem = nil end
    elseif et == "object" then
      session:removeObject(d.entity)
    elseif et == "sign" then
      session:removeSign(d.entity)
      if session.selectedItem == d.entity then session.selectedItem = nil end
    end
  elseif d.item then
    for i = #(ui.inventory.items or {}), 1, -1 do
      if ui.inventory.items[i] == d.item then
        table.remove(ui.inventory.items, i)
      end
    end
  end
  ui.details = nil
end

-- ---------------------------------------------------------------------------
-- Bottom action strip: MOVE / EDIT / REMOVE for world entities.  The field
-- list stays pure data; destructive/spatial verbs live here.

local BUTTON_H = 18
local BUTTON_GAP = 4

-- The buttons for a Details state.  Only live world entities get the strip;
-- read-only targets (other maps) and inventory items/maps list nothing.
function Details.buttons(d)
  if not d or not d.entity or d.readOnly then return {} end
  return {
    { id = "move", label = "MOVE" },
    { id = "edit", label = "EDIT" },
    { id = "remove", label = "REMOVE" },
  }
end

-- The rect of strip button `i` (1-based), or nil when out of range.  The
-- strip hugs the panel bottom, just above the hint chip.
function Details.buttonRectAt(d, i, vw, vh)
  local buttons = Details.buttons(d)
  local n = #buttons
  if i < 1 or i > n then return nil end
  local x, y, w, h = Details.rect(vw, vh)
  local bw = (w - Panel.PAD * 2 - (n - 1) * BUTTON_GAP) / n
  local by = y + h - Panel.PAD - 26 - BUTTON_H
  return x + Panel.PAD + (i - 1) * (bw + BUTTON_GAP), by, bw, BUTTON_H
end

-- The id of the strip button under a screen point, or nil.
function Details.buttonAt(d, vw, vh, mx, my)
  for i, b in ipairs(Details.buttons(d)) do
    local bx, by, bw, bh = Details.buttonRectAt(d, i, vw, vh)
    if bx and mx >= bx and mx < bx + bw and my >= by and my < by + bh then
      return b.id
    end
  end
  return nil
end

-- Runs a strip button: MOVE arms a relocation carried on Input.moveTarget
-- (the next world LMB lands the entity there), EDIT reopens the entity in
-- its creator form, REMOVE deletes it.
function Details.pressButton(ui, session, d, id)
  if not d or not d.entity then return end
  if id == "move" and not d.readOnly then
    ui.moveTarget = { entity = d.entity, entityType = d.entityType }
    ui.details = nil
  elseif id == "edit" and not d.readOnly then
    local EntityCreator =
      require("mods.mapamap.components.entity_creator")
    EntityCreator.openForEdit(ui, session,
      { entity = d.entity, entityType = d.entityType })
    ui.details = nil
  elseif id == "remove" then
    Details.delete(ui, session, d)
  end
end

-- ---------------------------------------------------------------------------
-- Open / close / keyboard

-- Opens the modal Details panel for a warp / object / inventory target.
-- `target.readOnly` (an entity living on another laid-out map) lists the
-- fields but blocks every mutation: the session's ops are bound to the
-- current map's def.
function Details.open(ui, session, target)
  ui.showInventory = true
  ui.details = {
    target = target,
    entity = target.entity,
    entityType = target.entityType,
    item = target.item,
    map = target.map,
    mapId = target.mapId,
    readOnly = target.readOnly or false,
    fields = Details.build(session, target),
    index = 1,
    editing = nil,
  }
end

-- Closes the modal Details panel.
function Details.close(ui)
  ui.details = nil
end

-- The Details target for an inventory cell: a live entity entry opens
-- the live map entry, anything else opens the stored cell itself.
function Details.openForItem(ui, session, item)
  if not item then return end
  if item.kind == "entity" then
    local et = item.entityType
    if et == "warp" and item.warp then
      session.selectedItem = item.warp
      Details.open(ui, session, { entity = item.warp, entityType = "warp" })
    elseif et == "object" and item.obj then
      session.selectedItem = item.obj
      Details.open(ui, session, { entity = item.obj, entityType = "object" })
    elseif et == "sign" and item.sign then
      session.selectedItem = item.sign
      Details.open(ui, session, { entity = item.sign, entityType = "sign" })
    end
  else
    Details.open(ui, session, { item = item })
  end
end

-- Keyboard editing of the open Details panel.  Returns true when consumed.
-- Read-only targets (entities on other maps) only navigate and close.
function Details.key(ui, session, key)
  if not ui.details then return false end
  local d = ui.details
  if key == "up" then
    d.index = math.max(1, d.index - 1)
    return true
  elseif key == "down" then
    d.index = math.min(#(d.fields or {}), d.index + 1)
    return true
  elseif key == "escape" then
    if d.editing then
      d.editing = nil
    else
      ui.details = nil
    end
    return true
  elseif d.readOnly then
    return true
  elseif key == "left" then
    if d.editing then return true end
    Details.nudge(session, d, -1)
    return true
  elseif key == "right" then
    if d.editing then return true end
    Details.nudge(session, d, 1)
    return true
  elseif key == "return" or key == "kpenter" then
    if d.editing then
      Details.commit(session, d, d.editing.fieldIdx, d.editing.buf)
      d.editing = nil
    else
      Details.activate(ui, session, d)
    end
    return true
  elseif key == "backspace" then
    if d.editing then
      d.editing.buf = d.editing.buf:sub(1, #d.editing.buf - 1)
    end
    return true
  elseif key == "m" and not d.editing then
    Details.pressButton(ui, session, d, "move")
    return true
  elseif key == "e" and not d.editing then
    Details.pressButton(ui, session, d, "edit")
    return true
  elseif key == "x" or key == "delete" then
    Details.delete(ui, session, d)
    return true
  elseif #key == 1 then
    if d.editing and d.editing.buf then
      d.editing.buf = d.editing.buf .. key
      return true
    end
    return true
  end
  return true
end

-- ---------------------------------------------------------------------------
-- Draw

function Details.draw(session, state, vw, vh, font)
  local x, y, w, h = Details.rect(vw, vh)
  Panel.drawBg(x, y, w, h, 0.92)
  Panel.drawTitle(font, Details.title(state), x, y)

  local rowY = y + Panel.PAD + 20
  for i, f in ipairs(state.fields or {}) do
    local ry = rowY + (i - 1) * (Panel.ROW_H + 6)
    Text.label(font, Panel.fitText(font, f.label .. ":", w / 2 - 6, 2),
      x + Panel.PAD, ry, 2, { bg = Panel.CHIP_ROW, padX = 2, padY = 1 })
    local value = f.value
    if f.type == "choice" and f.choices then
      local lbl = tostring(f.value)
      for _, c in ipairs(f.choices) do
        if c.id == f.value then lbl = c.label break end
      end
      value = "" .. lbl .. ""
    end
    if state.editing and state.editing.fieldIdx == i then
      value = state.editing.buf .. "_"
    end
    Text.label(font, Panel.fitText(font, value, w / 2 - 8, 2),
      x + w / 2, ry, 2, { bg = Panel.CHIP_VALUE, padX = 2, padY = 1 })
    if state.index == i then
      if f.type == "action" then
        if f.key == "encounters" then
          love.graphics.setColor(0.2, 0.8, 0.3, 0.9)
        else
          love.graphics.setColor(1, 0.3, 0.2, 0.9)
        end
        love.graphics.rectangle("line", x + 2, ry - 3, w - 4, Panel.ROW_H)
      else
        Panel.drawSel(x + 2, ry - 3, w - 4, Panel.ROW_H)
      end
    end
  end

  -- Bottom action strip (MOVE / EDIT / REMOVE) for live world entities.
  local buttons = Details.buttons(state)
  local hoverBtn = love.mouse.getPosition()
    and Details.buttonAt(state, vw, vh, love.mouse.getPosition()) or nil
  for i, b in ipairs(buttons) do
    local bx, by, bw, bh = Details.buttonRectAt(state, i, vw, vh)
    if bx then
      local isRemove = b.id == "remove"
      love.graphics.setColor(isRemove and 0.45 or 0.16,
        isRemove and 0.16 or 0.16, isRemove and 0.14 or 0.22, 0.95)
      love.graphics.rectangle("fill", bx, by, bw, bh)
      if isRemove then
        love.graphics.setColor(1, 0.35, 0.3, 0.9)
      elseif hoverBtn == b.id then
        love.graphics.setColor(Panel.COLOR_HOVER[1], Panel.COLOR_HOVER[2],
          Panel.COLOR_HOVER[3], Panel.COLOR_HOVER[4])
      else
        love.graphics.setColor(Panel.COLOR_SEL[1], Panel.COLOR_SEL[2],
          Panel.COLOR_SEL[3], 0.9)
      end
      love.graphics.rectangle("line", bx, by, bw, bh)
      local lw = Panel.labelWidth(font, b.label)
      Text.label(font, b.label,
        bx + math.max(2, math.floor((bw - lw) / 2)), by + 3, 2)
    end
  end
  Panel.resetColor()

  local hint
  if state.readOnly then
    hint = "READ-ONLY (other map)  Up/Down: field  Esc: close"
  elseif state.editing then
    hint = "Enter: ok  Esc: cancel"
  else
    hint = "Up/Down: field  L/R: +-  Enter: edit  M/E: move/edit  X: del"
  end
  Panel.drawHint(font, hint, x, y, w, h)
  Panel.resetColor()
end

return Details
