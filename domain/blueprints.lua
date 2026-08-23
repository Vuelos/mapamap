-- Blueprint capture and paint.  Rectangle-select (R) grabs a block grid out of
-- the visible world; the captured blueprint is stored whole as an inventory
-- item in the Blueprints tab.  Stamping paints the grid back through the
-- session's MapOps path (which pushes an undo step).

local Common = require("mods.mapamap.common")
local Coords = require("mods.mapamap.engine.coords")
local Neighbors = require("mods.mapamap.domain.neighbors")
local Inventory = require("mods.mapamap.components.inventory")

local Blueprints = {}

-- World-block coords (bx, by) under a screen point, or nil when it is not over
-- any visible laid-out map body.
function Blueprints.cellAt(session, mx, my)
  local t = Coords.transform(session.game)
  if not t then return nil end
  local tx, ty = Coords.toWorldCell(t, mx, my)
  local mapId, def = Neighbors.mapAt(session.def, session.neighbors, tx, ty)
  if not def then return nil end
  return math.floor(tx / 2), math.floor(ty / 2), mapId, def
end

-- The map-body block cell a world-block coord sits on, or nil for void / off
-- the layout.  The id of the map (for the caller), its def, and the block
-- coords local to that map.
local function visibleBlockAt(session, worldBx, worldBy)
  local mapId, def, ox, oy =
    Neighbors.mapAt(session.def, session.neighbors, worldBx * 2, worldBy * 2)
  if not def then return nil end
  local bx = math.floor((worldBx * Common.BLOCK_PX - (ox or 0)) / Common.BLOCK_PX)
  local by = math.floor((worldBy * Common.BLOCK_PX - (oy or 0)) / Common.BLOCK_PX)
  if bx < 0 or by < 0 or bx >= def.width or by >= def.height then return nil end
  return mapId, def, bx, by
end

-- Captures the block grid inside the current selection rectangle into the
-- blueprint book, along with any warps and objects within the area.
-- Returns the new blueprint id, or nil.
function Blueprints.capture(ui, session)
  local a, b = ui.selectStart, ui.selectEnd
  if not a or not b then return nil end
  local x0, x1 = math.min(a.bx, b.bx), math.max(a.bx, b.bx)
  local y0, y1 = math.min(a.by, b.by), math.max(a.by, b.by)
  local w = x1 - x0 + 1
  local h = y1 - y0 + 1
  if w <= 0 or h <= 0 or w * h > 4096 then return nil end
  
  -- Capture tiles
  local tiles = {}
  for by = y0, y1 do
    for bx = x0, x1 do
      local _, def, lbx, lby = visibleBlockAt(session, bx, by)
      if def then
        tiles[#tiles + 1] = {
          id = def.blocks[lby * def.width + lbx + 1],
          tileset = def.tileset,
        }
      else
        tiles[#tiles + 1] = false
      end
    end
  end
  
  -- Capture warps and objects within the selection rectangle
  -- Objects/warps are in walk-grid cells (not blocks), so multiply block coords by 2
  local cellX0 = x0 * 2
  local cellX1 = (x1 + 1) * 2 - 1
  local cellY0 = y0 * 2
  local cellY1 = (y1 + 1) * 2 - 1
  
  local warps = {}
  local function collectWarps(def, offX, offY)
    for _, w in ipairs(def and def.warps or {}) do
      local worldX = offX + w.x
      local worldY = offY + w.y
      if worldX >= cellX0 and worldX <= cellX1 and worldY >= cellY0 and worldY <= cellY1 then
        local copy = {}
        for k, v in pairs(w) do copy[k] = v end
        copy.x = worldX - cellX0
        copy.y = worldY - cellY0
        warps[#warps + 1] = copy
      end
    end
  end
  collectWarps(session.def, 0, 0)
  for _, nb in ipairs(session.neighbors or {}) do
    collectWarps(nb.def, math.floor(nb.ox / Common.CELL_PX), math.floor(nb.oy / Common.CELL_PX))
  end
  
  local objects = {}
  local function collectObjects(def, offX, offY)
    for _, o in ipairs(def and def.objects or {}) do
      local worldX = offX + o.x
      local worldY = offY + o.y
      if worldX >= cellX0 and worldX <= cellX1 and worldY >= cellY0 and worldY <= cellY1 then
        local copy = {}
        for k, v in pairs(o) do copy[k] = v end
        copy.x = worldX - cellX0
        copy.y = worldY - cellY0
        objects[#objects + 1] = copy
      end
    end
  end
  collectObjects(session.def, 0, 0)
  for _, nb in ipairs(session.neighbors or {}) do
    collectObjects(nb.def, math.floor(nb.ox / Common.CELL_PX), math.floor(nb.oy / Common.CELL_PX))
  end

  -- Signs ride along like objects (def.signs only: gen-2 readable bgEvents
  -- stay put so a stamp never duplicates one).
  local signs = {}
  local function collectSigns(def, offX, offY)
    for _, s in ipairs(def and def.signs or {}) do
      local worldX = offX + s.x
      local worldY = offY + s.y
      if worldX >= cellX0 and worldX <= cellX1 and worldY >= cellY0 and worldY <= cellY1 then
        local copy = {}
        for k, v in pairs(s) do copy[k] = v end
        copy.x = worldX - cellX0
        copy.y = worldY - cellY0
        signs[#signs + 1] = copy
      end
    end
  end
  collectSigns(session.def, 0, 0)
  for _, nb in ipairs(session.neighbors or {}) do
    collectSigns(nb.def, math.floor(nb.ox / Common.CELL_PX), math.floor(nb.oy / Common.CELL_PX))
  end

  local id = "blueprint_" .. os.time()
  -- Blueprints live in the inventory (its Blueprints tab is the only
  -- container), stored whole so the tab previews the captured grid.
  Inventory.add(ui, {
    kind = "blueprint", id = id, w = w, h = h,
    tiles = tiles, warps = warps, objects = objects, signs = signs
  })
  ui.selectStart, ui.selectEnd = nil, nil
  -- The capture is done: leave rectangle-select and show the inventory's
  -- Blueprints tab so the new blueprint is immediately visible.
  ui.blueprintMode = false
  ui.showPicker = false
  return id
end

-- Paints a blueprint at the given screen point's world block.  Cells can land
-- on any visible laid-out map; cells over open void trigger map creation when
-- a flush host is available, otherwise they are skipped.
function Blueprints.paint(ui, session, bid, mx, my)
  local bp = nil
  for _, e in ipairs(ui.inventory.items) do
    if e.kind == "blueprint" and e.id == bid then bp = e; break end
  end
  if not bp then return false end
  local t = Coords.transform(session.game)
  if not t then return false end
  local tx, ty = Coords.toWorldCell(t, mx, my)
  session.cursorBx = tx - (tx % 2)
  session.cursorBy = ty - (ty % 2)
  local bx0 = math.floor(session.cursorBx / 2)
  local by0 = math.floor(session.cursorBy / 2)
  -- When any stamp cell falls on void, try to create a map covering the
  -- whole bounding rect before stamping.
  local hasVoid = false
  for row = 0, bp.h - 1 do
    for col = 0, bp.w - 1 do
      local wx = bx0 + col
      local wy = by0 + row
      local _, def = Neighbors.mapAt(session.def, session.neighbors,
                                     wx * 2, wy * 2)
      if not def then hasVoid = true; break end
    end
    if hasVoid then break end
  end
  if hasVoid then
    session:createMapAtCursor(bx0, by0, bp.w, bp.h)
  end
  -- Defer the stamp + renderer rebuild to MapOps.paintBlueprint, which also
  -- pushes an undo step so Ctrl+Z / Ctrl+Y move through blueprint stamps.
  return session:paintBlueprint(bp)
end

return Blueprints
