-- Encounter editing operations: read/write wild Pokemon encounter data
-- (grass, water, indoor) for the current map.
--
-- Gen1: Encounters live in Data.encounters[mapId] with the shape:
--   { grass = { rate = N, slots = [{species, level}, ...] },
--     water = { ... }, indoor = { ... } }
--
-- Gen2: Encounters live in Data.gen2Encounters (proxied as Data.encounters)
-- with a per-kind structure:
--   encounters.grass[mapId] = { rates = {MORN, DAY, NITE},
--                                slots = {MORN=[7], DAY=[7], NITE=[7]} }
--   encounters.water[mapId] = { rate = N, slots = [3] }
--
-- The editor normalises gen2 data into the gen1 flat format on read and
-- writes back to gen2 on mutation.  Group keys for gen2:
--   "grass_morn", "grass_day", "grass_nite" (grass tabs), "water", "indoor"

local Encounters = {}

local Gen = require("mods.mapamap.engine.gen")

local GROUPS_GEN1 = { "grass", "water", "indoor" }
local GROUPS_GEN2 = { "grass_morn", "grass_day", "grass_nite", "water", "indoor" }
local MAX_SLOTS_GEN1 = 10
local MAX_SLOTS_GEN2_GRASS = 7
local MAX_SLOTS_GEN2_WATER = 3
local MAX_RATE = 100

local TIME_KEYS = { grass_morn = "MORN", grass_day = "DAY", grass_nite = "NITE" }

-- Returns the list of group keys for the current generation.
function Encounters:groups()
  return Gen.isGen2() and GROUPS_GEN2 or GROUPS_GEN1
end

-- Normalise a gen2 encounter entry to the flat { rate, slots } format.
local function gen2ToFlat(entry, timeKey)
  if not entry then return nil end
  if timeKey then
    local rates = entry.rates or {}
    local slots = entry.slots or {}
    return { rate = rates[timeKey] or 0, slots = slots[timeKey] or {} }
  end
  return { rate = entry.rate or 0, slots = entry.slots or {} }
end

-- Detect whether the encounter table uses gen2 shape (top-level "grass" key
-- whose children are mapIds) or gen1 shape (top-level mapIds whose children
-- have a "grass" field).
local function isGen2Shape(enc)
  if not enc then return false end
  -- Gen2 grass does not have 'rate' at the top level; Gen1 grass has 'rate' field.
  return not (enc.grass and enc.grass.rate ~= nil)
end

-- Sync the cached flat table back to gen2 source data.
-- Handles both gen2-shaped (src.grass[mapId]) and gen1-shaped (src[mapId].grass) data.
local function writeBackGen2(self)
  local flat = self._encFlat
  if not flat then return end
  local data = self.data
  local src = data and data.encounters
  if not src then return end
  local mapId = self.mapId
  if isGen2Shape(src) then
    -- Gen2 shape: src.grass[mapId] = { rates = {MORN...}, slots = {MORN={...}} }
    local grassSrc = src.grass and src.grass[mapId]
    if grassSrc then
      for gk, tk in pairs(TIME_KEYS) do
        local f = flat[gk]
        if f then
          if not grassSrc.rates then grassSrc.rates = {} end
          grassSrc.rates[tk] = f.rate or 0
          if not grassSrc.slots then grassSrc.slots = {} end
          grassSrc.slots[tk] = f.slots or {}
        end
      end
    end
    local waterFlat = flat.water
    if waterFlat and src.water and src.water[mapId] then
      src.water[mapId].rate = waterFlat.rate or 0
      src.water[mapId].slots = waterFlat.slots or {}
    end
  else
    -- Gen1 shape: src[mapId] = { grass = { rate, slots }, water = { rate, slots } }
    local entry = src[mapId]
    if entry then
      if flat.grass_morn and entry.grass then
        entry.grass.rate = flat.grass_morn.rate or 0
        entry.grass.slots = flat.grass_morn.slots or {}
      end
      if flat.water and entry.water then
        entry.water.rate = flat.water.rate or 0
        entry.water.slots = flat.water.slots or {}
      end
    end
  end
end

-- Read the flat encounter table for the current map.
-- For gen2, caches the result on self._encFlat so mutations persist.
-- Handles both gen2-shaped and gen1-shaped source data.
function Encounters:getEncounters()
  local data = self.data
  if not data then return nil end
  local mapId = self.mapId

  if Gen.isGen2() then
    -- Return cached flat table if available (mutations live here).
    if self._encFlat and self._encMapId == mapId then
      return self._encFlat
    end
    local enc = data.encounters
    if not enc then return nil end
    local flat = {}
    if isGen2Shape(enc) then
      flat.grass_morn = gen2ToFlat(enc.grass[mapId], "MORN")
      flat.grass_day  = gen2ToFlat(enc.grass[mapId], "DAY")
      flat.grass_nite = gen2ToFlat(enc.grass[mapId], "NITE")
      flat.water = gen2ToFlat(enc.water and enc.water[mapId])
    else
      -- Gen1-shaped data loaded in gen2 mode: top-level keys are mapIds
      -- with { grass = { rate, slots } } underneath.
      local entry = enc[mapId]
      if entry and entry.grass then
        flat.grass_morn = { rate = entry.grass.rate or 0, slots = entry.grass.slots or {} }
        flat.grass_day  = { rate = entry.grass.rate or 0, slots = entry.grass.slots or {} }
        flat.grass_nite = { rate = entry.grass.rate or 0, slots = entry.grass.slots or {} }
      end
      if entry and entry.water then
        flat.water = { rate = entry.water.rate or 0, slots = entry.water.slots or {} }
      end
    end
    flat.indoor = flat.indoor or { rate = 0, slots = {} }
    self._encFlat = flat
    self._encMapId = mapId
    return flat
  end

  return data.encounters and data.encounters[mapId]
end

-- Returns a specific group (e.g. "grass", "grass_morn", "water", "indoor"),
-- or nil if the map has no encounter data.
function Encounters:getEncounterGroup(groupKey)
  local enc = self:getEncounters()
  return enc and enc[groupKey]
end

-- Ensures a specific encounter group exists.  Creates it with rate=0 and
-- no slots if absent.  Returns the group (always non-nil after this call).
function Encounters:ensureEncounterGroup(groupKey)
  local enc = self:ensureEncounters()
  if not enc then return nil end
  if not enc[groupKey] then
    enc[groupKey] = { rate = 0, slots = {} }
    self.mapChanged = true
  end
  return enc[groupKey]
end

-- Ensures encounter data exists for the current map.  Returns the
-- flat encounter table (always non-nil after this call).
function Encounters:ensureEncounters()
  local data = self.data
  if not data then return nil end
  local mapId = self.mapId

  if Gen.isGen2() then
    data.encounters = data.encounters or {}
    local src = data.encounters
    if isGen2Shape(src) then
      -- Gen2 shape: src.grass[mapId] = { rates = {...}, slots = {...} }
      src.grass = src.grass or {}
      if not src.grass[mapId] then
        src.grass[mapId] = {
          rates = { MORN = 25, DAY = 25, NITE = 25 },
          slots = { MORN = {}, DAY = {}, NITE = {} },
        }
        self.mapChanged = true
      end
      src.water = src.water or {}
      if not src.water[mapId] then
        src.water[mapId] = { rate = 0, slots = {} }
        self.mapChanged = true
      end
    else
      -- Gen1 shape: src[mapId] = { grass = { rate, slots } }
      if not src[mapId] then
        src[mapId] = { grass = { rate = 25, slots = {} } }
        self.mapChanged = true
      end
      -- Ensure water sub-entry exists.
      if not src[mapId].water then
        src[mapId].water = { rate = 0, slots = {} }
        self.mapChanged = true
      end
    end
    -- Invalidate cache so getEncounters() rebuilds from source.
    self._encFlat = nil
    return self:getEncounters()
  end

  -- Gen1 path.
  data.encounters = data.encounters or {}
  local enc = data.encounters[mapId]
  if not enc then
    enc = { grass = { rate = 25, slots = {} } }
    for i = 1, 10 do
      table.insert(enc.grass.slots, { level = 5, species = "PIDGEY" })
    end
    data.encounters[mapId] = enc
    self.mapChanged = true
  end
  return enc
end

-- Sets the encounter rate for a group (clamped 0..MAX_RATE).
function Encounters:setEncounterRate(groupKey, rate)
  local enc = self:ensureEncounters()
  if not enc or not enc[groupKey] then return false end
  local v = math.max(0, math.min(tonumber(rate) or 0, MAX_RATE))
  if v == enc[groupKey].rate then return false end
  if self.undo then self.undo:capture(self.def) end
  enc[groupKey].rate = v
  writeBackGen2(self)
  self.mapChanged = true
  return true
end

-- Sets the species for a slot in a group.
function Encounters:setEncounterSlotSpecies(groupKey, slotIdx, species)
  local enc = self:getEncounterGroup(groupKey)
  if not enc or not enc.slots then return false end
  local slot = enc.slots[slotIdx]
  if not slot then return false end
  if not species or species == "" then return false end
  if self.undo then self.undo:capture(self.def) end
  slot.species = species:upper()
  writeBackGen2(self)
  self.mapChanged = true
  return true
end

-- Sets the level for a slot in a group (clamped 1..100).
function Encounters:setEncounterSlotLevel(groupKey, slotIdx, level)
  local enc = self:getEncounterGroup(groupKey)
  if not enc or not enc.slots then return false end
  local slot = enc.slots[slotIdx]
  if not slot then return false end
  local v = math.max(1, math.min(tonumber(level) or 1, 100))
  if v == slot.level then return false end
  if self.undo then self.undo:capture(self.def) end
  slot.level = v
  writeBackGen2(self)
  self.mapChanged = true
  return true
end

-- Adds a new slot to a group (copies the last slot or creates a default).
function Encounters:addEncounterSlot(groupKey)
  local enc = self:ensureEncounters()
  if not enc then return false end
  if not enc[groupKey] then
    enc[groupKey] = { rate = 0, slots = {} }
  end
  local group = enc[groupKey]
  local maxSlots = Gen.isGen2()
    and (TIME_KEYS[groupKey] and MAX_SLOTS_GEN2_GRASS or MAX_SLOTS_GEN2_WATER)
    or MAX_SLOTS_GEN1
  if #group.slots >= maxSlots then return false end
  if self.undo then self.undo:capture(self.def) end
  local last = group.slots[#group.slots]
  table.insert(group.slots, {
    species = last and last.species or "PIDGEY",
    level = last and last.level or 5,
  })
  writeBackGen2(self)
  self.mapChanged = true
  return true
end

-- Removes a slot from a group.
function Encounters:removeEncounterSlot(groupKey, slotIdx)
  local enc = self:getEncounterGroup(groupKey)
  if not enc or not enc.slots then return false end
  if slotIdx < 1 or slotIdx > #enc.slots then return false end
  if self.undo then self.undo:capture(self.def) end
  table.remove(enc.slots, slotIdx)
  writeBackGen2(self)
  self.mapChanged = true
  return true
end

-- Builds a sorted list of species IDs from data.pokemon.
function Encounters:speciesList()
  local data = self.data
  if not data or not data.pokemon then return {} end
  local keys = {}
  for k, v in pairs(data.pokemon) do
    if type(v) == "table" and v.dex then keys[#keys + 1] = k end
  end
  table.sort(keys)
  return keys
end

return Encounters
