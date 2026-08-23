-- module for Session handling Signs instances on the edited map.

local Gen = require("mods.mapamap.engine.gen")
local WorldAdapter = require("mods.mapamap.engine.world_adapter")

local Signs = {}

-- Bounds check for a walk-grid cell against a map def.
local function cellIn(def, x, y)
  return x >= 0 and y >= 0 and x < def.width * 2 and y < def.height * 2
end

function Signs:refreshSigns()
  -- Sign placement/moves need no renderer work, but custom sign texts must
  -- stay wired into the engine's talk dispatch (see WorldAdapter).
  WorldAdapter.registerTalkTexts(self)
  return true
end

-- The sign at a walk-grid cell on the edited map, or nil.
function Signs:signAt(cellX, cellY)
  for _, o in ipairs(self.def.signs or {}) do
    if (o.x or -1) == cellX and (o.y or -1) == cellY then return o end
  end
  return nil
end

-- Every sign marker a def carries: the gen-1 `signs` array plus the gen-2
-- readable bgEvents (kinds 0..6; 7 ITEM and 8 COPY are not signs -- see
-- World:bgEventAt).  A def can carry BOTH: placing an editor sign does
-- `def.signs = def.signs or {}`, which must NOT shadow the bgEvents.
function Signs.mapSigns(def)
  local out = {}
  for _, s in ipairs((def and def.signs) or {}) do
    out[#out + 1] = s
  end
  for _, ev in ipairs((def and def.bgEvents) or {}) do
    if (ev.kind or 0) <= 6 then out[#out + 1] = ev end
  end
  return out
end

-- Every sign on every visible laid-out map (the edited map plus the neighbor
-- set), flattened with its map's world-pixel offset.  This is the session
-- fallback behind Overlay.visibleSigns when no live overworld frame exists.
function Signs.visibleSigns(self)
  local out = {}
  local function collect(def, ox, oy)
    for _, s in ipairs(Signs.mapSigns(def)) do
      out[#out + 1] = { sign = s, ox = ox, oy = oy }
    end
  end
  collect(self.def, 0, 0)
  for _, nb in ipairs(self.neighbors or {}) do
    collect(nb.def, nb.ox, nb.oy)
  end
  return out
end

-- A display name for a sign (the item id, sprite id, or its label).
function Signs:signName(sign)
  if not sign then return "" end
  if sign.label and sign.label ~= "" then return sign.label end
  return "sign"
end

-- Places a deep copy of `sample` at the cell as a new sign (the "copy an
-- object from the map" tool). Returns the new sign or nil.
function Signs:placeSignCopy(cellX, cellY, sample)
  if not cellIn(self.def, cellX, cellY) then return nil end
  if not (sample and sample.text) then return nil end
  if self.undo then self.undo:capture(self.def) end
  self.def.signs = self.def.signs or {}
  local maxIndex = 0
  for _, o in ipairs(self.def.signs) do
    if (o.index or 0) > maxIndex then maxIndex = o.index end
  end
  local copy = {}
  for k, v in pairs(sample) do copy[k] = v end
  copy.x, copy.y = cellX, cellY
  copy.index = maxIndex + 1
  table.insert(self.def.signs, copy)
  self.mapChanged = true
  self:refreshLiveRenderers()
  self:refreshSigns()
  return copy
end

-- Places a fresh sign at the cell; the name/text are editable via the
-- Details panel. Returns the new sign or nil when the cell is blocked.
function Signs:placeNewSign(cellX, cellY)
  if not cellIn(self.def, cellX, cellY) then return nil end
  if self:cellOccupied(cellX, cellY) then return nil end
  if self.undo then self.undo:capture(self.def) end
  self.def.signs = self.def.signs or {}
  local maxIndex = 0
  for _, o in ipairs(self.def.signs) do
    if (o.index or 0) > maxIndex then maxIndex = o.index end
  end
  table.insert(self.def.signs, {
    x = cellX, y = cellY,
    index = maxIndex + 1,
    text = "...",
    label = "",
  })
  self.mapChanged = true
  self:refreshLiveRenderers()
  self:refreshSigns()
  return self.def.signs[#self.def.signs]
end

-- Places a sign at the cell from an Entity Creator form spec:
-- { text, label }.  Returns the new sign or nil.
function Signs:placeSignSpec(cellX, cellY, spec)
  if not cellIn(self.def, cellX, cellY) then return nil end
  if self:cellOccupied(cellX, cellY) then return nil end
  if self.undo then self.undo:capture(self.def) end
  self.def.signs = self.def.signs or {}
  local maxIndex = 0
  for _, o in ipairs(self.def.signs) do
    if (o.index or 0) > maxIndex then maxIndex = o.index end
  end
  table.insert(self.def.signs, {
    x = cellX, y = cellY,
    index = maxIndex + 1,
    text = (spec and spec.text) or "...",
    label = (spec and spec.label) or "",
  })
  self.mapChanged = true
  self:refreshLiveRenderers()
  self:refreshSigns()
  return self.def.signs[#self.def.signs]
end

-- Moves an existing sign to a cell.
function Signs:moveSign(obj, cellX, cellY)
  if not obj then return false end
  if not cellIn(self.def, cellX, cellY) then return false end
  if obj.x == cellX and obj.y == cellY then return true end
  if self:cellOccupied(cellX, cellY, obj) then return false end
  if self.undo then self.undo:capture(self.def) end
  obj.x, obj.y = cellX, cellY
  self.mapChanged = true
  self:refreshSigns()
  return true
end

-- Sets an sign's display label.
function Signs:setSignLabel(obj, label)
  if not obj then return false end
  if self.undo then self.undo:capture(self.def) end
  obj.label = label
  self.mapChanged = true
  return true
end

-- Removes an sign from the edited map.
function Signs:removeSign(obj)
  local list = self.def.signs or {}
  for i = #list, 1, -1 do
    if list[i] == obj then
      if self.undo then self.undo:capture(self.def) end
      table.remove(list, i)
      self.mapChanged = true
      self:refreshLiveRenderers()
      self:refreshSigns()
      return true
    end
  end
  return false
end

-- Removes an sign at the cursor cell. Returns true when one was found.
function Signs:eraseSignsAtCell()
  local tx = self.cursorBx
  local ty = self.cursorBy
  local def = self.def
  local list = def.signs or {}
  for i = #list, 1, -1 do
    local o = list[i]
    if o and o.x == tx and o.y == ty then
      table.remove(list, i)
      self.mapChanged = true
      self:refreshLiveRenderers()
      self:refreshSigns()
      return true
    end
  end
  return false
end

return Signs