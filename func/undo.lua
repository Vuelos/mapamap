-- In-memory undo/redo system for the map editor.
-- Supports both full snapshots (backward compatible) and
-- delta-based snapshots for memory efficiency on large maps.
-- Delta snapshots store only changed block indices with their
-- old and new values, while still deep-copying entities and
-- dimensions as full snapshots.

local Undo = {}
Undo.__index = Undo

local MAX_UNDO = 50

local function deepCopy(t)
  if type(t) ~= "table" then return t end
  local out = {}
  for k, v in pairs(t) do out[k] = deepCopy(v) end
  return out
end

function Undo.new()
  return setmetatable({
    _undoStack = {},
    _redoStack = {},
  }, Undo)
end

-- Captures a full snapshot of the map definition state.
-- Must be called BEFORE any mutation.  `recip` (when given) is a table of
-- mapId -> connections used to restore connected maps' reciprocal connection
-- offsets when a map expand is undone.
function Undo:captureFull(def, shiftL, shiftT, mapId, recip)
  table.insert(self._undoStack, {
    blocks      = deepCopy(def.blocks),
    warps       = deepCopy(def.warps),
    objects     = deepCopy(def.objects),
    signs       = deepCopy(def.signs),
    connections = deepCopy(def.connections),
    width       = def.width,
    height      = def.height,
    borderBlock = def.borderBlock,
    shiftL      = shiftL,
    shiftT      = shiftT,
    mapId       = mapId,
    recip       = recip,
    _full = true,
  })
  if #self._undoStack > MAX_UNDO then
    table.remove(self._undoStack, 1)
  end
  self._redoStack = {}
end

-- Captures a delta snapshot: only stores changed block indices
-- with their old and new values.  Caller must pass the old values
-- (pre-mutation) and the changed indices.  Entities and dimensions
-- are still deep-copied in full.
function Undo:captureDelta(def, shiftL, shiftT, mapId, changedIndices, oldValues)
  local blockDelta = {}
  for i, idx in ipairs(changedIndices) do
    blockDelta[idx] = { old = oldValues[i], new = def.blocks[idx] }
  end
  table.insert(self._undoStack, {
    blocks      = blockDelta,
    warps       = deepCopy(def.warps),
    objects     = deepCopy(def.objects),
    signs       = deepCopy(def.signs),
    connections = deepCopy(def.connections),
    width       = def.width,
    height      = def.height,
    borderBlock = def.borderBlock,
    shiftL      = shiftL,
    shiftT      = shiftT,
    mapId       = mapId,
    _full = false,
  })
  if #self._undoStack > MAX_UNDO then
    table.remove(self._undoStack, 1)
  end
  self._redoStack = {}
end

-- Backward-compatible capture: if changedIndices is provided, uses
-- delta mode; otherwise uses full snapshot mode.
function Undo:capture(def, shiftL, shiftT, mapId, changedIndices, oldValues)
  if changedIndices then
    self:captureDelta(def, shiftL, shiftT, mapId, changedIndices, oldValues)
  else
    self:captureFull(def, shiftL, shiftT, mapId)
  end
end

local function snapshotOf(def, shiftL, shiftT, mapId, recip)
  return {
    blocks      = deepCopy(def.blocks),
    warps       = deepCopy(def.warps),
    objects     = deepCopy(def.objects),
    signs       = deepCopy(def.signs),
    connections = deepCopy(def.connections),
    width       = def.width,
    height      = def.height,
    borderBlock = def.borderBlock,
    shiftL      = shiftL,
    shiftT      = shiftT,
    mapId       = mapId,
    recip       = recip,
    _full = true,
  }
end

local function applyFull(def, snapshot)
  for i, v in ipairs(snapshot.blocks) do def.blocks[i] = v end
  for i = #snapshot.blocks + 1, #def.blocks do def.blocks[i] = nil end
  def.warps       = deepCopy(snapshot.warps)
  def.objects     = deepCopy(snapshot.objects)
  def.signs       = deepCopy(snapshot.signs)
  def.connections = deepCopy(snapshot.connections)
  def.width       = snapshot.width
  def.height      = snapshot.height
  def.borderBlock = snapshot.borderBlock
end

local function applyDelta(def, snapshot)
  for idx, vals in pairs(snapshot.blocks) do
    def.blocks[idx] = vals.old
  end
  def.warps       = deepCopy(snapshot.warps)
  def.objects     = deepCopy(snapshot.objects)
  def.signs       = deepCopy(snapshot.signs)
  def.connections = deepCopy(snapshot.connections)
  def.width       = snapshot.width
  def.height      = snapshot.height
  def.borderBlock = snapshot.borderBlock
end

local function applyRedoDelta(def, snapshot)
  for idx, vals in pairs(snapshot.blocks) do
    def.blocks[idx] = vals.new
  end
  def.warps       = deepCopy(snapshot.warps)
  def.objects     = deepCopy(snapshot.objects)
  def.signs       = deepCopy(snapshot.signs)
  def.connections = deepCopy(snapshot.connections)
  def.width       = snapshot.width
  def.height      = snapshot.height
  def.borderBlock = snapshot.borderBlock
end

function Undo:undo(def, shiftL, shiftT, mapId, recip)
  if #self._undoStack == 0 then return nil end
  local snap = table.remove(self._undoStack)
  local redoSnap = snapshotOf(def, shiftL, shiftT, mapId, recip)
  redoSnap._full = snap._full
  if snap._full then
    redoSnap.blocks = deepCopy(def.blocks)
  else
    local blockDelta = {}
    for idx, vals in pairs(snap.blocks) do
      blockDelta[idx] = { old = vals.new, new = vals.old }
    end
    redoSnap.blocks = blockDelta
  end
  table.insert(self._redoStack, redoSnap)
  if snap._full then
    applyFull(def, snap)
  else
    applyDelta(def, snap)
  end
  return snap
end

function Undo:redo(def, shiftL, shiftT, mapId, recip)
  if #self._redoStack == 0 then return nil end
  local snap = table.remove(self._redoStack)
  local undoSnap = snapshotOf(def, shiftL, shiftT, mapId, recip)
  undoSnap._full = snap._full
  if snap._full then
    undoSnap.blocks = deepCopy(def.blocks)
  else
    local blockDelta = {}
    for idx, vals in pairs(snap.blocks) do
      blockDelta[idx] = { old = vals.old, new = vals.new }
    end
    undoSnap.blocks = blockDelta
  end
  table.insert(self._undoStack, undoSnap)
  if snap._full then
    applyFull(def, snap)
  else
    applyRedoDelta(def, snap)
  end
  return snap
end

function Undo:stack(kind)
  if kind == "redo" then return self._redoStack end
  return self._undoStack
end

function Undo:canUndo()
  return #self._undoStack > 0
end

function Undo:canRedo()
  return #self._redoStack > 0
end

return Undo