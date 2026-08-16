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
local Text = require("mods.mapamap.components.text")

local Details = {}

Details.PAD = 8
Details.ROW_H = 24

-- The panel is the inventory's equal-sized side panel (the picker's spot; the
-- picker is closed while details are open).
function Details.rect(vw, vh)
  return Inventory.sideRect(vw, vh)
end

-- True when a screen point is inside the details panel.
function Details.over(vw, vh, mx, my)
  local x, y, w, h = Details.rect(vw, vh)
  return mx >= x and mx < x + w and my >= y and my < y + h
end

-- The field index whose row a screen point is over (mouse hover / click), or
-- nil.  Rows mirror the keyboard's field list.
function Details.hit(vw, vh, mx, my)
  local x, y, w, h = Details.rect(vw, vh)
  if mx < x or mx >= x + w or my < y or my >= y + h then return nil end
  local rowY = y + Details.PAD + 20
  local n = math.floor((my - rowY) / (Details.ROW_H + 6)) + 1
  if n < 1 then return nil end
  return n
end

-- The field list for a target.  `target` is
--   { warp = <def.warps entry> }    a live warp on the edited map
--   { item = <inventory cell> }     a stored block/sprite/item/blueprint
--   { object = <def.objects entry> } a live object on the edited map
-- Field rows are { key, label, value, type } where type is "readonly",
-- "text", "number" or "action" (DELETE).
function Details.build(session, target)
  local fields = {}
  local function add(key, label, value, kind)
    fields[#fields + 1] = { key = key, label = label, value = value,
                            type = kind or "text" }
  end
  if target and target.warp then
    local w = target.warp
    add("pos", "Pos", (w.x ~= nil and w.y ~= nil) and (w.x .. "," .. w.y) or "-",
      "readonly")
    add("destMap", "Dest map", w.destMap or "?", "text")
    add("destWarp", "Warp #", tostring(w.destWarp or 0), "number")
    add("label", "Label", w.label or "", "text")
    add("delete", "DELETE", "", "action")
  elseif target and target.object then
    local o = target.object
    add("type", "Type", (o.object_type or "OBJECT"):upper(), "readonly")
    if o.object_type == "item" then
      add("name", "Name", o.item or o.label or "", "readonly")
    else
      add("name", "Name", (o.label ~= nil and o.label ~= "") and o.label
        or o.sprite or "New Object", "text")
    end
    add("pos", "Pos", (o.x ~= nil and o.y ~= nil) and (o.x .. "," .. o.y) or "-",
      "readonly")
    add("delete", "DELETE", "", "action")
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
    end
    add("delete", "DELETE", "", "action")
  end
  return fields
end

-- Panel title for a target.
function Details.title(state)
  local t = state and state.target
  if t and t.warp then
    local w = t.warp
    return ("WARP %d,%d"):format(w.x or 0, w.y or 0)
  end
  if t and t.object then
    local o = t.object
    local n = (o.label ~= nil and o.label ~= "") and o.label
      or o.sprite or o.item or "OBJECT"
    return (o.object_type or "OBJECT"):upper() .. " " .. tostring(n)
  end
  if t and t.item then
    return (t.item.kind or "ITEM"):upper() .. " " .. tostring(t.item.id or "")
  end
  return "DETAILS"
end

-- ---------------------------------------------------------------------------
-- Editing operations (called from Details.key / the input dispatcher)

local function applyToWarp(session, d, key, value)
  if not (d and d.warp) then return false end
  if key == "destMap" then
    if value ~= "" and session.data and session.data.maps[value] then
      return session:setWarpDest(d.warp, value)
    end
    return false
  elseif key == "destWarp" then
    return session:setWarpDest(d.warp, nil, math.max(0, tonumber(value) or 0))
  elseif key == "label" then
    return session:setWarpLabel(d.warp, value)
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

local function applyToObject(session, d, key, value)
  if not (d and d.object) then return false end
  if key == "name" then
    return session:setObjectLabel(d.object, value)
  end
  return false
end

-- Commits an edited value to the active field (writes through to the warp /
-- item / object).  Refreshes the field's display value on success.
function Details.commit(session, d, fieldIdx, value)
  local f = d and d.fields and d.fields[fieldIdx]
  if not f then return false end
  local ok
  if d.warp then ok = applyToWarp(session, d, f.key, value)
  elseif d.object then ok = applyToObject(session, d, f.key, value)
  else ok = applyToItem(d, f.key, value) end
  if ok then f.value = value end
  return ok
end

-- Nudges a numeric field (Left/Right).
function Details.nudge(session, d, delta)
  local f = d and d.fields and d.fields[d.index]
  if not f or f.type ~= "number" then return end
  local v = math.max(0, (tonumber(f.value) or 0) + delta)
  Details.commit(session, d, d.index, tostring(v))
end

-- Enter on the active field: starts a text edit, or runs a DELETE action.
function Details.activate(ui, session, d)
  local f = d and d.fields and d.fields[d.index]
  if not f then return end
  if f.type == "text" then
    d.editing = { fieldIdx = d.index, buf = f.value }
  elseif f.type == "action" then
    Details.delete(ui, session, d)
  end
end

-- Deletes the target (warp / object from the map, or the item from the
-- inventory).
function Details.delete(ui, session, d)
  if not d then return end
  if d.warp then
    session:removeWarp(d.warp)
    if session.selectedWarp == d.warp then session.selectedWarp = nil end
  elseif d.object then
    session:removeObject(d.object)
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
-- Open / close / keyboard

-- Opens the modal Details panel for a warp / object / inventory target.
function Details.open(ui, session, target)
  ui.details = {
    target = target,
    warp = target.warp,
    object = target.object,
    item = target.item,
    fields = Details.build(session, target),
    index = 1,
    editing = nil,
  }
end

-- Closes the modal Details panel.
function Details.close(ui)
  ui.details = nil
end

-- The Details target for an inventory cell: a live warp / object entry opens
-- the live map entry, anything else opens the stored cell itself.
function Details.openForItem(ui, session, item)
  if not item then return end
  if item.kind == "warp" and item.warp then
    session.selectedWarp = item.warp
    Details.open(ui, session, { warp = item.warp })
  elseif item.kind == "object" and item.obj then
    session.selectedObject = item.obj
    Details.open(ui, session, { object = item.obj })
  else
    Details.open(ui, session, { item = item })
  end
end

-- Keyboard editing of the open Details panel.  Returns true when consumed.
function Details.key(ui, session, key)
  if not ui.details then return false end
  local d = ui.details
  if key == "up" then
    d.index = math.max(1, d.index - 1)
    return true
  elseif key == "down" then
    d.index = math.min(#(d.fields or {}), d.index + 1)
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
  elseif key == "x" or key == "delete" then
    Details.delete(ui, session, d)
    return true
  elseif key == "escape" then
    if d.editing then
      d.editing = nil
    else
      ui.details = nil
    end
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

local function fitText(font, s, budgetPx, scale)
  scale = scale or 2
  local function w(t)
    return ((font.width and font.width(t)) or (#t * 8)) * scale
  end
  if w(s) <= budgetPx then return s end
  while #s > 0 and w(s) > budgetPx do s = s:sub(1, #s - 1) end
  return s .. "..."
end

function Details.draw(session, state, vw, vh, font)
  local x, y, w, h = Details.rect(vw, vh)
  love.graphics.setColor(0, 0, 0, 0.92)
  love.graphics.rectangle("fill", x, y, w, h)
  love.graphics.setColor(0.55, 0.55, 0.6, 0.5)
  love.graphics.rectangle("line", x, y, w, h)

  Text.label(font, Details.title(state), x + Details.PAD, y + 6, 2, {
    bg = { 0.92, 0.92, 0.95, 0.95 }, padX = 3, padY = 2,
  })

  local rowY = y + Details.PAD + 20
  for i, f in ipairs(state.fields or {}) do
    local ry = rowY + (i - 1) * (Details.ROW_H + 6)
    Text.label(font, fitText(font, f.label .. ":", w / 2 - 6, 2),
      x + Details.PAD, ry, 2, { bg = { 0.85, 0.85, 0.9, 0.9 }, padX = 2, padY = 1 })
    local value = f.value
    if state.editing and state.editing.fieldIdx == i then
      value = state.editing.buf .. "_"
    end
    Text.label(font, fitText(font, value, w / 2 - 8, 2),
      x + w / 2, ry, 2, { bg = { 0.92, 0.92, 0.95, 0.95 }, padX = 2, padY = 1 })
    if state.index == i then
      if f.type == "action" then
        love.graphics.setColor(1, 0.3, 0.2, 0.9)
        love.graphics.rectangle("line", x + 2, ry - 3, w - 4, Details.ROW_H)
      else
        love.graphics.setColor(0.25, 0.5, 1, 0.9)
        love.graphics.rectangle("line", x + 2, ry - 3, w - 4, Details.ROW_H)
      end
    end
  end

  local hint = state.editing and "Enter: ok  Esc: cancel"
                    or "Up/Down: field  L/R: +-  Enter: edit  X: del  Esc: close"
  Text.label(font, fitText(font, hint, w - Details.PAD * 2, 1),
    x + Details.PAD, y + h - Details.PAD - 8, 1,
    { bg = { 0.2, 0.2, 0.25, 0.9 }, padX = 2, padY = 1 })
  love.graphics.setColor(1, 1, 1, 1)
end

return Details