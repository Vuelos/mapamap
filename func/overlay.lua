-- Map border overlay: outlines every laid-out map (via MapGrid.layout) in
-- world-pixel coordinates, each tagged with its (complete) map name on a white
-- chip, while the border toggle (Input.showMapBorders) is enabled.  Each
-- connection and extra connection is drawn as a white marker INSIDE the map,
-- sized to its exact block offset and seam span (size), with the destination
-- map's name written across it (vertically on the side edges).  The styling
-- mirrors the map_editor mod's map-edge drawing: green outlines (current map
-- ringed in yellow) and orange primary-connection borders (magenta for extras).
-- This is a focused draw module following the func/ convention;
-- components/overlay.lua owns the global draw orchestration and calls into
-- here.  Draws in LOVE screen units (the caller has already pushed an identity
-- matrix via push("all") + origin()).

local Coords = require("mods.mapamap.func.coords")
local Common = require("mods.mapamap.func.common")
local MapGrid = require("mods.mapamap.func.map_grid")
local Text = require("mods.mapamap.components.text")
local Input = require("mods.mapamap.input")

local Borders = {}

-- Layout reach used for the border overlay: show the whole reachable cluster,
-- not just the immediate ring around the session map.
Borders.LAYOUT_HOPS = 100

-- map_editor's connection-silhouette palette (renderer/drawing.lua): green
-- edges with the focused/selected element highlighted in yellow.
local GREEN = { 0.2, 1, 0.4 }
local YELLOW = { 1, 1, 0 }
-- Connection borders: orange for the primary slot, magenta for editor-only extras.
local PRIMARY = { 1, 0.6, 0.1 }
local EXTRA = { 1, 0.3, 0.9 }
-- High-contrast chip for the map-name label (dark ink drawn on white).
local WHITE_BG = { 1, 1, 1, 0.9 }

-- Depth (world px) a connection marker extends inward from the map edge.
local CONN_DEPTH = Common.BLOCK_PX * 0.5

-- Draws `str` centered at (cx, cy), optionally rotated 90° (vertical), with an
-- optional white chip behind it.  Dark ink is used so it reads on the white
-- connection marker without needing its own background.
local function drawLabelCentered(font, str, cx, cy, vertical, bg)
  local glyphW = (font.width and font.width(str)) or (#str * 8)
  local tw = glyphW
  local th = 8
  love.graphics.push()
  love.graphics.translate(cx, cy)
  if vertical then love.graphics.rotate(-math.pi / 2) end
  if bg and bg[4] and bg[4] > 0 then
    love.graphics.setColor(bg[1], bg[2], bg[3], bg[4])
    love.graphics.rectangle("fill", -tw / 2 - 1, -th / 2 - 1, tw + 2, th + 2)
  end
  love.graphics.setColor(0.05, 0.05, 0.09, 1)
  font.draw(str, -tw / 2, -th / 2)
  love.graphics.pop()
  love.graphics.setColor(1, 1, 1, 1)
end

-- Draws one connection as a white marker INSIDE the map, sized to its block
-- offset and seam span (size), with the destination map's name written across
-- it (vertically on the side edges).  A thin colored border marks primaries
-- (orange) versus editor-only extras (magenta).
local function drawConnection(session, t, dir, worldX, worldY, worldW, worldH, conn, isExtra)
  local off = conn.offset or 0
  local sz = conn.size
  if not sz then
    -- Legacy size-less connection: assume it spans the whole side.
    sz = (dir == "north" or dir == "south")
         and (worldW / Common.BLOCK_PX) or (worldH / Common.BLOCK_PX)
  end
  local B = Common.BLOCK_PX
  local d = CONN_DEPTH
  -- White marker rect, inside the map just off the relevant edge.
  local x0, y0, w, h
  if dir == "north" then
    x0, y0, w, h = worldX + off * B, worldY, sz * B, d
  elseif dir == "south" then
    x0, y0, w, h = worldX + off * B, worldY + worldH - d, sz * B, d
  elseif dir == "west" then
    x0, y0, w, h = worldX, worldY + off * B, d, sz * B
  else -- east
    x0, y0, w, h = worldX + worldW - d, worldY + off * B, d, sz * B
  end
  local sx0, sy0 = Coords.toScreen(t, x0, y0)
  local sx1, sy1 = Coords.toScreen(t, x0 + w, y0 + h)
  if not sx0 or not sx1 then return end
  local rx = math.min(sx0, sx1)
  local ry = math.min(sy0, sy1)
  local rw = math.abs(sx1 - sx0)
  local rh = math.abs(sy1 - sy0)
  -- White fill = the connection's size/offset footprint.
  love.graphics.setColor(1, 1, 1, 0.92)
  love.graphics.rectangle("fill", rx, ry, rw, rh)
  -- Thin colored border: orange primary, magenta extra.
  local col = isExtra and EXTRA or PRIMARY
  love.graphics.setColor(col[1], col[2], col[3], 0.9)
  love.graphics.setLineWidth(1)
  love.graphics.rectangle("line", rx, ry, rw, rh)
  -- Destination name, vertical on the side edges.
  local destDef = session.data.maps[conn.map]
  local name = (destDef and destDef.name) or tostring(conn.map or "?")
  drawLabelCentered(session.font, name, rx + rw / 2, ry + rh / 2,
                    (dir == "west" or dir == "east"), nil)
end

-- Draws an outline + name tag for every map in the layout, plus a band on each
-- edge for every primary and extra connection (offset/size-correct).  No-op
-- when the toggle is off, there is no live camera transform, or the layout is
-- missing.
function Borders.draw(session, game)
  if not Input.showMapBorders then return end
  if not session or not session.data or not session.data.maps then return end
  local t = Coords.transform(game)
  if not t then return end
  local layout = MapGrid.layout(session.data.maps, session.mapId, Borders.LAYOUT_HOPS)
  if not layout then return end
  for _, r in ipairs(layout) do
    local bx, by, bw, bh = r.x, r.y, r.w, r.h
    local worldX, worldY = bx * Common.BLOCK_PX, by * Common.BLOCK_PX
    local worldW, worldH = bw * Common.BLOCK_PX, bh * Common.BLOCK_PX
    local sx1, sy1 = Coords.toScreen(t, worldX, worldY)
    local sx2, sy2 = Coords.toScreen(t, worldX + worldW, worldY + worldH)
    if sx1 and sx2 then
      local rectX, rectY = sx1, sy1
      local rectW, rectH = sx2 - sx1, sy2 - sy1
      local isCurrent = r.id == session.mapId
      local col = isCurrent and YELLOW or GREEN
      -- Faint fill + bright outline, echoing map_editor's edge silhouette.
      love.graphics.setColor(col[1], col[2], col[3], isCurrent and 0.12 or 0.1)
      love.graphics.rectangle("fill", rectX, rectY, rectW, rectH)
      love.graphics.setColor(col[1], col[2], col[3], isCurrent and 0.95 or 0.8)
      love.graphics.setLineWidth(isCurrent and 2 or 1)
      love.graphics.rectangle("line", rectX, rectY, rectW, rectH)

      -- Connection bands on every side (primary slots + editor-only extras).
      local def = r.def or session.data.maps[r.id]
      if def then
        for _, dir in ipairs(Common.DIRS) do
          local all = Common.connectionsOn(def, dir)
          local extraSet = {}
          local ex = def.connectionsExtra and def.connectionsExtra[dir]
          if ex then for _, c in ipairs(ex) do extraSet[c] = true end end
          local seen = {}
          for _, conn in ipairs(all) do
            if not seen[conn] then
              seen[conn] = true
              drawConnection(session, t, dir, worldX, worldY, worldW, worldH,
                             conn, not not extraSet[conn])
            end
          end
        end
      end

      -- Map name tag (complete, white chip for contrast), centered on the map.
      local name = (def and def.name) or tostring(r.id)
      local tw = (session.font.width and session.font.width(name)) or (#name * 8)
      local lx = rectX + rectW / 2 - tw / 2
      local ly = rectY + rectH / 2 - 4
      Text.label(session.font, name, lx, ly, 1, { bg = WHITE_BG, padX = 2, padY = 1 })
    end
  end
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.setLineWidth(1)
end

return Borders
