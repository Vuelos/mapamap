-- Map editing operations: paint, revert, flood fill, expand, undo/redo,
-- and original-state snapshots.

local Fill = require("mods.mapamap.domain.fill")
local Common = require("mods.mapamap.common")
local Snapshot = require("mods.mapamap.domain.snapshot")
local Gen = require("mods.mapamap.engine.gen")
local WorldAdapter = require("mods.mapamap.engine.world_adapter")
local CELL_PX = Common.CELL_PX
local BLOCK_PX = Common.BLOCK_PX

local MapOps = {}

-- Opposite connection direction for reciprocal fixing.
local BACK = { north = "south", south = "north", east = "west", west = "east" }

-- Keeps the connection graph consistent after this map's connection offsets
-- moved (expansion).  The engine places the connected map's strip at
-- `conn.offset * 32` and lands crossings at `cur - conn.offset * 2`, and the
-- vanilla reciprocal invariant is `back.offset == -offset` -- so when this
-- map's offsets shift, every connected map's return connection must mirror
-- the new value or a round-trip seam crossing lands at the wrong cell.
-- Applies the fix to the live data immediately (so the editor shows the
-- adjusted seams); when `persist` is truthy it also writes a connections-only
-- patch for each affected map so the fix survives a reload.  The affected
-- maps are always marked dirty so a later save persists their connection
-- diff even when they were reconciled live during an expand.
function MapOps.reconcileReciprocalConnections(self, persist)
  local data = self.data
  if not data or not data.maps then return end
  local def = self.def
  local changed = {}
  for dir, conn in pairs(def.connections or {}) do
    local back = BACK[dir]
    if back and conn and (conn.map or conn.mapId) then
      local other = data.maps[conn.map] or data.maps[tostring(conn.map)]
                    or data.maps[conn.mapId] or data.maps[tostring(conn.mapId)]
      if other and other ~= def then
        local r = other.connections and other.connections[back]
        if r and (r.map == self.mapId or r.mapId == self.mapId) then
          local want = -(conn.offset or 0)
          if (r.offset or 0) ~= want then
            r.offset = want
            changed[conn.map or conn.mapId] = true
          end
        end
      end
    end
  end
  if next(changed) then
    self.neighborDirty = self.neighborDirty or {}
    for otherId in pairs(changed) do
      self.neighborDirty[otherId] = true
    end
    if persist then
      local Save = require("mods.mapamap.storage.patch_saver")
      for otherId in pairs(changed) do
        Save.updatePatchField(self.mod, otherId, "connections",
          Common.deepCopy(data.maps[otherId].connections))
      end
    end
  end
end

function MapOps.expandMap(self, needL, needR, needT, needB)
  if needL == 0 and needR == 0 and needT == 0 and needB == 0 then return end
  local oldW = self.def.width
  local oldH = self.def.height
  local newW = oldW + needL + needR
  local newH = oldH + needT + needB
  local fill = self.selectedBlock or self.def.borderBlock

  local newBlocks = {}
  for by = 0, newH - 1 do
    for bx = 0, newW - 1 do
      local obx = bx - needL
      local oby = by - needT
      local idx = by * newW + bx + 1
      if obx >= 0 and obx < oldW and oby >= 0 and oby < oldH then
        newBlocks[idx] = self.def.blocks[oby * oldW + obx + 1]
      else
        newBlocks[idx] = fill
      end
    end
  end

  local cellShiftX = needL * 2
  local cellShiftY = needT * 2
  if cellShiftX ~= 0 or cellShiftY ~= 0 then
    for _, w in ipairs(self.def.warps or {}) do
      w.x = w.x + cellShiftX; w.y = w.y + cellShiftY
    end
    for _, o in ipairs(self.def.objects or {}) do
      o.x = o.x + cellShiftX; o.y = o.y + cellShiftY
    end
    for _, s in ipairs(self.def.signs or {}) do
      s.x = s.x + cellShiftX; s.y = s.y + cellShiftY
    end
      
    local c = self.def.connections or {}
    local extra = self.def.connectionsExtra
    local function shiftSide(list)
      for _, conn in ipairs(list or {}) do
        local d = conn.dir
        if d == "north" or d == "south" then
          conn.offset = (conn.offset or 0) + cellShiftX / 2
        elseif d == "east" or d == "west" then
          conn.offset = (conn.offset or 0) + cellShiftY / 2
        end
      end
    end
    if c.north then
      c.north.offset = (c.north.offset or 0) + cellShiftX / 2
    end

    if c.south then
      c.south.offset = (c.south.offset or 0) + cellShiftX / 2
    end

    if c.east then
      c.east.offset = (c.east.offset or 0) + cellShiftY / 2
    end

    if c.west then
      c.west.offset = (c.west.offset or 0) + cellShiftY / 2
    end
    for _, dir in ipairs(Common.DIRS) do
      shiftSide(extra and extra[dir])
    end
  end

  self.def.width = newW
  self.def.height = newH
  self.def.blocks = newBlocks
  self.mapW = newW * BLOCK_PX
  self.mapH = newH * BLOCK_PX
  -- Track how far the original content was shifted so revertBlock can map
  -- current block coords back to the persisted snapshot.
  self.expandShiftL = (self.expandShiftL or 0) + needL
  self.expandShiftT = (self.expandShiftT or 0) + needT
  self.cursorBx = self.cursorBx + needL * 2
  self.cursorBy = self.cursorBy + needT * 2
  self.mapChanged = true
  -- Mirror the shifted strip offsets onto every connected map's reciprocal
  -- connection now (not on save) so the editor's seams line up immediately.
  self:reconcileReciprocalConnections()
end

-- Resolves which map a MAP-mode tile operation anchored at world-cell
-- (cellX, cellY) edits.  The edited map wins inside its own body; a cell
-- inside a laid-out neighbor's body targets that map; any other cell falls
-- back to the edited map (auto-expansion when painting past an edge).
-- Returns mapId (nil = the edited map), the def, and the map's world-pixel
-- origin for local block-coordinate math.
local function paintTarget(self, cellX, cellY)
  local px = cellX * CELL_PX
  local py = cellY * CELL_PX
  local w = self.def.width * BLOCK_PX
  local h = self.def.height * BLOCK_PX
  if px >= 0 and px < w and py >= 0 and py < h then
    return nil, self.def, 0, 0
  end
  for _, nb in ipairs(self.neighbors or {}) do
    local nw = nb.def.width * BLOCK_PX
    local nh = nb.def.height * BLOCK_PX
    if px >= nb.ox and px < nb.ox + nw and py >= nb.oy and py < nb.oy + nh then
      return nb.id, nb.def, nb.ox, nb.oy
    end
  end
  return nil, self.def, 0, 0
end

-- Renders the affected map (the edited one, or a connected map) after a
-- block change.
local function rebuildFor(self, mapId)
  if mapId then
    local m = self.neighborMaps and self.neighborMaps[mapId]
    Gen.rebuildRenderer(m)
  else
    Gen.rebuildRenderer(self.map)
  end
end

function MapOps.paintBlock(self)
   local bs = self.brushSize
   local mapId, def, ox, oy = paintTarget(self, self.cursorBx, self.cursorBy)
   local px0 = self.cursorBx * CELL_PX
   local py0 = self.cursorBy * CELL_PX
   local bx0 = math.floor((px0 - ox) / BLOCK_PX)
   local by0 = math.floor((py0 - oy) / BLOCK_PX)
   local bx1 = math.floor((px0 + (bs - 1) * CELL_PX - ox) / BLOCK_PX)
   local by1 = math.floor((py0 + (bs - 1) * CELL_PX - oy) / BLOCK_PX)

   local shiftL, shiftT = self.expandShiftL, self.expandShiftT
   local capturedFull = false

   if mapId == nil then
     local needL = math.max(0, -bx0)
     local needR = math.max(0, bx1 + 1 - def.width)
     local needT = math.max(0, -by0)
     local needB = math.max(0, by1 + 1 - def.height)

   if needL > 0 or needR > 0 or needT > 0 or needB > 0 then
     -- Capture the PRE-expansion state (with pre-expansion shifts and the
     -- connected maps' reciprocal connections) so Ctrl+Z undoes the expand.
     local preShiftL, preShiftT = self.expandShiftL or 0, self.expandShiftT or 0
     local recipBefore = self:snapshotRecipConnections()
     if self.undo then
       self.undo:captureFull(def, preShiftL, preShiftT, nil, recipBefore)
     end
     self:expandMap(needL, needR, needT, needB)
     bx0 = math.floor(self.cursorBx / 2)
     by0 = math.floor(self.cursorBy / 2)
     bx1 = math.floor((self.cursorBx + bs - 1) / 2)
     by1 = math.floor((self.cursorBy + bs - 1) / 2)
     shiftL, shiftT = self.expandShiftL, self.expandShiftT
     capturedFull = true
   end
   else
     bx0 = math.max(0, bx0); by0 = math.max(0, by0)
     bx1 = math.min(bx1, def.width - 1); by1 = math.min(by1, def.height - 1)
     if bx0 > bx1 or by0 > by1 then return end
   end

   local w = def.width
   local changedIndices = {}
   local oldValues = {}
   for by = by0, by1 do
     for bx = bx0, bx1 do
       local idx = by * w + bx + 1
       changedIndices[#changedIndices + 1] = idx
       oldValues[#oldValues + 1] = def.blocks[idx]
       def.blocks[idx] = self.selectedBlock
     end
   end

   if self.undo and #changedIndices > 0 and not capturedFull then
     self.undo:capture(def, shiftL, shiftT, mapId, changedIndices, oldValues)
   end

    self.mapChanged = true
    if mapId ~= nil then self.neighborDirty[mapId] = true end
    rebuildFor(self, mapId)
  end

-- Stamps a captured blueprint grid onto the visible laid-out maps at the
-- current cursor block (2x2-aligned), skipping cells over open void.
-- Mirrors paintBlock's delta-capture so a blueprint stamp is pushed as an undo
-- step per touched map and can be undone/redone with Ctrl+Z / Ctrl+Y like any
-- block paint.
function MapOps.paintBlueprint(self, bp)
local Neighbors = require("mods.mapamap.domain.neighbors")
local Graft = require("mods.mapamap.engine.graft")
  local bx0 = math.floor(self.cursorBx / 2)
  local by0 = math.floor(self.cursorBy / 2)
  local changed = false
  local groups = {}
  local graftedTilesets = {}
  for row = 0, bp.h - 1 do
    for col = 0, bp.w - 1 do
      local cell = bp.tiles[row * bp.w + col + 1]
      if cell ~= nil and cell ~= false then
        local tile = type(cell) == "table" and cell.id or cell
        local srcTileset = type(cell) == "table" and cell.tileset or nil
        local wx = bx0 + col
        local wy = by0 + row
        local mapId, def, ox, oy =
          Neighbors.mapAt(self.def, self.neighbors, wx * 2, wy * 2)
        local bx = def and math.floor((wx * BLOCK_PX - (ox or 0)) / BLOCK_PX)
        local by = def and math.floor((wy * BLOCK_PX - (oy or 0)) / BLOCK_PX)
        if def and bx >= 0 and by >= 0 and bx < def.width and by < def.height then
          if srcTileset and srcTileset ~= def.tileset then
            local grafted = Graft.importBlock(self.data, def.tileset, def, srcTileset, tile)
            if grafted then
              tile = grafted
              graftedTilesets[def.tileset] = true
            else
              tile = nil
            end
          end
          if tile ~= nil then
            local idx = by * def.width + bx + 1
            local gkey = mapId or "__root"
            local g = groups[gkey]
            if not g then
              g = { mapId = mapId, def = def, changedIndices = {}, oldValues = {} }
              groups[gkey] = g
            end
            g.changedIndices[#g.changedIndices + 1] = idx
            g.oldValues[#g.oldValues + 1] = def.blocks[idx]
            def.blocks[idx] = tile
            changed = true
          end
        end
      end
    end
  end
  
  -- Paint warps from the blueprint
  local cursorCx0 = self.cursorBx
  local cursorCy0 = self.cursorBy
  if bp.warps then
    for _, bpWarp in ipairs(bp.warps) do
      local cx = cursorCx0 + bpWarp.x
      local cy = cursorCy0 + bpWarp.y
      local mapId, def, ox, oy = Neighbors.mapAt(self.def, self.neighbors, cx, cy)
      if def then
        local localCx = cx - math.floor((ox or 0) / CELL_PX)
        local localCy = cy - math.floor((oy or 0) / CELL_PX)
        if localCx >= 0 and localCy >= 0 and localCx < def.width * 2 and localCy < def.height * 2 then
          def.warps = def.warps or {}
          local newWarp = {}
          for k, v in pairs(bpWarp) do newWarp[k] = v end
          newWarp.x = localCx
          newWarp.y = localCy
          if self.undo then self.undo:capture(def) end
          table.insert(def.warps, newWarp)
          changed = true
          if mapId ~= nil then self.neighborDirty[mapId] = true end
        end
      end
    end
  end
  
  -- Paint objects from the blueprint
  if bp.objects then
    for _, bpObject in ipairs(bp.objects) do
      local cx = cursorCx0 + bpObject.x
      local cy = cursorCy0 + bpObject.y
      local mapId, def, ox, oy = Neighbors.mapAt(self.def, self.neighbors, cx, cy)
      if def then
        local localCx = cx - math.floor((ox or 0) / CELL_PX)
        local localCy = cy - math.floor((oy or 0) / CELL_PX)
        if localCx >= 0 and localCy >= 0 and localCx < def.width * 2 and localCy < def.height * 2 then
          def.objects = def.objects or {}
          local maxIndex = 0
          for _, o in ipairs(def.objects) do
            if (o.index or 0) > maxIndex then maxIndex = o.index end
          end
          local newObject = {}
          for k, v in pairs(bpObject) do newObject[k] = v end
          newObject.x = localCx
          newObject.y = localCy
          newObject.index = maxIndex + 1
          if self.undo then self.undo:capture(def) end
          table.insert(def.objects, newObject)
          changed = true
          if mapId ~= nil then self.neighborDirty[mapId] = true end
        end
      end
    end
  end
  
  if changed then
    for tilesetId in pairs(graftedTilesets) do
      -- The stamp grew this tileset's atlas: live renderers hold the
      -- pre-growth texture (TileRenderer:rebuild only drops the draw
      -- window), so remount every map built on it or grafted cells draw
      -- blank until the player enters each map.
      WorldAdapter.reloadTilesetRenderers(self, tilesetId)
    end
    for _, g in pairs(groups) do
      if self.undo then
        self.undo:capture(g.def, nil, nil, g.mapId, g.changedIndices, g.oldValues)
      end
      if g.mapId ~= nil then self.neighborDirty[g.mapId] = true end
      rebuildFor(self, g.mapId)
    end
    self.mapChanged = true
  end

  self:refreshLiveRenderers()
  if self.refreshObjects then
    self:refreshObjects()
  end
  return changed
end

-- Stamps a terrain brush at world block (wx, wy): resolves the cell's join
-- mask against every visible laid-out map, paints the matching slot tile,
-- then re-evaluates the 8 surrounding cells that already carry brush tiles so
-- their edges/corners re-shape to blend with the new cell.  A center over
-- open void first tries to create a host map (like blueprint stamps); cells
-- still on void after that are skipped.  Undo/renderer handling mirrors
-- paintBlueprint: one delta-capture per touched map.
function MapOps.paintBrush(self, brush, wx, wy)
  local Brushes = require("mods.mapamap.domain.brushes")
  local Neighbors = require("mods.mapamap.domain.neighbors")
  local Graft = require("mods.mapamap.engine.graft")
  if not Brushes.isComplete(brush) then return false end

  local natives = {}
  local function nativeOf(def)
    local key = def
    local n = natives[key]
    if n == nil then
      local ts = self.data and self.data.tilesets and self.data.tilesets[def.tileset]
      n = (ts and #ts.blocks) or 0
      natives[key] = n
    end
    return n
  end

  -- One world block's stored id + owning def, or nil when it is void.
  local function blockAt(bx, by)
    local mapId, def, ox, oy =
      Neighbors.mapAt(self.def, self.neighbors, bx * 2, by * 2)
    if not def then return nil end
    local lx = math.floor((bx * BLOCK_PX - (ox or 0)) / BLOCK_PX)
    local ly = math.floor((by * BLOCK_PX - (oy or 0)) / BLOCK_PX)
    if lx < 0 or ly < 0 or lx >= def.width or ly >= def.height then return nil end
    return def.blocks[ly * def.width + lx + 1], def, mapId
  end

  local function ownsAt(bx, by)
    local bid, def = blockAt(bx, by)
    if not bid then return false end
    return Brushes.ownsBlock(brush, def, nativeOf(def), bid)
  end

  local groups = {}
  local graftedTilesets = {}
  local function writeTile(bx, by, item)
    local mapId, def, ox, oy =
      Neighbors.mapAt(self.def, self.neighbors, bx * 2, by * 2)
    if not def then return false end
    local lx = math.floor((bx * BLOCK_PX - (ox or 0)) / BLOCK_PX)
    local ly = math.floor((by * BLOCK_PX - (oy or 0)) / BLOCK_PX)
    if lx < 0 or ly < 0 or lx >= def.width or ly >= def.height then return false end
    local tile = item.id
    local srcTs = item.srcTileset or item.tileset
    if srcTs and srcTs ~= def.tileset then
      local grafted = Graft.importBlock(self.data, def.tileset, def, srcTs, item.id)
      if not grafted then return false end
      tile = grafted
      graftedTilesets[def.tileset] = true
    end
    local idx = ly * def.width + lx + 1
    if def.blocks[idx] == tile then return false end
    local gkey = mapId or "__root"
    local g = groups[gkey]
    if not g then
      g = { mapId = mapId, def = def, changedIndices = {}, oldValues = {} }
      groups[gkey] = g
    end
    g.changedIndices[#g.changedIndices + 1] = idx
    g.oldValues[#g.oldValues + 1] = def.blocks[idx]
    def.blocks[idx] = tile
    return true
  end

  -- Center over void: try to grow a host map first (single-block stamp).
  if not blockAt(wx, wy) then
    self:createMapAtCursor(wx, wy, 1, 1)
  end

  local changed = false
  local centerItem = Brushes.tileFor(brush, Brushes.maskFrom(function(dx, dy)
    return ownsAt(wx + dx, wy + dy)
  end))
  if centerItem then
    changed = writeTile(wx, wy, centerItem) or changed
  end

  -- Re-blend the ring: every neighbor that already carries a brush tile gets
  -- its mask recomputed (now including the new center) and repainted.
  local RING = { { 0, -1 }, { 1, -1 }, { -1, -1 }, { -1, 0 },
                 { 1, 0 }, { -1, 1 }, { 0, 1 }, { 1, 1 } }
  for _, off in ipairs(RING) do
    local rx, ry = wx + off[1], wy + off[2]
    if ownsAt(rx, ry) then
      local item = Brushes.tileFor(brush, Brushes.maskFrom(function(dx, dy)
        return ownsAt(rx + dx, ry + dy)
      end))
      if item then changed = writeTile(rx, ry, item) or changed end
    end
  end

  if changed then
    for tilesetId in pairs(graftedTilesets) do
      -- The stamp grew this tileset's atlas: live renderers hold the
      -- pre-growth texture (TileRenderer:rebuild only drops the draw
      -- window), so remount every map built on it or grafted cells draw
      -- blank until the player enters each map.
      WorldAdapter.reloadTilesetRenderers(self, tilesetId)
    end
    for _, g in pairs(groups) do
      if self.undo then
        self.undo:capture(g.def, nil, nil, g.mapId, g.changedIndices, g.oldValues)
      end
      if g.mapId ~= nil then self.neighborDirty[g.mapId] = true end
      rebuildFor(self, g.mapId)
    end
    self.mapChanged = true
    self:refreshLiveRenderers()
  end
  return changed
end

function MapOps.revertBlock(self)
   local mapId, def, ox, oy = paintTarget(self, self.cursorBx, self.cursorBy)
   local bx = math.floor((self.cursorBx * CELL_PX - ox) / BLOCK_PX)
   local by = math.floor((self.cursorBy * CELL_PX - oy) / BLOCK_PX)

   if mapId == nil then
     local snap = self._originalSnapshot
     if not snap then return end
     local obx = bx - (self.expandShiftL or 0)
     local oby = by - (self.expandShiftT or 0)
     if obx >= 0 and obx < snap.width and oby >= 0 and oby < snap.height then
       local idx = by * def.width + bx + 1
       if idx >= 1 and idx <= #def.blocks then
         local oldVal = def.blocks[idx]
         local newVal = snap.blocks[oby * snap.width + obx + 1]
          if oldVal ~= newVal then
            if self.undo then self.undo:capture(def, self.expandShiftL, self.expandShiftT, nil, {idx}, {oldVal}) end
            def.blocks[idx] = newVal
            self.mapChanged = true
            Gen.rebuildRenderer(self.map)
          end
       end
     end
     return
   end

   local orig = self.neighborOriginals and self.neighborOriginals[mapId]
   if not orig then return end
   local idx = by * def.width + bx + 1
   if bx >= 0 and bx < def.width and by >= 0 and by < def.height
      and idx >= 1 and idx <= #def.blocks then
     local oldVal = def.blocks[idx]
     local newVal = orig.blocks[idx]
     if oldVal ~= newVal then
       if self.undo then self.undo:capture(def, nil, nil, mapId, {idx}, {oldVal}) end
       def.blocks[idx] = newVal
       self.mapChanged = true
       self.neighborDirty[mapId] = true
       rebuildFor(self, mapId)
     end
   end
 end

function MapOps.floodFill(self)
   local mapId, def, ox, oy = paintTarget(self, self.cursorBx, self.cursorBy)
   local bx = math.floor((self.cursorBx * CELL_PX - ox) / BLOCK_PX)
   local by = math.floor((self.cursorBy * CELL_PX - oy) / BLOCK_PX)
   local changed, changedIndices, oldValues = Fill.flood(def, bx, by, self.selectedBlock)
   if changed > 0 then
     if self.undo then
       local shiftL, shiftT = nil, nil
       if mapId == nil then shiftL, shiftT = self.expandShiftL, self.expandShiftT end
       self.undo:capture(def, shiftL, shiftT, mapId, changedIndices, oldValues)
     end
     self.mapChanged = true
     if mapId ~= nil then self.neighborDirty[mapId] = true end
     rebuildFor(self, mapId)
   end
 end

function MapOps.selectCursorBlock(self)
  local mapId, def, ox, oy = paintTarget(self, self.cursorBx, self.cursorBy)
  local bx = math.floor((self.cursorBx * CELL_PX - ox) / BLOCK_PX)
  local by = math.floor((self.cursorBy * CELL_PX - oy) / BLOCK_PX)
  if bx < 0 or by < 0 or bx >= def.width or by >= def.height then return end
  local b = def.blocks[by * def.width + bx + 1]
  if b then self.selectedBlock = b end
end

-- Rounds the cursor down to the even cell of the block it currently sits
-- in.  MAP mode moves and paints in whole 2-cell blocks, so a cursor left
-- on an odd cell by ENT/ENC must snap back before MAP work resumes or the
-- cursor highlight and the block grid disagree.
function MapOps.snapCursorToBlock(self)
  self.cursorBx = self.cursorBx - (self.cursorBx % 2)
  self.cursorBy = self.cursorBy - (self.cursorBy % 2)
end

function MapOps.restoreSnapshot(self, kind)
  -- Peek the target stack to find which map the next step belongs to:
  -- nil means the edited map, otherwise a connected map painted across a
  -- seam.  Each step must be re-applied to the def it captured.
  local stack = self.undo:stack(kind == "redo" and "redo" or "undo")
  local top = stack and stack[#stack]
  local mapId = top and top.mapId
  local def = self.def
  if mapId then
    local m = self.neighborMaps and self.neighborMaps[mapId]
    if not m or not m.def then return end
    def = m.def
  end
  local shiftL, shiftT = self.expandShiftL, self.expandShiftT
  if mapId then shiftL, shiftT = nil, nil end
  -- Current reciprocal connections, so the inverse step can restore them.
  local recipNow = self:snapshotRecipConnections()
  local snap = kind == "redo"
    and self.undo:redo(def, shiftL, shiftT, mapId, recipNow)
    or self.undo:undo(def, shiftL, shiftT, mapId, recipNow)
  if not snap then return end
  if snap.shiftL ~= nil then self.expandShiftL = snap.shiftL end
  if snap.shiftT ~= nil then self.expandShiftT = snap.shiftT end
  if snap.recip then
    local data = self.data
    for otherId, conns in pairs(snap.recip) do
      local otherDef = data and data.maps and data.maps[otherId]
      if otherDef then otherDef.connections = Common.deepCopy(conns) end
    end
  end
  self.mapW = self.def.width * BLOCK_PX
  self.mapH = self.def.height * BLOCK_PX
  if mapId then
    local m = self.neighborMaps and self.neighborMaps[mapId]
    Gen.rebuildRenderer(m)
  else
    self:reloadMap()
    Gen.rebuildRenderer(self.map)
    -- The undo may have restored a different connection layout; re-derive
    -- the neighbor set and re-capture its originals.
    self:rebuildNeighbors()
  end
  self.mapChanged = true
end

function MapOps.storeOriginal(self)
  self._originalSnapshot = Snapshot.capture(self.def)
  self.originalRecipConnections = {}
  if self.data and self.data.maps then
    for otherId, otherDef in pairs(self.data.maps) do
      if otherId ~= self.mapId then
        for _, conn in pairs(otherDef.connections or {}) do
          if conn.map == self.mapId then
            self.originalRecipConnections[otherId] = Common.deepCopy(otherDef.connections)
            break
          end
        end
      end
    end
  end
  self.originalEncounters = Common.deepCopy(
    self.data and self.data.encounters and self.data.encounters[self.mapId]
  )
  self.expandShiftL = 0
  self.expandShiftT = 0
  self.paletteList = {}
  -- Gen 2: stop before the trailing $00 filler metatile slots so hotbar
  -- seeds never offer dead block ids (Common.effectiveBlockCount).
  local nativeCount = Common.effectiveBlockCount(self.tileset)
  for i = 1, nativeCount do self.paletteList[i] = i - 1 end
  self.spriteList = {}
  local sprites = self.data and self.data.sprites or {}
  local keys = {}
  for k in pairs(sprites) do table.insert(keys, k) end
  table.sort(keys)
  for _, id in ipairs(keys) do table.insert(self.spriteList, id) end
end

return MapOps
