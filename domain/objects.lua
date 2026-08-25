-- module for Session handling object and NPC instances on the edited map.

local Gen = require("mods.mapamap.engine.gen")
local EditOps = require("mods.mapamap.domain.edit_ops")
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

-- Trainer sight range cap (cells): a screen is ~10 cells across, so larger
-- values would ambush off-screen.
Objects.MAX_SIGHT = 10

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
  elseif key == "winText" then
    if type(value) ~= "string" then return false end
    if self.undo then self.undo:capture(self.def) end
    obj.winText = (value ~= "") and value or nil
    touch(self)
    return true
  elseif key == "prizeItem" then
    if self.undo then self.undo:capture(self.def) end
    if value == "" or value == "NONE" then
      obj.prizeItem = nil
      obj.prizeCount = nil
    else
      if not (data.items and data.items[value]) then return false end
      obj.prizeItem = value
      obj.prizeCount = obj.prizeCount or 1
    end
    touch(self)
    return true
  elseif key == "sight" then
    local v = tonumber(value)
    if not v or v < 0 then return false end
    if self.undo then self.undo:capture(self.def) end
    v = math.min(math.floor(v), Objects.MAX_SIGHT)
    obj.sight = (v > 0) and v or nil
    touch(self)
    return true
  elseif key == "sprite" then
    -- Sprite swap from the creator's EDIT mode; the sheet must exist.
    if not (value and data.sprites and data.sprites[value]) then return false end
    if self.undo then self.undo:capture(self.def) end
    obj.sprite = value
    touch(self)
    return true
  elseif key == "berryItem" then
    -- Gen-2 berry tree payload edits.
    if value ~= "" and not (data.items and data.items[value]) then return false end
    if self.undo then self.undo:capture(self.def) end
    obj.berryItem = (value ~= "") and value or nil
    touch(self)
    return true
  elseif key == "berryCount" then
    local n = tonumber(value)
    if not n then return false end
    if self.undo then self.undo:capture(self.def) end
    obj.berryCount = math.max(1, math.floor(n))
    touch(self)
    return true
  elseif key == "name" then
    return self:setObjectLabel(obj, value)
  end
  return false
end

-- Bounds check for a walk-grid cell against a map def.
local cellIn = EditOps.cellIn

-- Spawn-gate mirror of OverworldState.objectVisible (hidden placements,
-- picked-up items, beaten static encounters, per-map name toggles) plus the
-- editor's own blocker ledger, so a live refresh never resurrects something
-- the engine itself would keep off-screen.
local function spawnVisible(self, save, obj)
  if not save then return true end
  local key = self.mapId .. "_obj_" .. tostring(obj.index)
  local toggles = save.objectToggles and save.objectToggles[self.mapId] or {}
  local visible = not obj.hidden
  if obj.name and toggles[obj.name] ~= nil then visible = toggles[obj.name] end
  if obj.item and save.itemsTaken and save.itemsTaken[key] then
    visible = false
  end
  if obj.pokemon and save.defeatedTrainers
      and save.defeatedTrainers[key] then
    visible = false
  end
  if obj.blocker and save.defeatedTrainers and save.defeatedTrainers[key] then
    visible = false
  end
  return visible
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
  -- Gen 2: the World owns its people -- object masks, time-of-day rolls,
  -- neighbor-strip ghosts and the preserved guest list (the follower) all
  -- live in World:rebuildPeople.  Hand-assembling ow.npcs here would be
  -- invisible to all of that AND get desynced by the next zoom's own
  -- rebuildPeople pass, so an edit hands the whole rebuild to the engine.
  -- Both handles Gen.overworld can answer are tried: the raw World carries
  -- rebuildPeople directly, while the Gen2Compat facade reaches it through
  -- game.world.
  if Gen.isGen2() then
    local handles = { ow, self.game and self.game.world }
    for _, world in ipairs(handles) do
      if type(world) == "table" and type(world.rebuildPeople) == "function"
          and world.map and world.map.id == self.mapId then
        pcall(world.rebuildPeople, world)
        return true
      end
    end
  end
  local fn = ow.pooledNPC
  if not fn then return false end
  local save = self.game and self.game.save
  ow.npcs = {}
  for _, obj in ipairs(self.def.objects or {}) do
    if spawnVisible(self, save, obj) then
      local npc = fn(ow.npcPool, self.data, self.mapId, obj)
      npc.frozen = false
      table.insert(ow.npcs, npc)
    end
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
  local nextIndex = EditOps.nextIndex(self.def.objects)
  local copy = {}
  for k, v in pairs(sample) do copy[k] = v end
  copy.x, copy.y = cellX, cellY
  copy.index = nextIndex
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
  local nextIndex = EditOps.nextIndex(self.def.objects)
  table.insert(self.def.objects, {
    x = cellX, y = cellY,
    sprite = spriteId,
    index = nextIndex,
    object_type = "NPC",
    movement = "STAY",
    range = "DOWN",
    isTrainer = false,
    trainerClass = nil,
    script = nil,
    item = nil,
    text = "...",
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
    -- Battler dialog set: intro (text is shared with plain NPCs), the line
    -- after defeat, and an optional one-time prize item.
    if type(spec.text) == "string" and spec.text ~= "" then
      obj.text = spec.text
    end
    if type(spec.winText) == "string" and spec.winText ~= "" then
      obj.winText = spec.winText
    end
    if type(spec.prizeItem) == "string"
        and self.data.items and self.data.items[spec.prizeItem] then
      obj.prizeItem = spec.prizeItem
      obj.prizeCount = math.max(1, tonumber(spec.prizeCount) or 1)
    end
    if spec.sight ~= nil then
      local sv = math.max(0, math.floor(tonumber(spec.sight) or 0))
      obj.sight = (math.min(sv, Objects.MAX_SIGHT) > 0)
        and math.min(sv, Objects.MAX_SIGHT) or nil
    end
  elseif spec.objectType == "boulder" then
    -- Strength-pushable stone: Map.isPushable keys off the boulder sheet.
    obj.sprite = "SPRITE_BOULDER"
    obj.pushable = true
    obj.movement = "STAY"
    obj.label = "Boulder"
  elseif spec.objectType == "blocker" then
    -- Sleeping blocker (snorlax-style): a wild battle on talk; the talk
    -- handler marks it defeated so refreshObjects stops spawning it.
    if not (spec.pokemon and self.data.pokemon
            and self.data.pokemon[spec.pokemon]) then return nil end
    obj.sprite = "SPRITE_SNORLAX"
    obj.movement = "STAY"
    obj.label = "Sleeping " .. tostring(spec.pokemon)
    obj.blocker = { species = spec.pokemon,
      level = math.max(1, math.min(tonumber(spec.level) or 30, 100)) }
  elseif spec.objectType == "berrytree" then
    -- Gen-2 daily berry tree: the World interaction seam hands out
    -- berryItem once per in-game day (see World:giveCustomBerry).
    if not (spec.berryItem and self.data.items
            and self.data.items[spec.berryItem]) then return nil end
    local function pickSprite(...)
      for _, id in ipairs({ ... }) do
        if self.data.sprites and self.data.sprites[id] then return id end
      end
      for id in pairs(self.data.sprites or {}) do return id end
      return nil
    end
    obj.sprite = pickSprite("SPRITE_FRUIT_TREE", "SPRITE_BERRY_TREE",
      "SPRITE_SMALL_TREE")
    obj.movement = "STAY"
    obj.label = "Berry Tree"
    obj.berryItem = spec.berryItem
    obj.berryCount = math.max(1, tonumber(spec.berryCount) or 1)
  elseif spec.objectType == "mon" then
    if not (spec.pokemon and self.data.pokemon
            and self.data.pokemon[spec.pokemon]) then return nil end
    obj.pokemon = spec.pokemon
    obj.level = math.max(1, math.min(tonumber(spec.level) or 5, 100))
  elseif spec.objectType == "shop" then
    -- Poke Mart: an NPC that opens a shop dialog with the listed items.
    if type(spec.items) ~= "table" or #spec.items == 0 then return nil end
    obj.mart = true
    obj.items = {}
    for _, id in ipairs(spec.items) do
      if self.data.items and self.data.items[id] then
        obj.items[#obj.items + 1] = id
      end
    end
    if #obj.items == 0 then return nil end
  elseif spec.objectType == "itemball" then
    if not (spec.item and self.data.items and self.data.items[spec.item]) then
      return nil
    end
    obj.object_type = "item"
    obj.item = spec.item
    if spec.hidden then
      -- Invisible find (engine objectVisible hides hidden placements until
      -- the pickup ledger marks them taken).
      obj.hidden = true
    end
  elseif spec.objectType == "npc" then
    -- Generic NPC: healing entities carry the healing flag so the talk
    -- handler triggers nurseHeal() instead of a text box.
    if spec.healing then
      obj.healing = true
      obj.label = obj.label or "Healer"
    end
    if type(spec.prizeItem) == "string"
        and self.data.items and self.data.items[spec.prizeItem] then
      obj.prizeItem = spec.prizeItem
    end
  elseif spec.objectType == "none" then
    -- Bare placement: no type-specific payload, just the label.
  end
  local spriteId = spec.sprite
  if obj.object_type == "item" and not spriteId then
    spriteId = "SPRITE_POKE_BALL"
  end
  if spriteId and self.data.sprites and self.data.sprites[spriteId] then
    obj.sprite = spriteId
  end
  local nextIndex = EditOps.nextIndex(self.def.objects or {})
  obj.index = nextIndex
  if not obj.text or obj.text == "" then
    obj.text = "..."
  end
  if obj.blocker then
    -- Marker text: the key registerTalkTexts binds the wild-battle handler
    -- to.  Unique per placement so two blockers never share a handler.
    obj.text = "\1BLK:" .. tostring(self.mapId) .. ":" .. tostring(obj.index)
  end
  if obj.healing then
    -- Marker text: registerTalkTexts binds the nurseHeal handler to this key.
    obj.text = "\1HEAL:" .. tostring(self.mapId) .. ":" .. tostring(obj.index)
  end
  if obj.prizeItem and not obj.text then
    -- Gift-item NPCs with no dialog still need a talk handler to hand over
    -- the item; generate a unique marker key.
    obj.text = "\1GIFT:" .. tostring(self.mapId) .. ":" .. tostring(obj.index)
  end
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
  local nextIndex = EditOps.nextIndex(def.objects)
  table.insert(def.objects, {
    x = tx, y = ty,
    sprite = spriteId,
    index = nextIndex,
    object_type = "NPC",
    movement = "STAY",
    range = "DOWN",
    isTrainer = false,
    trainerClass = nil,
    script = nil,
    item = nil,
    text = "...",
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
  local nextIndex = EditOps.nextIndex(def.objects)
  table.insert(def.objects, {
    x = tx, y = ty,
    sprite = "SPRITE_POKE_BALL",
    index = nextIndex,
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