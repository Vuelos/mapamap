-- module for Session handling object and NPC instances on the edited map.

local Gen = require("mods.mapamap.engine.gen")
local WorldAdapter = require("mods.mapamap.engine.world_adapter")

local Objects = {}

-- Range vocabularies per movement mode (engine: NPC.new reads range as the
-- facing when STAY and as the roam mask when WALK).
Objects.OBJECT_RANGES = {
  STAY = { "DOWN", "UP", "LEFT", "RIGHT", "NONE" },
  WALK = { "ANY_DIR", "UP_DOWN", "LEFT_RIGHT" },
}

-- User-facing choice rows (id + label) shared by the Entity Creator and the
-- Details panel; ids are exactly the OBJECT_RANGES vocabularies.
Objects.MOVEMENT_CHOICES = {
  { id = "STAY", label = "Stands still" },
  { id = "WALK", label = "Walks around" },
}

local function labeled(ids, labels)
  local out = {}
  for _, id in ipairs(ids) do
    out[#out + 1] = { id = id, label = labels[id] or id }
  end
  return out
end

Objects.RANGE_CHOICES = {
  STAY = labeled(Objects.OBJECT_RANGES.STAY, {
    DOWN = "Faces down", UP = "Faces up",
    LEFT = "Faces left", RIGHT = "Faces right",
    NONE = "No facing",
  }),
  WALK = labeled(Objects.OBJECT_RANGES.WALK, {
    ANY_DIR = "Roams freely",
    UP_DOWN = "Walks up/down",
    LEFT_RIGHT = "Walks left/right",
  }),
}

-- Marks the map changed and refreshes whatever an object edit affects.
local function touch(self)
  self.mapChanged = true
  self:refreshLiveRenderers()
  self:refreshObjects()
end

-- Validates + writes one editable object property from the Details panel.
-- Returns true when written; invalid values keep the old ones.  Switching
-- movement coerces the range into the new vocabulary.  Empty strings clear
-- optional payloads (text / item / trainerClass).
function Objects:setObjectProperty(obj, key, value)
  if not obj then return false end
  local data = self.data or {}
  if key == "movement" then
    if value ~= "STAY" and value ~= "WALK" then return false end
    if obj.movement ~= value then
      if self.undo then self.undo:capture(self.def) end
      obj.movement = value
      local allowed = Objects.OBJECT_RANGES[value]
      local okRange = false
      for _, r in ipairs(allowed) do
        if obj.range == r then okRange = true break end
      end
      if not okRange then obj.range = allowed[1] end
    end
    touch(self)
    return true
  elseif key == "range" then
    for _, r in ipairs(Objects.OBJECT_RANGES[obj.movement or "STAY"]) do
      if r == value then
        if obj.range ~= value then
          if self.undo then self.undo:capture(self.def) end
          obj.range = value
        end
        touch(self)
        return true
      end
    end
    return false
  elseif key == "text" then
    if type(value) ~= "string" then return false end
    if self.undo then self.undo:capture(self.def) end
    if value == "" then value = nil end
    obj.text = value
    touch(self)
    return true
  elseif key == "pokemon" then
    if not (value and data.pokemon and data.pokemon[value]) then return false end
    if self.undo then self.undo:capture(self.def) end
    obj.pokemon = value
    touch(self)
    return true
  elseif key == "level" then
    local lvl = tonumber(value)
    if not lvl then return false end
    if self.undo then self.undo:capture(self.def) end
    obj.level = math.max(1, math.min(lvl, 100))
    touch(self)
    return true
  elseif key == "item" then
    if value ~= "" and not (data.items and data.items[value]) then return false end
    if self.undo then self.undo:capture(self.def) end
    if value == "" then value = nil end
    obj.item = value
    touch(self)
    return true
  elseif key == "trainerClass" then
    if value ~= "" and not (data.trainers and data.trainers[value]) then
      return false
    end
    if self.undo then self.undo:capture(self.def) end
    if value == "" then
      obj.trainerClass = nil
      obj.isTrainer = false
    else
      obj.trainerClass = value
      obj.isTrainer = true
    end
    touch(self)
    return true
  elseif key == "trainerParty" then
    local party = tonumber(value)
    if not party then return false end
    local tdef = obj.trainerClass and data.trainers and data.trainers[obj.trainerClass]
    local maxParty = tdef and math.max(1, #(tdef.parties or {})) or 6
    if self.undo then self.undo:capture(self.def) end
    obj.trainerParty = math.max(1, math.min(party, maxParty))
    touch(self)
    return true
  elseif key == "name" then
    return self:setObjectLabel(obj, value)
  end
  return false
end

-- Bounds check for a walk-grid cell against a map def.
local function cellIn(def, x, y)
  return x >= 0 and y >= 0 and x < def.width * 2 and y < def.height * 2
end

-- Rebuilds the overworld's live NPC list for the current map from def.objects
-- (the same source the engine reads on map enter), so a just-placed or removed
-- object appears immediately instead of waiting for the next map enter. No-op
-- when the visible map isn't the session's, or the world has no npc pool helper.
function Objects:refreshObjects()
  -- Keep custom object texts wired into the engine's talk dispatch before
  -- the early returns (registration is overworld-independent).
  WorldAdapter.registerTalkTexts(self)
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

-- Places a copy tool for `sample` at the cell as a new object ("copy an
-- object from the map").  ROM objects carry no object_type, so any sample
-- with a sprite / item / pokemon payload is accepted. Returns the new object
-- or nil.
function Objects:placeObjectCopy(cellX, cellY, sample)
  if not cellIn(self.def, cellX, cellY) then return nil end
  if not (sample and (sample.object_type or sample.sprite or sample.item
                      or sample.pokemon)) then return nil end
  if self:cellOccupied(cellX, cellY) then return nil end
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

-- Places a fresh simple NPC at the cell, using the first sprite in the
-- engine's sprite table so the object is immediately visible; the name is
-- editable via the Details panel. Returns the new object or nil when no
-- sprite exists to render with.
function Objects:placeNewObject(cellX, cellY)
  if not cellIn(self.def, cellX, cellY) then return nil end
  if self:cellOccupied(cellX, cellY) then return nil end
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
    movement = "STAY",
    range = "DOWN",
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

-- Places a fully-specified object at the cell from an Entity Creator / picker
-- tool spec: { objectType = "npc"|"trainer"|"mon"|"itemball", sprite, label,
-- trainerClass, trainerParty, pokemon, level, item, movement, range, text }.
-- Only the fields the spec carries land on the object, so each source
-- produces exactly the entity it described; movement/range fall back to a
-- STAY/DOWN default and an out-of-vocabulary range is coerced into the
-- movement's own vocabulary.  Returns the new object or nil.
function Objects:placeObjectSpec(cellX, cellY, spec)
  if not cellIn(self.def, cellX, cellY) then return nil end
  if not (spec and spec.objectType) then return nil end
  if self:cellOccupied(cellX, cellY) then return nil end
  local obj = {
    x = cellX, y = cellY,
    index = 0,
    object_type = "NPC",
    movement = "STAY",
    range = "DOWN",
    isTrainer = false,
    trainerClass = nil,
    script = nil,
    item = nil,
    label = spec.label,
  }
  -- Movement + facing/roam range (engine: NPC.new reads range as the facing
  -- when STAY and as the roam mask when WALK).
  if spec.movement == "WALK" or spec.movement == "STAY" then
    obj.movement = spec.movement
  end
  do
    local okRange = false
    for _, r in ipairs(Objects.OBJECT_RANGES[obj.movement]) do
      if r == spec.range then obj.range = r; okRange = true break end
    end
    if not okRange and not spec.range then
      -- keep the STAY/DOWN defaults
    elseif not okRange then
      obj.range = Objects.OBJECT_RANGES[obj.movement][1]
    end
  end
  -- Custom dialog text (WorldAdapter.registerTalkTexts wires non-TEXT_
  -- strings into the engine's talk dispatch).
  if type(spec.text) == "string" and spec.text ~= "" then
    obj.text = spec.text
  end
  -- Movement / facing-or-roam range / dialog text from creator specs; an
  -- out-of-vocabulary range falls back to its vocabulary's first entry.
  obj.movement = (spec.movement == "WALK") and "WALK" or "STAY"
  do
    local okRange = false
    for _, r in ipairs(Objects.OBJECT_RANGES[obj.movement]) do
      if spec.range == r then okRange = true break end
    end
    obj.range = okRange and spec.range or Objects.OBJECT_RANGES[obj.movement][1]
  end
  if type(spec.text) == "string" and spec.text ~= "" then
    obj.text = spec.text
  end
  if spec.objectType == "trainer" then
    if not (spec.trainerClass and self.data.trainers
            and self.data.trainers[spec.trainerClass]) then return nil end
    obj.isTrainer = true
    obj.trainerClass = spec.trainerClass
    obj.trainerParty = math.max(1, tonumber(spec.trainerParty) or 1)
  elseif spec.objectType == "mon" then
    if not (spec.pokemon and self.data.pokemon
            and self.data.pokemon[spec.pokemon]) then return nil end
    obj.pokemon = spec.pokemon
    obj.level = math.max(1, math.min(tonumber(spec.level) or 5, 100))
  elseif spec.objectType == "itemball" then
    if not (spec.item and self.data.items and self.data.items[spec.item]) then
      return nil
    end
    obj.object_type = "item"
    obj.item = spec.item
  end
  local spriteId = spec.sprite
  if obj.object_type == "item" and not spriteId then
    spriteId = "SPRITE_POKE_BALL"
  end
  if spriteId and self.data.sprites and self.data.sprites[spriteId] then
    obj.sprite = spriteId
  end
  local maxIndex = 0
  for _, o in ipairs(self.def.objects or {}) do
    if (o.index or 0) > maxIndex then maxIndex = o.index end
  end
  obj.index = maxIndex + 1
  if self.undo then self.undo:capture(self.def) end
  self.def.objects = self.def.objects or {}
  table.insert(self.def.objects, obj)
  self.mapChanged = true
  self:refreshLiveRenderers()
  self:refreshObjects()
  return obj
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
    movement = "STAY",
    range = "DOWN",
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
    sprite = "SPRITE_POKE_BALL",
    index = maxIndex + 1,
    object_type = "item",
    movement = "STAY",
    range = "DOWN",
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
  if obj.x == cellX and obj.y == cellY then return true end
  if self:cellOccupied(cellX, cellY, obj) then return false end
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