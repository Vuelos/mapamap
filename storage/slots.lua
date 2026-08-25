-- Map-slot persistence: named snapshots of the whole mapamap edit-set.
--
-- A slot captures every persisted edit bucket at once -- block patches,
-- encounter patches, connection patches, whole created maps and trainer
-- parties -- under a user-facing name in the mod save (Keys.SLOTS), so the
-- overlay's Map Slots panel can store the current work under one name and
-- swap between stored sets later (SessionManager.activateSlot).
--
-- Slots are also files: export writes <mod>/export/<name>.lua next to the
-- mod source (shareable like map_edits/patches.lua), import reads such a
-- file back into the slot list.  Serialization uses the SaveSerializer
-- grammar; the absolute-path writer is shared with patch_saver's bulk
-- export.

local Common = require("mods.mapamap.common")
local Save = require("mods.mapamap.storage.patch_saver")
local Keys = require("mods.mapamap.storage.save_keys")
local SaveSerializer = require("src.core.SaveSerializer")

local Slots = {}

-- The auto-backup slot: LOAD stashes the live edit-set here before swapping,
-- so activating a slot without a prior SAVE is always recoverable.
Slots.PREVIOUS = "previous"

-- Every bucket that makes up a complete edit-set snapshot.  `field` names
-- the record entry, `key` the mod-save bucket it mirrors.
local BUCKETS = {
  { field = "patches",        key = Keys.PATCHES },
  { field = "encounters",     key = Keys.ENCOUNTER_PATCHES },
  { field = "connections",    key = Keys.CONNECTION_PATCHES },
  { field = "newMaps",        key = Keys.NEW_MAPS },
  { field = "trainerParties", key = Keys.TRAINER_PARTIES },
}

-- All stored slots ({ [name] = record }).
function Slots.all(mod)
  return mod.save:get(Keys.SLOTS, {})
end

-- Sorted slot-name list.  The auto "previous" backup sorts last so it never
-- displaces a user slot from the panel's first rows.
function Slots.names(mod)
  local out = {}
  for name in pairs(Slots.all(mod)) do out[#out + 1] = name end
  table.sort(out, function(a, b)
    if (a == Slots.PREVIOUS) ~= (b == Slots.PREVIOUS) then
      return b == Slots.PREVIOUS
    end
    return a < b
  end)
  return out
end

function Slots.get(mod, name)
  if not name then return nil end
  return Slots.all(mod)[name]
end

-- Deep-copies the live edit-set into a snapshot record.  The copies are the
-- point: later edits to the live buckets must never mutate a stored slot.
function Slots.capture(mod)
  local rec = { format = "mapamap-slot", savedAt = os.time() }
  for _, b in ipairs(BUCKETS) do
    rec[b.field] = Common.deepCopy(mod.save:get(b.key, {}))
  end
  return rec
end

local function writeRecord(mod, name, rec)
  local all = Slots.all(mod)
  all[name] = rec
  mod.save:set(Keys.SLOTS, all)
  return rec
end

-- Captures the current edit-set under `name` (overwriting any old content).
function Slots.store(mod, name)
  if not (mod and name and name ~= "") then return nil end
  return writeRecord(mod, name, Slots.capture(mod))
end

function Slots.delete(mod, name)
  if not Slots.get(mod, name) then return false end
  local all = Slots.all(mod)
  all[name] = nil
  mod.save:set(Keys.SLOTS, all)
  return true
end

-- Renames a stored slot.  Refuses missing sources, empty targets and
-- targets that already hold another slot.
function Slots.rename(mod, from, to)
  local rec = Slots.get(mod, from)
  if not rec then return false, "no slot named " .. tostring(from) end
  if not (to and to ~= "") then return false, "empty slot name" end
  if to == from then return true end
  if Slots.get(mod, to) then return false, "slot " .. tostring(to) .. " exists" end
  local all = Slots.all(mod)
  all[from] = nil
  all[to] = rec
  mod.save:set(Keys.SLOTS, all)
  return true
end

-- Default slot name: a YY.MM.DD.HH.MM.SS timestamp of the capture moment
-- (export files inherit it, since they are written as <name>.lua).
-- Same-second collisions step forward one second at a time so the suggested
-- name stays inside the format and is always free.
function Slots.nextName(mod)
  local taken = Slots.all(mod)
  local t = os.time()
  local name = os.date("%y.%m.%d.%H.%M.%S", t)
  while taken[name] do
    t = t + 1
    name = os.date("%y.%m.%d.%H.%M.%S", t)
  end
  return name
end

-- Writes the five live buckets wholesale from a slot record.  Activation is
-- a FULL replacement of the edit-set, never a merge: buckets the record
-- carries as {} clear their live counterpart too.
function Slots.applyBuckets(mod, record)
  if not (mod and record) then return false end
  for _, b in ipairs(BUCKETS) do
    mod.save:set(b.key, Common.deepCopy(record[b.field] or {}))
  end
  return true
end

-- ------- export / import (mods/<mod>/export/<name>.lua)

-- PhysFS-relative folder the export files live in.
function Slots.dirRel(mod)
  return (mod.path or "mods/mapamap") .. "/export"
end

-- Absolute filesystem path of one export file (nil when no game source
-- folder could be located, e.g. fused builds without getSource).
function Slots.exportPath(mod, name)
  local root = Save.sourceRootDir and Save.sourceRootDir()
  if not root then return nil end
  return root .. "/" .. Slots.dirRel(mod) .. "/" .. name .. ".lua"
end

-- Writes the named slot to mods/<mod>/export/<name>.lua.  Returns the path,
-- or nil + an error message.
function Slots.export(mod, name)
  local rec = Slots.get(mod, name)
  if not rec then return nil, "no slot named " .. tostring(name) end
  local path = Slots.exportPath(mod, name)
  if not path then return nil, "could not locate the game source folder" end
  local ok, err = pcall(Save.writeSourceFile, path, SaveSerializer.encode(rec))
  if not ok then return nil, tostring(err) end
  return path
end

-- File names (.lua) available in the export folder, sorted.
function Slots.files(mod)
  local items = love.filesystem.getDirectoryItems(Slots.dirRel(mod)) or {}
  local out = {}
  for _, f in ipairs(items) do
    if type(f) == "string" and f:match("%.lua$") then out[#out + 1] = f end
  end
  table.sort(out)
  return out
end

-- Slot name an export file imports under ("my map.lua" -> "my map").
function Slots.nameForFile(fileName)
  return tostring(fileName or ""):gsub("%.lua$", "")
end

-- Reads one export file back into the slot list under its file name.
-- love.filesystem reaches the game source on normal runs; the raw-io path
-- covers environments where only the absolute location is readable.
-- Returns the imported slot name, or nil + an error message.
function Slots.import(mod, fileName)
  local rel = Slots.dirRel(mod) .. "/" .. fileName
  local raw = love.filesystem and love.filesystem.read
    and love.filesystem.read(rel)
  if not raw then
    local path = Slots.exportPath(mod, Slots.nameForFile(fileName))
    local f = path and io.open(path, "rb")
    if f then raw = f:read("*a"); f:close() end
  end
  if not raw then return nil, "export/" .. tostring(fileName) .. " not found" end
  local rec, err = SaveSerializer.decode(raw)
  if not rec then return nil, tostring(err) end
  local name = Slots.nameForFile(fileName)
  if name == "" then return nil, "bad export file name" end
  writeRecord(mod, name, rec)
  return name
end

return Slots
