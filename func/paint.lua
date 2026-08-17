-- World paint operations: placing the selected hotbar item at a cursor cell,
-- erasing back to the saved baseline, picking the block under the cursor, and
-- the graphical warp destination-pick click.  The brush's drag state (arm
-- flags, dedupe anchors) lives in a `brush` table owned by input.lua and is
-- passed in so this module stays a pure operation layer.

local Common = require("mods.mapamap.func.common")
local Coords = require("mods.mapamap.func.coords")
local Neighbors = require("mods.mapamap.func.neighbors")
local Hotbar = require("mods.mapamap.components.hotbar")
local Details = require("mods.mapamap.components.details")
local Blueprints = require("mods.mapamap.func.blueprints")

local Paint = {}

-- The block / sprite id stored at a given screen point, for the cursor pick.
-- Returns nil when not over the world.
function Paint.pickUnder(session, game, mx, my)
  local t = Coords.transform(game)
  if not t then return nil end
  local tx, ty = Coords.toWorldCell(t, mx, my)
  local mapId, def, ox, oy = Neighbors.mapAt(session.def, session.neighbors, tx, ty)
  if not def then return nil end
  local bx = math.floor((tx * 16 - (ox or 0)) / Common.BLOCK_PX)
  local by = math.floor((ty * 16 - (oy or 0)) / Common.BLOCK_PX)
  if bx < 0 or by < 0 or bx >= def.width or by >= def.height then return nil end
  return def.blocks[by * def.width + bx + 1], def.tileset, mapId
end

-- Paints one block (or sprite / item / warp / object / blueprint) at the cursor
-- if it has moved to a new cell.  Returns true when something changed.
function Paint.paintAt(ui, brush, session, mx, my)
  local item = Hotbar.selected(ui)
  if not item then return false end
  local t = Coords.transform(session.game)
  if not t then return false end
  local tx, ty = Coords.toWorldCell(t, mx, my)
  if tx == brush.lastCellX and ty == brush.lastCellY then return false end
  brush.lastCellX, brush.lastCellY = tx, ty

  -- Sprites place NPC objects, one per block cell.
  if item.kind == "sprite" then
    session.cursorBx = tx
    session.cursorBy = ty
    return session:placeSprite(item.id)
  end

  -- Items place map-item objects, one per block cell.
  if item.kind == "item" then
    session.cursorBx = tx
    session.cursorBy = ty
    return session:placeItem(item.id)
  end

  -- Warps place a warp wired to the tool's destination (a copy), or a
  -- single fresh warp (self-destination) via the "new warp" template.
  if item.kind == "warp" then
    session.cursorBx = tx
    session.cursorBy = ty
    if item.newWarp then
      return session:placeWarp(tx, ty) ~= nil
    end
    return session:placeWarp(tx, ty, item.destMap, item.destWarp) ~= nil
  end

  -- Objects place a deep copy of the selected map object at the cursor (the
  -- "copy from the map" tool), or a fresh simple NPC via the template.
  if item.kind == "object" then
    session.cursorBx = tx
    session.cursorBy = ty
    if item.newObject then
      local o = session:placeNewObject(tx, ty)
      if o then
        session.selectedObject = o
        Details.open(ui, session, { object = o })
      end
      return o ~= nil
    end
    return session:placeObjectCopy(tx, ty, item.obj) ~= nil
  end

  -- Blueprints stamp a block grid at the cursor block.
  if item.kind == "blueprint" then
    return Blueprints.paint(ui, session, item.id, mx, my)
  end

  -- Blocks paint with the shared map_ops brush.  Cursor is snapped to whole
  -- blocks (2-cell) in MAP mode semantics.
  session.cursorBx = tx - (tx % 2)
  session.cursorBy = ty - (ty % 2)
  session.selectedBlock = item.id
  local srcTileset = item.srcTileset or item.tileset
  if srcTileset and srcTileset ~= session.tileset.id then
    local gid = session:importBlock(srcTileset, item.id)
    if gid == nil then return false end
    session.selectedBlock = gid
    if session._needsGraftRebuild then
      session:reloadGraftedRenderers()
    end
  end
  -- When the cursor lands on void (outside every laid-out map body) try to
  -- create a new map flush against the nearest host.  On failure (no flush
  -- contact possible) the paint is a no-op.
  local side = session:cellEdgeSide(session.cursorBx, session.cursorBy)
  if side and not session:cellInsideNeighbor(session.cursorBx, session.cursorBy) then
    local newId = session:createMapAtCursor()
    if not newId then return false end
  end
  session:snapCursorToBlock()
  session:paintBlock()
  session:refreshLiveRenderers()
  return session.mapChanged
end

-- Erases one cell back to the snapshot (blocks) or removes an object (sprite
-- slot).  Returns true when something changed.
function Paint.eraseAt(ui, brush, session, mx, my)
  local t = Coords.transform(session.game)
  if not t then return false end
  local tx, ty = Coords.toWorldCell(t, mx, my)
  if tx == brush.lastCellX and ty == brush.lastCellY then return false end
  brush.lastCellX, brush.lastCellY = tx, ty
  local item = Hotbar.selected(ui)
  if item and (item.kind == "sprite" or item.kind == "object") then
    session.cursorBx = tx
    session.cursorBy = ty
    return session:eraseObjectsAtCell()
  end
  session.cursorBx = tx - (tx % 2)
  session.cursorBy = ty - (ty % 2)
  session:snapCursorToBlock()
  session:revertBlock()
  session:refreshLiveRenderers()
  return session.mapChanged
end

-- A world click with the warp destination-pick armed (C): wires the selected
-- warp to land on whatever laid-out map is under the cursor.  Returns true
-- (the click is always consumed while armed).
function Paint.destPick(ui, session, mx, my)
  local t = Coords.transform(session.game)
  if not t then return true end
  local tx, ty = Coords.toWorldCell(t, mx, my)
  local mapId, def, ox, oy = Neighbors.mapAt(session.def, session.neighbors, tx, ty)
  if def then
    if session:connectWarpToCell(session.selectedWarp,
       mapId or session.mapId, tx - (ox or 0) / 16, ty - (oy or 0) / 16) then
      ui.warpDestPick = false
    end
  end
  return true
end

return Paint
