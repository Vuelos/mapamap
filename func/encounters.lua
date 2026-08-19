-- Encounter editing operations: read/write wild Pokemon encounter data
-- (grass, water, indoor) for the current map.
--
-- Encounters live in Data.encounters[mapId] with the shape:
--   { grass = { rate = N, slots = [{species, level}, ...] },
--     water = { ... }, indoor = { ... } }

local Encounters = {}

local GROUPS = { "grass", "water", "indoor" }
local MAX_SLOTS = 10
local MAX_RATE = 100

-- Returns the encounter table for the current map, or nil.
function Encounters:getEncounters()
  local data = self.data
  return data and data.encounters and data.encounters[self.mapId]
end

-- Returns a specific group (grass/water/indoor), or nil.
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
-- encounter table (always non-nil after this call).
function Encounters:ensureEncounters()
  local data = self.data
  if not data then return nil end
  data.encounters = data.encounters or {}
  local enc = data.encounters[self.mapId]
  if not enc then
    enc = { grass = { rate = 25, slots = {} } }
    for i = 1, 10 do
      table.insert(enc.grass.slots, { level = 5, species = "PIDGEY" })
    end
    data.encounters[self.mapId] = enc
    self.mapChanged = true
  end
  return enc
end

-- Sets the encounter rate for a group (clamped 0..255).
function Encounters:setEncounterRate(groupKey, rate)
  local enc = self:ensureEncounters()
  if not enc or not enc[groupKey] then return false end
  local v = math.max(0, math.min(tonumber(rate) or 0, MAX_RATE))
  if v == enc[groupKey].rate then return false end
  if self.undo then self.undo:capture(self.def) end
  enc[groupKey].rate = v
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
  self.mapChanged = true
  return true
end

-- Adds a new slot to a group (copies the last slot or creates a default).
function Encounters:addEncounterSlot(groupKey)
  local enc = self:ensureEncounters()
  if not enc then return false end
  if not enc[groupKey] then
    enc[groupKey] = { rate = 25, slots = {} }
  end
  local group = enc[groupKey]
  if #group.slots >= MAX_SLOTS then return false end
  if self.undo then self.undo:capture(self.def) end
  local last = group.slots[#group.slots]
  table.insert(group.slots, {
    species = last and last.species or "PIDGEY",
    level = last and last.level or 5,
  })
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
