-- Grid-based map expansion for mapamap.
--
-- Map creation is owned by the grid and runs on map load, not on paint: a
-- BFS over the connection graph derives each reachable map's block-space rect
-- relative to the root (0,0), open edges are the sides with no map flush
-- against them, and autofill closes the voids -- always the cell with the most
-- flush neighbours first, bounded by a hop-depth limit so the world cannot
-- grow unboundedly from a single load.  The old paint-time edge creation
-- (NewMap.createEdgeMap / growToOppositeSide / handleEdgePaint) is removed.
--
-- Fill maps reuse the engine's connection convention (reciprocal offsets
-- mirror; flush maps get wired both ways), so a walked seam lands correctly.
-- A side can carry MORE than one connection: the primary slot
-- (`def.connections[dir]`, the only one the engine reads) holds the first,
-- and any extras live in `def.connectionsExtra[dir]` (editor-only, but still
-- traversed here and by Neighbors.compute).  Each connection records a `size`
-- (its seam span in blocks) so a new connection never overlaps an existing
-- one.  The free seams of the depth-capped layout are derived from the actual
-- laid-out map bodies (seam gaps), so a partially-covered side keeps emitting
-- smaller gap-fill voids that slot into the leftover space instead of being
-- rejected outright.

local MapGrid = {}
local Neighbors = require("mods.mapamap.domain.neighbors")
local NewMap = require("mods.mapamap.domain.new_map")
local Common = require("mods.mapamap.common")
local Connections = require("mods.mapamap.domain.connections")
local Bridge = require("mods.mapamap.engine.dramaless_bridge")
local BLOCK_PX = Common.BLOCK_PX
local DIRS = Common.DIRS
local RECIP = Common.RECIP

MapGrid.DEFAULT_DEPTH = 1   -- autofill fills voids one ring beyond the loaded map

-- BFS layout: every map reachable from `rootId` within `hops` connections,
-- with its world rect in BLOCK coords relative to the root (0,0) and its
-- hop depth.  Mirrors Neighbors.compute's offset composition so the rects
-- line up with the positions the editor/runtime actually draw.  Traverses
-- the whole connection union (primary + extras).  Returns
-- { { id, x, y, w, h, def, hop }, ... } (root first, hop 0).
function MapGrid.layout(maps, rootId, hops)
  local rootDef = maps and maps[rootId]
  if not rootDef then return {} end
  local out = {}
  local placed = { [rootId] = true }
  local queue = { { id = rootId, x = 0, y = 0,
                    w = rootDef.width, h = rootDef.height,
                    def = rootDef, hop = 0 } }
  local qi = 1
  while queue[qi] do
    local cur = queue[qi]
    qi = qi + 1
    table.insert(out, cur)
    if cur.hop < (hops or MapGrid.DEFAULT_DEPTH) then
      for _, dir in ipairs(DIRS) do
        for _, conn in ipairs(Connections.connectionsOn(cur.def, dir)) do
          local destDef = maps[conn.map] or maps[tostring(conn.map)]
          if destDef and not placed[conn.map] then
            placed[conn.map] = true
            local x, y = cur.x, cur.y
            local off = conn.offset or 0
            if dir == "north" then
              x = cur.x + off
              y = cur.y - destDef.height
            elseif dir == "south" then
              x = cur.x + off
              y = cur.y + cur.h
            elseif dir == "west" then
              x = cur.x - destDef.width
              y = cur.y + off
            else -- east
              x = cur.x + cur.w
              y = cur.y + off
            end
            if cur.hop + 1 <= (hops or MapGrid.DEFAULT_DEPTH) then
              table.insert(queue, { id = conn.map, x = x, y = y,
                                    w = destDef.width, h = destDef.height,
                                    def = destDef, hop = cur.hop + 1 })
            end
          end
        end
      end
    end
  end
  return out
end

-- True when the rect (x,y,w,h) interior-overlaps any rect in `layout`.
function MapGrid.overlaps(layout, x, y, w, h)
  for _, r in ipairs(layout or {}) do
    if x < r.x + r.w and r.x < x + w and y < r.y + r.h and r.y < y + h then
      return true
    end
  end
  return false
end

-- True when `a` (x0,y0,x1,y1) sits flush against `b` (bx,by,bw,bh) sharing a
-- seam segment (edges touch; bodies do not overlap).
function MapGrid.flushOf(x0, y0, x1, y1, bx, by, bw, bh)
  local north = (by + bh == y0) and x0 < bx + bw and bx < x1
  local south = (y1 == by) and x0 < bx + bw and bx < x1
  local west = (bx + bw == x0) and y0 < by + bh and by < y1
  local east = (x1 == bx) and y0 < by + bh and by < y1
  return north or south or west or east
end

-- The overlap (start, width) of `b`'s body on `a`'s `dir` edge, in `a`'s
-- local seam axis (blocks).  `a`/`b` are {x,y,w,h} block rects.  Returns nil
-- when `b` is not flush against that edge (no shared seam segment).
function MapGrid.edgeCoverage(a, b, dir)
  local ax, ay, aw, ah = a.x, a.y, a.w, a.h
  local bx, by, bw, bh = b.x, b.y, b.w, b.h
  local s, e
  if dir == "north" then
    if by + bh ~= ay then return nil end
    s, e = math.max(ax, bx), math.min(ax + aw, bx + bw)
  elseif dir == "south" then
    if by ~= ay + ah then return nil end
    s, e = math.max(ax, bx), math.min(ax + aw, bx + bw)
  elseif dir == "west" then
    if bx + bw ~= ax then return nil end
    s, e = math.max(ay, by), math.min(ay + ah, by + bh)
  else -- east
    if bx ~= ax + aw then return nil end
    s, e = math.max(ay, by), math.min(ay + ah, by + bh)
  end
  if e <= s then return nil end
  if dir == "north" or dir == "south" then
    return s - ax, e - s
  end
  return s - ay, e - s
end

-- The free seam segments of `r`'s `dir` edge: the parts not covered by any
-- laid-out map body flush against it (covered spans come from the maps'
-- actual positions, so legacy size-less connections restrict nothing on
-- their own -- only the maps they place do).  Returns { { start, width }, ... }
-- in block coords along the seam axis (x for north/south, y for west/east).
function MapGrid.seamGaps(full, r, dir)
  local axisLen = (dir == "north" or dir == "south") and r.w or r.h
  local covered = {}
  for _, nb in ipairs(full or {}) do
    if nb.id and nb.id ~= r.id then
      local s, wdt = MapGrid.edgeCoverage(r, nb, dir)
      if s then covered[#covered + 1] = { s = s, e = s + wdt } end
    end
  end
  table.sort(covered, function(x, y) return x.s < y.s end)
  local gaps = {}
  local cur = 0
  for _, c in ipairs(covered) do
    if c.e > cur then
      if c.s > cur then gaps[#gaps + 1] = { start = cur, width = c.s - cur } end
      cur = c.e
    end
  end
  if cur < axisLen then gaps[#gaps + 1] = { start = cur, width = axisLen - cur } end
  return gaps
end

-- Every laid-out map whose body sits flush against the void (bx,by,w,h), with
-- the connection it would need: `side` is the side of the VOID it touches,
-- `recip` the reciprocal side on the map, `off` the connection offset (the
-- map's position relative to the void along the seam axis) and `span` the
-- seam segment the connection would occupy.  Returns
-- { { id, def, rect, side, off, span, recip }, ... }.
function MapGrid.flushAgainst(full, bx, by, w, h)
  local void = { x = bx, y = by, w = w, h = h }
  local out = {}
  for _, nb in ipairs(full or {}) do
    if nb.id then
      for _, dir in ipairs(DIRS) do
        local s, span = MapGrid.edgeCoverage(void, nb, dir)
        if s then
          local off = (dir == "north" or dir == "south") and (nb.x - bx)
                    or (nb.y - by)
          out[#out + 1] = { id = nb.id, def = nb.def, rect = nb,
                            side = dir, off = off, span = span,
                            recip = RECIP[dir] }
          break
        end
      end
    end
  end
  return out
end

-- True when `def` can accept a connection on its `recip` side from the void
-- (bx,by,w,h): the void's seam span on that side must not overlap the span of
-- any existing connection there (derived from the laid-out positions of the
-- already-connected maps via `byId`).  Extra connections are allowed -- the
-- side just needs the room.
function MapGrid.contactAccepts(byId, def, recip, bx, by, w, h)
  local rect = byId[def.id]
  if not rect then return false end
  local void = { x = bx, y = by, w = w, h = h }
  local vs, vw = MapGrid.edgeCoverage(rect, void, recip)
  if not vs then return false end
  local covered = {}
  for _, conn in ipairs(Connections.connectionsOn(def, recip)) do
    local t = byId[conn.map]
    if t then
      local s, wdt = MapGrid.edgeCoverage(rect, t, recip)
      if s then covered[#covered + 1] = { s = s, e = s + wdt } end
    end
  end
  table.sort(covered, function(x, y) return x.s < y.s end)
  for _, c in ipairs(covered) do
    if vs < c.e and vs + vw > c.s then return false end
  end
  return true
end

-- Every open-edge candidate cell: for each map in `layout` (within `depth`
-- hops of the root), a same-footprint void sitting flush on each side, scored
-- by the number of laid-out maps that can accept a connection to it.  A side
-- may already carry connections -- the void only needs a free seam segment
-- (a full-width connection leaves none, a partial one leaves gap-fill voids
-- sized to the leftover space).  Overlap and connectivity are measured
-- against the FULL reachable layout, not just the depth-capped one.  Deduped
-- by position (a void can be reachable from two sides).  Returns
-- { { bx, by, w, h, dir, from, conns }, ... }.
function MapGrid.candidates(self, depth)
  local full = MapGrid.layout(self.data.maps, self.mapId, math.huge)
  local capped = MapGrid.layout(self.data.maps, self.mapId,
                                depth or MapGrid.DEFAULT_DEPTH)
  local byId = {}
  for _, e in ipairs(full) do byId[e.id] = e end
  local best = {}
  for _, r in ipairs(capped) do
    for _, dir in ipairs(DIRS) do
      for _, gap in ipairs(MapGrid.seamGaps(full, r, dir)) do
        local bx, by = r.x, r.y
        local w, h = r.w, r.h
        if dir == "north" then
          bx = r.x + gap.start
          by = r.y - h
          w = gap.width
        elseif dir == "south" then
          bx = r.x + gap.start
          by = r.y + r.h
          w = gap.width
        elseif dir == "west" then
          bx = r.x - w
          by = r.y + gap.start
          h = gap.width
        else -- east
          bx = r.x + r.w
          by = r.y + gap.start
          h = gap.width
        end
        if not MapGrid.overlaps(full, bx, by, w, h) then
          local flush = MapGrid.flushAgainst(full, bx, by, w, h)
          local wireable = 0
          for _, f in ipairs(flush) do
            if MapGrid.contactAccepts(byId, f.def, f.recip, bx, by, w, h) then
              wireable = wireable + 1
            end
          end
          if wireable > 0 then
            local key = bx .. "," .. by .. "," .. w .. "," .. h
            local prev = best[key]
            if not prev or wireable > prev.conns then
              best[key] = { bx = bx, by = by, w = w, h = h, dir = dir,
                            from = r.id, conns = wireable }
            end
          end
        end
      end
    end
  end
  local out = {}
  for _, c in pairs(best) do out[#out + 1] = c end
  return out
end

-- The highest-connectivity open void, or nil.
function MapGrid.bestVoid(self, depth)
  local best
  for _, c in ipairs(MapGrid.candidates(self, depth)) do
    if not best or c.conns > best.conns
       or (c.conns == best.conns and (c.bx < best.bx
           or (c.bx == best.bx and c.by < best.by))) then
      best = c
    end
  end
  return best
end

-- Creates a map of `w` x `h` blocks at block (bx,by), wired with reciprocal
-- connections to every laid-out map flush against it that has room on the
-- seam it touches (existing sides take an extra connection when the span
-- fits; otherwise that contact is skipped).  Returns the new id, or nil when
-- the body would interior-overlap an existing map or no contact accepts a
-- connection.
function MapGrid.createMap(self, bx, by, w, h)
  if not (self and self.data and self.data.maps) then return nil end
  if w <= 0 or h <= 0 then return nil end
  local full = MapGrid.layout(self.data.maps, self.mapId, math.huge)
  if MapGrid.overlaps(full, bx, by, w, h) then return nil end

  local byId = {}
  for _, e in ipairs(full) do byId[e.id] = e end

  local flush = MapGrid.flushAgainst(full, bx, by, w, h)
  local wireable = {}
  for _, f in ipairs(flush) do
    if MapGrid.contactAccepts(byId, f.def, f.recip, bx, by, w, h) then
      wireable[#wireable + 1] = f
    end
  end
  if #wireable == 0 then return nil end
  if self and self.mod and self.mod.log then
    local details = {}
    for _, f in ipairs(wireable) do
      details[#details + 1] = string.format("%s:%s@%s", tostring(f.id), tostring(f.side), tostring(f.off))
    end
  end

  local newId = self.mapId .. "_EXT"
  local n = 1
  while self.data.maps[newId] do
    n = n + 1
    newId = self.mapId .. "_EXT" .. n
  end
  local newDef = NewMap.buildDef(self, newId, w, h)
  self.data.maps[newId] = newDef

  local wired = {}
  for _, f in ipairs(wireable) do
    Connections.addConnection(newDef, f.def, f.side, f.off, f.span)
    self.neighborDirty = self.neighborDirty or {}
    self.neighborDirty[f.id] = true
    wired[#wired + 1] = f.id
  end

  -- Snapshot AFTER wiring so the persisted new map carries its connections.
  self._newMaps = self._newMaps or {}
  self._newMaps[newId] = Common.deepCopy(newDef)

  -- rebuildWorldNeighbors() re-baselines the neighbor originals, which would
  -- otherwise drop the reciprocal connections just added to laid-out maps
  -- from the close-time patch diff.  Keep the pre-mutation originals for the
  -- wired maps so their new connection edges survive a reload.
  local keptOriginal = {}
  if self.neighborOriginals then
    for _, id in ipairs(wired) do
      if self.neighborOriginals[id] then keptOriginal[id] = self.neighborOriginals[id] end
    end
  end

  self.mapChanged = true
  self:rebuildWorldNeighbors()
  if self.neighborOriginals then
    for id, orig in pairs(keptOriginal) do self.neighborOriginals[id] = orig end
  end
  return newId
end

-- Fills the single highest-connectivity open void within `depth` hops of the
-- loaded map.  Returns the new map id or nil when no void remains.
function MapGrid.fillNextVoid(self, depth)
  local void = MapGrid.bestVoid(self, depth)
  if not void then return nil end
  return MapGrid.createMap(self, void.bx, void.by, void.w, void.h)
end

-- Creates maps at every open void flush on `direction` (north/south/west/east)
-- within `depth` hops.  Returns how many were created.
function MapGrid.expandInDirection(self, direction, depth)
  local created = 0
  for _, c in ipairs(MapGrid.candidates(self, depth)) do
    if c.dir == direction then
      if MapGrid.createMap(self, c.bx, c.by, c.w, c.h) then
        created = created + 1
      end
    end
  end
  return created
end

-- The load-time fill: repeatedly closes the highest-connectivity void while
-- any remains within `depth` hops, bounded by a safety cap.  Returns the
-- number of maps created.
function MapGrid.autofill(self, depth)
  local created = 0
  local limit = 64
  while created < limit do
    local id = MapGrid.fillNextVoid(self, depth)
    if not id then break end
    created = created + 1
  end
  return created
end

-- True when every cell in (x0,y0,w,h) lies inside some laid-out map body.
local function rectFullyCovered(full, x0, y0, w, h)
  for y = y0, y0 + h - 1 do
    for x = x0, x0 + w - 1 do
      local hit = false
      for _, r in ipairs(full) do
        if x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h then
          hit = true; break
        end
      end
      if not hit then return false end
    end
  end
  return true
end

-- Paint-time void creation: builds candidate rects flush against every
-- laid-out map that contain the given block rect, picks the best, and
-- creates the map.  Returns the new id or nil when no candidate works.
function MapGrid.createForBlocks(self, bx0, by0, bw, bh)
  if not (self and self.data and self.data.maps) then return nil end
  if bw <= 0 or bh <= 0 then return nil end
  local full = MapGrid.layout(self.data.maps, self.mapId, math.huge)
  if rectFullyCovered(full, bx0, by0, bw, bh) then return nil end

  local byId = {}
  for _, e in ipairs(full) do byId[e.id] = e end

  local cands = {}
  for _, r in ipairs(full) do
    local sides = {
      { dir = "east",
        test = bx0 >= r.x + r.w,
        rect = { x = r.x + r.w, y = r.y,
                 w = bx0 + bw - (r.x + r.w), h = r.h } },
      { dir = "west",
        test = bx0 + bw <= r.x,
        rect = { x = bx0, y = r.y, w = r.x - bx0, h = r.h } },
      { dir = "south",
        test = by0 >= r.y + r.h,
        rect = { x = r.x, y = r.y + r.h, w = r.w,
                 h = by0 + bh - (r.y + r.h) } },
      { dir = "north",
        test = by0 + bh <= r.y,
        rect = { x = r.x, y = by0, w = r.w, h = r.y - by0 } },
    }
    for _, sd in ipairs(sides) do
      if sd.test then
        local rc = sd.rect
        if rc.w > 0 and rc.h > 0
           and not MapGrid.overlaps(full, rc.x, rc.y, rc.w, rc.h)
           and (rc.x < bx0 + bw and bx0 < rc.x + rc.w
                and rc.y < by0 + bh and by0 < rc.y + rc.h) then
          local flush = MapGrid.flushAgainst(full, rc.x, rc.y, rc.w, rc.h)
          local wireable = 0
          for _, f in ipairs(flush) do
            if MapGrid.contactAccepts(byId, f.def, f.recip,
                                      rc.x, rc.y, rc.w, rc.h) then
              wireable = wireable + 1
            end
          end
          if wireable > 0 then
            cands[#cands + 1] = {
              rect = rc, conns = wireable,
              priority = r.id == self.mapId and 0 or 1,
              area = rc.w * rc.h,
            }
          end
        end
      end
    end
  end

  table.sort(cands, function(a, b)
    if a.priority ~= b.priority then return a.priority < b.priority end
    if a.conns ~= b.conns then return a.conns > b.conns end
    return a.area < b.area
  end)

  for _, c in ipairs(cands) do
    local newId = MapGrid.createMap(self, c.rect.x, c.rect.y,
                                    c.rect.w, c.rect.h)
    if newId then return newId end
  end
  return nil
end

-- Thin wrapper: create a host-sized map on the void containing the single
-- block at (bx,by), sized like the existing maps rather than the painted cell.
function MapGrid.createForPaint(self, bx, by)
  return MapGrid.createLikeNeighbor(self, bx, by)
end

-- Paint-time void creation sized like the existing maps: finds the host-sized
-- candidate void (per MapGrid.candidates, which derives its footprint from the
-- laid-out map bodies / seam gaps -- not the painted blocks) that contains the
-- painted block, and creates it with full-seam connections.  Returns the new id
-- or nil when no host-sized void contains the block.
function MapGrid.createLikeNeighbor(self, bx, by)
  if not (self and self.data and self.data.maps) then return nil end
  local depth = self.DEFAULT_DEPTH or 1
  local caps = MapGrid.candidates(self, depth)
  local best
  for _, c in ipairs(caps) do
    if bx >= c.bx and by >= c.by
       and bx < c.bx + c.w and by < c.by + c.h then
      if not best or c.conns > best.conns then best = c end
    end
  end
  if not best then return nil end
  return MapGrid.createMap(self, best.bx, best.by, best.w, best.h)
end

return MapGrid
