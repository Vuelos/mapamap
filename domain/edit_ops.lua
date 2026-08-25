-- EditOps: the tiny idioms every domain module repeats -- undo capture, the
-- max-index walk for new placements, and the walk-grid bounds check.  One
-- home keeps objects/signs/warps/party editing in lockstep.

local EditOps = {}

-- Captures `def` onto the session's undo stack when one exists.
function EditOps.capture(self, def)
  if self.undo then self.undo:capture(def) end
end

-- The index a NEW placement in `list` should take (1-based, after the
-- highest existing index; 1 when the list is empty).
function EditOps.nextIndex(list)
  local maxIndex = 0
  for _, o in ipairs(list or {}) do
    if (o.index or 0) > maxIndex then maxIndex = o.index end
  end
  return maxIndex + 1
end

-- Walk-grid (16 px cell) bounds check against a map def.
function EditOps.cellIn(def, x, y)
  return x >= 0 and y >= 0 and x < def.width * 2 and y < def.height * 2
end

return EditOps
