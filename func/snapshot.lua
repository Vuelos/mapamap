-- Snapshot/restore/diff for map editor state.
-- Captures the editable fields of a map definition, restores them,
-- and computes a minimal diff patch against a prior snapshot.

local Common = require("mods.mapamap.func.common")

local Snapshot = {}

local SNAPSHOT_FIELDS = {
  "blocks", "warps", "objects", "signs",
  "borderBlock", "width", "height", "name",
  "textDefs", "connections", "connectionsExtra",
}

function Snapshot.capture(def)
  local snap = {}
  for _, key in ipairs(SNAPSHOT_FIELDS) do
    snap[key] = Common.deepCopy(def[key])
  end
  snap.width = def.width
  snap.height = def.height
  snap.borderBlock = def.borderBlock
  snap.name = def.name
  return snap
end

function Snapshot.restore(def, snap)
  for _, key in ipairs(SNAPSHOT_FIELDS) do
    def[key] = Common.deepCopy(snap[key])
  end
  def.width = snap.width
  def.height = snap.height
  def.borderBlock = snap.borderBlock
  def.name = snap.name
end

function Snapshot.diff(def, snap)
  local patch = {}
  for _, key in ipairs(SNAPSHOT_FIELDS) do
    if not Common.tablesEqual(def[key], snap[key]) then
      patch[key] = Common.deepCopy(def[key])
    end
  end
  if def.width ~= snap.width then patch.width = def.width end
  if def.height ~= snap.height then patch.height = def.height end
  if def.borderBlock ~= snap.borderBlock then patch.borderBlock = def.borderBlock end
  if def.name ~= snap.name then patch.name = def.name end
  return patch
end

return Snapshot