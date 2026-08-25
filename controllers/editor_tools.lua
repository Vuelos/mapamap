-- EditorTools: tool / brush state holder for the direct-paint overlay.
--
-- Owns the brush drag state (arm flags, dedupe anchors, right-button pending
-- map-body click, void-stroke buffer) that input.lua used to keep as a local.
-- input.lua stays a pure event translator: it resolves the cursor and calls
-- the small state mutations here, and the world operations (paint / erase)
-- route through apply()/erase() below into domain/paint.lua.
--
-- The `brush` table is passed down to Paint.paintAt/eraseAt as the shared
-- drag-state argument, so this module is the single owner of that state.

local Paint = require("mods.mapamap.domain.paint")

local Tools = {}

-- Brush drag state (arm flags, drag anchors, dedupe cells).  Read and mutated
-- by Paint through the `brush` argument; every mutation goes through the
-- helpers below so the state machine has one home.
Tools.brush = {
  painting = false,
  erasing = false,
  paintingMap = nil,      -- mapId painted on this drag (blocks only)
  paintVoidCells = nil,   -- void cells buffered this drag, committed as one map on release
  pendingMapClick = nil,  -- RMB press over a map body, pending rename-click vs erase-drag
  lastBlockX = nil,       -- last painted block coord (re-paint dedupe)
  lastBlockY = nil,
  lastCellX = nil,
  lastCellY = nil,
}

-- Clears every brush field for a fresh session open.
function Tools.reset()
  local b = Tools.brush
  b.painting = false
  b.erasing = false
  b.paintingMap = nil
  b.paintVoidCells = nil
  b.pendingMapClick = nil
  b.lastBlockX = nil
  b.lastBlockY = nil
  b.lastCellX = nil
  b.lastCellY = nil
end

-- Retire every held drag on a pointer cancel (focus loss / input recovery).
function Tools.cancelled()
  local b = Tools.brush
  b.painting = false
  b.erasing = false
  b.paintVoidCells = nil
  b.pendingMapClick = nil
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

-- RMB release over a map body with no drag: return the deferred click.
function Tools.takeMapClick()
  local pc = Tools.brush.pendingMapClick
  Tools.brush.pendingMapClick = nil
  return pc
end

-- Settles the erase arms when a physical release was lost (focus flip,
-- input recovery).
function Tools.stopErase()
  local b = Tools.brush
  b.erasing = false
  b.pendingMapClick = nil
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