-- module for Session handling object and NPC instances on the edited map.

local Gen = require("mods.mapamap.engine.gen")

local Objects = {}

-- Bounds check for a walk-grid cell against a map def.
local function cellIn(def, x, y)
  return x >= 0 and y >= 0 and x < def.width * 2 and y < def.height * 2
end

-- Rebuilds the overworld's live NPC list for the current map from def.objects
-- (the same source the engine reads on map enter), so a just-placed or removed
-- object appears immediately instead of waiting for the next map enter. No-op
-- when the visible map isn't the session's, or the world has no npc pool helper.
function Objects:refreshObjects()
  local ow = self.game and Gen.overworld(self.game)
  if not (ow and ow.map and ow.map.id == self.mapId) then return false end
  local fn = ow.pooledNPC
  if not fn then return false end
  ow.npcs = {}
  for _, obj in ipairs(self.def.objects or {}) do
    local npc = fn(ow.npcPool, self.data, self.mapId, obj)
    npc.frozen = false
    table.insert(ow.npcs, npc)
  end
  if ow.player then
    ow.entities = { ow.player }
    for _, n in ipairs(ow.npcs) do table.insert(ow.entities, n) end
  end
  return true
end

-- The object at a walk-grid cell on the edited map, or nil.
function Objects:objectAt(cellX, cellY)
  for _, o in ipairs(self.def.objects or {}) do
    if (o.x or -1) == cellX and (o.y or -1) == cellY then return o end
  end
  return nil
end

-- A display name for an object (the item id, sprite id, or its label).
function Objects:objectName(obj)
  if not obj then return "" end
  if obj.label and obj.label ~= "" then return obj.label end
  if obj.object_type == "item" then return obj.item or "item" end
  return obj.sprite or "object"
end

-- Places a deep copy of `sample` at the cell as a new object (the "copy an
-- object from the map" tool). Returns the new object or nil.
function Objects:placeObjectCopy(cellX, cellY, sample)
  if not cellIn(self.def, cellX, cellY) then return nil end
  if not (sample and sample.object_type) then return nil end
  if self.undo then self.undo:capture(self.def) end
  self.def.objects = self.def.objects or {}
  local maxIndex = 0
  for _, o in ipairs(self.def.objects) do
    if (o.index or 0) > maxIndex then maxIndex = o.index end
  end
  local copy = {}
  for k, v in pairs(sample) do copy[k] = v end
  copy.x, copy.y = cellX, cellY
  copy.index = maxIndex + 1
  table.insert(self.def.objects, copy)
  self.mapChanged = true
  self:refreshLiveRenderers()
  self:refreshObjects()
  return copy
end

-- Places a fresh simple NPC at the cell (the "New Object" template tool),
-- using the first sprite in the engine's sprite table so the object is
-- immediately visible; the name is editable via the Details panel. Returns
-- the new object or nil when no sprite exists to render with.
function Objects:placeNewObject(cellX, cellY)
  if not cellIn(self.def, cellX, cellY) then return nil end
  local spriteId
  for id in pairs(self.data.sprites or {}) do spriteId = id; break end
  if not spriteId then return nil end
  if self.undo then self.undo:capture(self.def) end
  self.def.objects = self.def.objects or {}
  local maxIndex = 0
  for _, o in ipairs(self.def.objects) do
    if (o.index or 0) > maxIndex then maxIndex = o.index end
  end
  table.insert(self.def.objects, {
    x = cellX, y = cellY,
    sprite = spriteId,
    index = maxIndex + 1,
    object_type = "NPC",
    isTrainer = false,
    trainerClass = nil,
    script = nil,
    item = nil,
    label = "New Object",
  })
  self.mapChanged = true
  self:refreshLiveRenderers()
  self:refreshObjects()
  return self.def.objects[#self.def.objects]
end

-- Places a simple NPC object (no script/dialog) at the current cursor cell and
-- marks the map changed. Returns true when placed.
function Objects:placeSprite(spriteId)
  if not spriteId or spriteId == "" then return false end
  if not self.data.sprites or not self.data.sprites[spriteId] then return false end
  local tx = self.cursorBx
  local ty = self.cursorBy
  local def = self.def
  if not cellIn(def, tx, ty) then return false end
  def.objects = def.objects or {}
  local maxIndex = 0
  for _, o in ipairs(def.objects) do
    if (o.index or 0) > maxIndex then maxIndex = o.index end
  end
  table.insert(def.objects, {
    x = tx, y = ty,
    sprite = spriteId,
    index = maxIndex + 1,
    object_type = "NPC",
    isTrainer = false,
    trainerClass = nil,
    script = nil,
    item = nil,
  })
  self.mapChanged = true
  self:refreshLiveRenderers()
  self:refreshObjects()
  return true
end

-- Places a simple item object (no ball/hidden flag) at the cursor cell and
-- marks the map changed. Returns true when placed.
function Objects:placeItem(itemId)
  if not itemId or itemId == "" then return false end
  if not self.data.items or not self.data.items[itemId] then return false end
  local def = self.def
  local tx = self.cursorBx
  local ty = self.cursorBy
  if not cellIn(def, tx, ty) then return false end
  def.objects = def.objects or {}
  local maxIndex = 0
  for _, o in ipairs(def.objects) do
    if (o.index or 0) > maxIndex then maxIndex = o.index end
  end
  table.insert(def.objects, {
    x = tx, y = ty,
    sprite = nil,
    index = maxIndex + 1,
    object_type = "item",
    item = itemId,
    isTrainer = false,
    script = nil,
  })
  self.mapChanged = true
  self:refreshLiveRenderers()
  self:refreshObjects()
  return true
end

-- Moves an existing object to a cell.
function Objects:moveObject(obj, cellX, cellY)
  if not obj then return false end
  if not cellIn(self.def, cellX, cellY) then return false end
  if self.undo then self.undo:capture(self.def) end
  obj.x, obj.y = cellX, cellY
  self.mapChanged = true
  self:refreshObjects()
  return true
end

-- Sets an object's display label.
function Objects:setObjectLabel(obj, label)
  if not obj then return false end
  if self.undo then self.undo:capture(self.def) end
  obj.label = label
  self.mapChanged = true
  return true
end

-- Removes an object from the edited map.
function Objects:removeObject(obj)
  local list = self.def.objects or {}
  for i = #list, 1, -1 do
    if list[i] == obj then
      if self.undo then self.undo:capture(self.def) end
      table.remove(list, i)
      self.mapChanged = true
      self:refreshLiveRenderers()
      self:refreshObjects()
      return true
    end
  end
  return false
end

-- Removes an NPC/object at the cursor cell. Returns true when one was found.
function Objects:eraseObjectsAtCell()
  local tx = self.cursorBx
  local ty = self.cursorBy
  local def = self.def
  local list = def.objects or {}
  for i = #list, 1, -1 do
    local o = list[i]
    if o and o.x == tx and o.y == ty then
      table.remove(list, i)
      self.mapChanged = true
      self:refreshLiveRenderers()
      self:refreshObjects()
      return true
    end
  end
  return false
end

return Objects