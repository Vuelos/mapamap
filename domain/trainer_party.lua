-- Trainer party (enemy team) editing: the shared class#party tables in
-- data.trainers plus per-placement overrides.
--
-- Two scopes, both consumed by the engine live:
--   * SHARED  -- data.trainers[class].parties[n] is read straight from data at
--     battle start (src/battle/BattleState.lua newTrainer; gen 2 resolves the
--     same tables through World:trainerParty), so mutating a slot changes every
--     battle that uses this class#party.  Edits are recorded whole into the
--     mod save (save_keys.TRAINER_PARTIES) and replayed over data.trainers on
--     save.loaded, battles or not.
--   * CUSTOM  -- obj.customParty on a placed battler's def.  The engine hook
--     "trainer.party" fires with (class, partyIndex, party) at battle start;
--     controllers/battle_link.lua captures the engaged NPC from the
--     world.trainer_engaged event and hands back the object's own roster, so
--     only THIS placement fights the custom team.  The field rides the normal
--     map-def diff persistence.
--
-- Party slots are { species = id, level = 1..100, moves = nil | {id,...} }.
-- A nil moves list keeps the ROM-defined moves for that slot.

local Common = require("mods.mapamap.common")
local Keys = require("mods.mapamap.storage.save_keys")

local TrainerParty = {}

TrainerParty.MAX_SLOTS = 6

-- ---------------------------------------------------------------------------
-- Read helpers

-- The live shared party table for class#partyIndex (a reference, not a copy),
-- or nil when the class / party does not exist.
function TrainerParty:partyFor(class, partyIndex)
  local tdef = class and self.data and self.data.trainers
    and self.data.trainers[class]
  if not (tdef and tdef.parties) then return nil end
  return tdef.parties[partyIndex or 1]
end

-- The effective team behind an editor target: an object's customParty when it
-- carries one, else the shared class#party table.  Returns table, isCustom.
function TrainerParty:effectiveParty(obj, class, partyIndex)
  if obj and obj.customParty and #obj.customParty > 0 then
    return obj.customParty, true
  end
  return self:partyFor(class, partyIndex), false
end

-- Latest-4 learnable moves for species+level (engine learn_move behavior), or
-- nil when the species has no usable learnset.  pcall'd so headless/stub data
-- degrades to "no auto moves" instead of raising.
function TrainerParty.autoMoveset(data, speciesId, level)
  local def = data and data.pokemon and data.pokemon[speciesId]
  if not (def and def.learnset) then return nil end
  local ok, Pokemon = pcall(require, "src.pokemon.Pokemon")
  if not ok then return nil end
  local okM, moves = pcall(Pokemon.movesAtLevel, def, level or 1)
  if not okM then return nil end
  return moves
end

-- Validates one desired slot against the data tables; returns a clean row
-- { species, level, moves? } or nil + reason.
function TrainerParty.validateSlot(self, slot)
  if type(slot) ~= "table" then return nil, "not a team slot" end
  if not (slot.species and self.data.pokemon and self.data.pokemon[slot.species]) then
    return nil, "unknown species " .. tostring(slot.species)
  end
  local level = math.max(1, math.min(tonumber(slot.level) or 1, 100))
  local row = { species = slot.species, level = level }
  if type(slot.moves) == "table" and #slot.moves > 0 then
    local moves = {}
    for _, mv in ipairs(slot.moves) do
      if not (self.data.moves and self.data.moves[mv]) then
        return nil, "unknown move " .. tostring(mv)
      end
      moves[#moves + 1] = mv
    end
    row.moves = moves
  end
  return row
end

-- ---------------------------------------------------------------------------
-- Shared-party mutations (recorded into the mod save on every write)

-- Persists the whole edited party under its class#partyIndex key.
local function recordShared(self, class, partyIndex, party)
  local mod = self.mod
  if not (mod and mod.save) then return end
  local all = mod.save:get(Keys.TRAINER_PARTIES) or {}
  all[class] = all[class] or {}
  all[class][tostring(partyIndex or 1)] = Common.deepCopy(party)
  mod.save:set(Keys.TRAINER_PARTIES, all)
end

-- Writes patch fields ({species?, level?, moves?|false}) onto shared slot
-- `slotIdx`.  Returns true when anything changed.
function TrainerParty:setTrainerPartyMember(class, partyIndex, slotIdx, patch)
  local party = self:partyFor(class, partyIndex)
  local slot = party and party[slotIdx]
  if not slot then return false end
  if patch.species ~= nil and patch.species ~= slot.species then
    if not (self.data.pokemon and self.data.pokemon[patch.species]) then
      return false
    end
    slot.species = patch.species
  end
  if patch.level ~= nil then
    local lvl = math.max(1, math.min(math.floor(tonumber(patch.level)
      or tonumber(slot.level) or 1), 100))
    if lvl ~= slot.level then
      slot.level = lvl
    end
  end
  if patch.moves ~= nil then
    if patch.moves == false then
      slot.moves = nil
    elseif type(patch.moves) == "table" then
      local moves = {}
      for _, mv in ipairs(patch.moves) do
        if not (self.data.moves and self.data.moves[mv]) then return false end
        moves[#moves + 1] = mv
      end
      slot.moves = #moves > 0 and moves or nil
    end
  end
  recordShared(self, class, partyIndex, party)
  return true
end

-- Appends an empty-ish slot (first species, level 5) while under the cap.
function TrainerParty:addTrainerPartySlot(class, partyIndex)
  local tdef = class and self.data and self.data.trainers
    and self.data.trainers[class]
  local parties = tdef and tdef.parties
  if not parties then return false end
  local idx = partyIndex or 1
  parties[idx] = parties[idx] or {}
  local party = parties[idx]
  if #party >= TrainerParty.MAX_SLOTS then return false end
  local first
  for sid in pairs(self.data.pokemon or {}) do first = sid break end
  party[#party + 1] = { species = first, level = 5 }
  recordShared(self, class, idx, party)
  return true
end

-- Removes slot `slotIdx`; never shrinks a party below one member.
function TrainerParty:removeTrainerPartySlot(class, partyIndex, slotIdx)
  local party = self:partyFor(class, partyIndex)
  if not party or not party[slotIdx] or #party <= 1 then return false end
  table.remove(party, slotIdx)
  recordShared(self, class, partyIndex, party)
  return true
end

-- Moves slot `slotIdx` by delta (-1 up / +1 down) within the party.
function TrainerParty:moveTrainerPartySlot(class, partyIndex, slotIdx, delta)
  local party = self:partyFor(class, partyIndex)
  if not party then return false end
  local to = slotIdx + delta
  if slotIdx < 1 or slotIdx > #party or to < 1 or to > #party then
    return false
  end
  party[slotIdx], party[to] = party[to], party[slotIdx]
  recordShared(self, class, partyIndex, party)
  return true
end

-- ---------------------------------------------------------------------------
-- Per-placement custom teams (obj.customParty)

-- Sets or clears a placed battler's own roster.  Passing nil reverts the
-- placement to the shared class#party team.
function TrainerParty:setObjectCustomParty(obj, party)
  if not (obj and obj.trainerClass) then return false end
  if party == nil then
    if obj.customParty == nil then return false end
    if self.undo then self.undo:capture(self.def) end
    obj.customParty = nil
    self.mapChanged = true
    return true
  end
  if type(party) ~= "table" or #party == 0 then return false end
  if #party > TrainerParty.MAX_SLOTS then return false end
  local rows = {}
  for _, s in ipairs(party) do
    local row, err = TrainerParty.validateSlot(self, s)
    if not row then
      self._lastTeamError = err
      return false
    end
    rows[#rows + 1] = row
  end
  if self.undo then self.undo:capture(self.def) end
  obj.customParty = rows
  self.mapChanged = true
  return true
end

-- Patches one slot of an existing custom roster ({species?, level?,
-- moves?|false}); the roster must already exist (build it with
-- setObjectCustomParty first).
function TrainerParty:setObjectCustomPartyMember(obj, slotIdx, patch)
  if not (obj and obj.customParty and obj.customParty[slotIdx]) then
    return false
  end
  local merged = {}
  for i, row in ipairs(obj.customParty) do
    merged[i] = (i == slotIdx) and
      { species = row.species, level = row.level,
        moves = row.moves and Common.deepCopy(row.moves) or nil } or row
  end
  local target = merged[slotIdx]
  if patch.species ~= nil then target.species = patch.species end
  if patch.level ~= nil then
    target.level = math.max(1, math.min(math.floor(tonumber(patch.level)
      or target.level or 1), 100))
  end
  if patch.moves ~= nil then
    target.moves = (patch.moves == false) and nil
      or (type(patch.moves) == "table" and Common.deepCopy(patch.moves) or nil)
  end
  -- validateSlot checks the WHOLE row, so rebuild the candidate row list.
  local rows = {}
  for _, row in ipairs(merged) do
    local clean, err = TrainerParty.validateSlot(self, row)
    if not clean then
      self._lastTeamError = err
      return false
    end
    rows[#rows + 1] = clean
  end
  if self.undo then self.undo:capture(self.def) end
  obj.customParty = rows
  self.mapChanged = true
  return true
end

-- Adds / removes / reorders slots of an object's custom roster directly
-- (mirrors the shared mutators without touching the mod-save bucket).
function TrainerParty:addObjectCustomPartySlot(obj)
  if not (obj and obj.customParty) then return false end
  if #obj.customParty >= TrainerParty.MAX_SLOTS then return false end
  local first
  for sid in pairs(self.data.pokemon or {}) do first = sid break end
  if self.undo then self.undo:capture(self.def) end
  table.insert(obj.customParty, { species = first, level = 5 })
  self.mapChanged = true
  return true
end

function TrainerParty:removeObjectCustomPartySlot(obj, slotIdx)
  if not (obj and obj.customParty) then return false end
  if not obj.customParty[slotIdx] or #obj.customParty <= 1 then return false end
  if self.undo then self.undo:capture(self.def) end
  table.remove(obj.customParty, slotIdx)
  self.mapChanged = true
  return true
end

function TrainerParty:moveObjectCustomPartySlot(obj, slotIdx, delta)
  if not (obj and obj.customParty) then return false end
  local to = slotIdx + delta
  if slotIdx < 1 or slotIdx > #obj.customParty
      or to < 1 or to > #obj.customParty then
    return false
  end
  if self.undo then self.undo:capture(self.def) end
  local party = obj.customParty
  party[slotIdx], party[to] = party[to], party[slotIdx]
  self.mapChanged = true
  return true
end

-- ---------------------------------------------------------------------------
-- Replay (no session): applies saved shared-party edits over data.trainers.
-- Returns the number of parties applied.

function TrainerParty.replayInto(data, saved)
  if not (data and data.trainers and saved) then return 0 end
  local n = 0
  for class, byIdx in pairs(saved) do
    local tdef = data.trainers[class]
    if tdef and tdef.parties and type(byIdx) == "table" then
      for idxStr, party in pairs(byIdx) do
        local i = tonumber(idxStr)
        if i and type(party) == "table" and #party > 0 then
          tdef.parties[i] = Common.deepCopy(party)
          n = n + 1
        end
      end
    end
  end
  return n
end

return TrainerParty
