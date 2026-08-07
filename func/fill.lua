-- Flood fill for the map editor.
-- Replaces all connected blocks of the same type with the selected block
-- using a four-directional BFS starting from (bx, by).

local Fill = {}

-- Performs a flood fill on def.blocks starting from block coordinate
-- (bx, by).  Every block that is connected to the start and has the
-- same original value is replaced with newBlock.
-- Returns the number of blocks changed, a table of changed
-- block indices, and a table of their original values (empty if nothing was done).
function Fill.flood(def, bx, by, newBlock)
  local w = def.width
  local h = def.height
  if bx < 0 or bx >= w or by < 0 or by >= h then return 0, {}, {} end

  local idx = by * w + bx + 1
  local target = def.blocks[idx]
  if target == nil or target == newBlock then return 0, {}, {} end

  local changed = 0
  local changedIndices = {}
  local oldValues = {}
  local visited = {}
  local queue = { { bx, by } }
  visited[idx] = true

  while #queue > 0 do
    local cell = table.remove(queue, 1)
    local cx, cy = cell[1], cell[2]
    local ci = cy * w + cx + 1
    oldValues[#oldValues + 1] = def.blocks[ci]
    def.blocks[ci] = newBlock
    changed = changed + 1
    changedIndices[#changedIndices + 1] = ci

    -- Four-directional neighbours.
    for _, dir in ipairs({ { 0, -1 }, { 0, 1 }, { -1, 0 }, { 1, 0 } }) do
      local nx, ny = cx + dir[1], cy + dir[2]
      if nx >= 0 and nx < w and ny >= 0 and ny < h then
        local ni = ny * w + nx + 1
        if not visited[ni] and def.blocks[ni] == target then
          visited[ni] = true
          table.insert(queue, { nx, ny })
        end
      end
    end
  end

  return changed, changedIndices, oldValues
end

return Fill