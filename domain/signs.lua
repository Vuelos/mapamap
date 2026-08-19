-- module for Session handling Signs instances on the edited map.

local Gen = require("mods.mapamap.engine.gen")

local Signs = {}

-- Bounds check for a walk-grid cell against a map def.
local function cellIn(def, x, y)
  return x >= 0 and y >= 0 and x < def.width * 2 and y < def.height * 2
end

function Signs:refreshSigns()
  return true
end

-- The sign at a walk-grid cell on the edited map, or nil.
function Signs:signAt(cellX, cellY)
  for _, o in ipairs(self.def.signs or {}) do
    if (o.x or -1) == cellX and (o.y or -1) == cellY then return o end
  end
  return nil
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

-- Places a new sign at the cell (the "New Sign" template tool),
-- The name is editable via the Details panel. Returns
-- the new sign or nil when no sprite exists to render with.
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