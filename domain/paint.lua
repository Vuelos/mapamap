-- World paint operations: placing the selected hotbar item at a cursor cell,
-- erasing back to the saved baseline, picking the block under the cursor, and
-- the graphical warp destination-pick click.  The brush's drag state (arm
-- flags, dedupe anchors) lives in a `brush` table owned by
-- controllers/editor_tools.lua and is passed in so this module stays a pure
-- operation layer.

local Common = require("mods.mapamap.common")
local Coords = require("mods.mapamap.engine.coords")
local Neighbors = require("mods.mapamap.domain.neighbors")
local WorldAdapter = require("mods.mapamap.engine.world_adapter")
local Hotbar = require("mods.mapamap.components.hotbar")
local Details = require("mods.mapamap.components.details")
local Blueprints = require("mods.mapamap.domain.blueprints")
local Objects = require("mods.mapamap.domain.objects")
local Warps = require("mods.mapamap.domain.warps")

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

  -- Entities place a warp / object / sign at the cursor depending on
  -- entityType.  A `create` payload (Entity Creator form) carries the fully
  -- specified entity; plain entity cells act as copy tools.
  if item.kind == "entity" then
    session.cursorBx = tx
    session.cursorBy = ty
    local et = item.entityType
    if et == "warp" then
      if item.create then
        return session:placeWarp(tx, ty, item.create.destMap,
          item.create.destWarp) ~= nil
      end
      return session:placeWarp(tx, ty, item.destMap, item.destWarp) ~= nil
    elseif et == "object" then
      if item.create then
        local o = session:placeObjectSpec(tx, ty, item.create)
        if o then session.selectedItem = o end
        return o ~= nil
      end
      return session:placeObjectCopy(tx, ty, item.obj) ~= nil
    elseif et == "sign" then
      if item.create then
        local s = session:placeSignSpec(tx, ty, item.create)
        if s then session.selectedItem = s end
        return s ~= nil
      end
      local s = session:placeNewSign(tx, ty)
      if s then
        session.selectedItem = s
        Details.open(ui, session, { entity = s, entityType = "sign" })
      end
      return s ~= nil
    end
    return false
  end

  -- Blueprints stamp a block grid at the cursor block.
  if item.kind == "blueprint" then
    return Blueprints.paint(ui, session, item.id, mx, my)
  end

  -- Terrain brushes stamp a join-aware tile at the cursor block and re-blend
  -- the surrounding brush tiles (see MapOps.paintBrush).
  if item.kind == "brush" then
    local bx = math.floor(tx / 2)
    local by = math.floor(ty / 2)
    session.cursorBx = bx * 2
    session.cursorBy = by * 2
    return session:paintBrush(item, bx, by)
  end

  -- Blocks paint with the shared map_ops brush.  Cursor is snapped to whole
  -- blocks (2-cell) in MAP mode semantics.
  session.cursorBx = tx - (tx % 2)
  session.cursorBy = ty - (ty % 2)
  session.selectedBlock = item.id
  -- Resolve which map the cursor actually edits BEFORE importing: a foreign-
  -- tileset block painted across a seam must graft into THAT map's tileset and
  -- def.  Importing into the session's own pair (the old behavior) put the id
  -- in this map's graftBlocks space and indexed this map's tileset atlas --
  -- the neighbor's renderer could resolve neither, so the cell drew blank and
  -- the graft was persisted on the wrong map.  Mirrors paintBlueprint.
  local Graft = require("mods.mapamap.engine.graft")
  local tMapId, tDef = Neighbors.mapAt(session.def, session.neighbors,
    session.cursorBx, session.cursorBy)
  if not tDef then tMapId, tDef = nil, session.def end
  local srcTileset = item.srcTileset or item.tileset
  if srcTileset and srcTileset ~= tDef.tileset then
    local gid
    if tDef == session.def then
      gid = session:importBlock(srcTileset, item.id)
    else
      gid = Graft.importBlock(session.data, tDef.tileset, tDef,
        srcTileset, item.id)
    end
    if gid == nil then return false end
    session.selectedBlock = gid
    if tDef ~= session.def then
      -- The DESTINATION tileset grew rows: every renderer already built on it
      -- holds the pre-growth atlas texture (TileRenderer:rebuild only drops
      -- the draw window), so remount them or the cell draws blank until the
      -- player enters the map.  Flags the map dirty for save/bake too.
      WorldAdapter.reloadTilesetRenderers(session, tDef.tileset)
      session.neighborDirty[tMapId] = true
    elseif session._needsGraftRebuild then
      session:reloadGraftedRenderers()
    end
  end
  -- When the cursor lands on void (outside every laid-out map body) buffer the
  -- cell for a single map created at stroke end (see commitVoidStroke).  This
  -- avoids spraying one 1x1 map per painted block; instead one map sized to the
  -- whole drag is created, with correct full-width connections.  A paint with no
  -- flush contact possible is a no-op (cellEdgeSide reports an edge, but no host
  -- is actually adjacent so nothing is buffered and createForBlocks no-ops too).
  local side = session:cellEdgeSide(session.cursorBx, session.cursorBy)
  if side and not session:cellInsideNeighbor(session.cursorBx, session.cursorBy) then
    brush.paintVoidCells = brush.paintVoidCells or {}
    brush.paintVoidCells[#brush.paintVoidCells + 1] = {
      bx = session.cursorBx, by = session.cursorBy, block = session.selectedBlock,
    }
    return false
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
  if item and (item.kind == "sprite" or item.kind == "entity") then
    session.cursorBx = tx
    session.cursorBy = ty
    if item.kind == "entity" then
      local et = item.entityType
      if et == "warp" then
        local w = session:warpAt(tx, ty)
        if w then session:removeWarp(w) end
      elseif et == "object" then
        session:eraseObjectsAtCell()
      elseif et == "sign" then
        session:eraseSignsAtCell()
      end
    else
      session:eraseObjectsAtCell()
    end
    session:refreshLiveRenderers()
    return session.mapChanged
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
    if session:connectWarpToCell(session.selectedItem,
       mapId or session.mapId, tx - (ox or 0) / 16, ty - (oy or 0) / 16) then
      ui.warpDestPick = false
    end
  end
  return true
end

-- Finalizes a block-paint stroke that landed on void: creates ONE map sized
-- like the existing maps (host-sized, full-seam connections) on the void the
-- drag touched -- never one 1x1 map per painted block -- and paints every
-- buffered cell into it.  Called from input on pointer release.  Returns true
-- when a map was created / painted.
function Paint.commitVoidStroke(brush, session)
  local cells = brush.paintVoidCells
  if not cells or #cells == 0 then return false end
  brush.paintVoidCells = nil

  local MapGrid = require("mods.mapamap.domain.map_grid")

  -- Create a host-sized map for the drag (covers a straight drag next to a
  -- single host).  L-shaped strokes may need a map per arm: any cell still
  -- outside a laid-out map after the first create gets its own host-sized map.
  local function ensure(cell)
    if session:cellInsideNeighbor(cell.bx, cell.by) then return true end
    local bx = math.floor(cell.bx / 2)
    local by = math.floor(cell.by / 2)
    return MapGrid.createLikeNeighbor(session, bx, by) ~= nil
  end

  ensure(cells[1])
  for _, c in ipairs(cells) do
    if not session:cellInsideNeighbor(c.bx, c.by) then ensure(c) end
  end

  for _, c in ipairs(cells) do
    if session:cellInsideNeighbor(c.bx, c.by) then
      session.selectedBlock = c.block
      session.cursorBx = c.bx
      session.cursorBy = c.by
      session:paintBlock()
    end
  end
  session:refreshLiveRenderers()
  return true
end

return Paint
