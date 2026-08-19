-- EditorTools: tool / brush state holder for the direct-paint overlay.
--
-- Owns the brush drag state (arm flags, dedupe anchors, right-button pending
-- click-vs-drag, entity drag ghost, void-stroke buffer) that input.lua used to
-- keep as a local.  input.lua stays a pure event translator: it resolves the
-- cursor and calls the small state mutations here, and the world operations
-- (paint / erase) route through apply()/erase() below into domain/paint.lua.
--
-- The `brush` table is passed down to Paint.paintAt/eraseAt as the shared
-- drag-state argument, so this module is the single owner of that state.

local Coords = require("mods.mapamap.engine.coords")
local Neighbors = require("mods.mapamap.domain.neighbors")
local Paint = require("mods.mapamap.domain.paint")

local Tools = {}

-- Brush drag state (arm flags, drag anchors, dedupe cells).  Read and mutated
-- by Paint through the `brush` argument; every mutation goes through the
-- helpers below so the state machine has one home.
Tools.brush = {
  painting = false,
  erasing = false,
  draggingEntity = nil,   -- { kind = "warp"|"object", entity = ..., ox, oy } during RMB drag
  paintingMap = nil,      -- mapId painted on this drag (blocks only)
  paintVoidCells = nil,   -- void cells buffered this drag, committed as one map on release
  pendingMapClick = nil,  -- RMB press over a map body, pending click-vs-drag
  pendingEntityClick = nil, -- RMB press over a warp/object, deferred click-vs-drag
  lastBlockX = nil,       -- last painted block coord (re-paint dedupe)
  lastBlockY = nil,
  lastCellX = nil,
  lastCellY = nil,
}

-- Ghost entity drag (copy of brush.draggingEntity) for the overlay renderer.
Tools.draggingEntity = nil

-- Clears every brush field for a fresh session open.
function Tools.reset()
  local b = Tools.brush
  b.painting = false
  b.erasing = false
  b.draggingEntity = nil
  b.paintingMap = nil
  b.paintVoidCells = nil
  b.pendingMapClick = nil
  b.pendingEntityClick = nil
  b.lastBlockX = nil
  b.lastBlockY = nil
  b.lastCellX = nil
  b.lastCellY = nil
  Tools.draggingEntity = nil
end

-- Retire every held drag on a pointer cancel (focus loss / input recovery).
function Tools.cancelled()
  local b = Tools.brush
  b.painting = false
  b.erasing = false
  b.draggingEntity = nil
  b.pendingEntityClick = nil
  b.paintVoidCells = nil
  b.pendingMapClick = nil
  Tools.draggingEntity = nil
end

-- ---------------------------------------------------------------------------
-- Arm / disarm (LMB paint, RMB erase, and the RMB click-vs-drag routing).

-- Arms the paint brush: a press without a drag still places one block, so the
-- dedupe anchors start cleared.
function Tools.armPaint()
  local b = Tools.brush
  b.painting = true
  b.erasing = false
  b.lastCellX, b.lastCellY = nil, nil
  b.paintVoidCells = nil
end

function Tools.stopPaint()
  Tools.brush.painting = false
end

-- Arms the erase brush (plain RMB over empty ground).
function Tools.armErase()
  local b = Tools.brush
  b.erasing = true
  b.painting = false
  b.lastCellX, b.lastCellY = nil, nil
end

-- RMB press over a warp/object: defer the click-vs-drag decision until the
-- pointer either stops (Details click) or moves past the threshold (drag).
function Tools.deferEntityClick(kind, entity, mx, my)
  local b = Tools.brush
  b.pendingEntityClick = { kind = kind, entity = entity, mx = mx, my = my }
  b.erasing = false
  b.painting = false
end

-- RMB press over a map body: defer rename-click vs erase-drag.
function Tools.deferMapClick(mx, my, mapId)
  local b = Tools.brush
  b.pendingMapClick = { mx = mx, my = my, mapId = mapId }
  b.erasing = false
  b.painting = false
end

-- A moved pointer over a pending map-body click: once past the threshold the
-- press becomes an erase.  Returns true when the click was converted.
function Tools.maybeEraseFromMap(mx, my)
  local b = Tools.brush
  local pc = b.pendingMapClick
  if not pc then return false end
  local dx, dy = mx - pc.mx, my - pc.my
  if dx * dx + dy * dy <= 25 then return false end
  b.pendingMapClick = nil
  b.erasing = true
  b.lastCellX, b.lastCellY = nil, nil
  return true
end

-- A moved pointer over a pending entity click: once past the threshold the
-- press becomes an entity drag (ghost shown at the cursor cell).  Resolves the
-- map offset so the overlay draws the ghost at the right world position.
-- Returns true when the drag was armed.
function Tools.maybeDragEntity(session, mx, my)
  local b = Tools.brush
  local pc = b.pendingEntityClick
  if not pc then return false end
  local dx, dy = mx - pc.mx, my - pc.my
  if dx * dx + dy * dy <= 25 then return false end
  b.pendingEntityClick = nil
  local t = Coords.transform(session.game)
  local ox, oy = 0, 0
  if t then
    local tx, ty = Coords.toWorldCell(t, pc.mx, pc.my)
    local mapId, mapDef, mapOx, mapOy =
      Neighbors.mapAt(session.def, session.neighbors, tx, ty)
    ox = mapOx or 0
    oy = mapOy or 0
  end
  b.draggingEntity = { kind = pc.kind, entity = pc.entity, ox = ox, oy = oy }
  Tools.draggingEntity = b.draggingEntity
  return true
end

-- RMB release after an entity drag: return the dragged entity ({ kind, entity,
-- ox, oy }) and clear the ghost.  The caller relocates it to the cursor cell.
function Tools.releaseEntityDrag()
  local ent = Tools.brush.draggingEntity
  Tools.brush.draggingEntity = nil
  Tools.draggingEntity = nil
  return ent
end

-- RMB release over an entity with no drag: return the deferred click and clear
-- it so the caller opens its Details panel.
function Tools.takeEntityClick()
  local pc = Tools.brush.pendingEntityClick
  Tools.brush.pendingEntityClick = nil
  return pc
end

-- RMB release over a map body with no drag: return the deferred click.
function Tools.takeMapClick()
  local pc = Tools.brush.pendingMapClick
  Tools.brush.pendingMapClick = nil
  return pc
end

-- Settles the erase / drag arms when a physical release was lost (focus flip,
-- input recovery).  Clears both held-button brushes and any in-flight drag.
function Tools.stopErase()
  local b = Tools.brush
  b.erasing = false
  b.draggingEntity = nil
  b.pendingEntityClick = nil
  b.pendingMapClick = nil
  Tools.draggingEntity = nil
end

-- True while the LMB paint brush is armed (the pointer is physically held).
function Tools.isPainting()
  return Tools.brush.painting
end

-- True while the RMB erase brush is armed.
function Tools.isErasing()
  return Tools.brush.erasing
end

-- ---------------------------------------------------------------------------
-- Apply: route the selected hotbar tool at the cursor through Paint.  The
-- brush table is passed down so paint-time void buffering / dedupe anchors
-- stay in one place.

function Tools.apply(ui, session, mx, my)
  return Paint.paintAt(ui, Tools.brush, session, mx, my)
end

function Tools.erase(ui, session, mx, my)
  return Paint.eraseAt(ui, Tools.brush, session, mx, my)
end

-- Finalizes a block-paint stroke that landed on void (LMB release): creates
-- the host-sized maps and paints the buffered cells (see Paint.commitVoidStroke).
function Tools.commitVoidStroke(session)
  return Paint.commitVoidStroke(Tools.brush, session)
end

return Tools