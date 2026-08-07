-- Screen <-> world coordinate mapping for mapamap's live-render overlay.
--
-- mapamap paints directly onto the overworld the player is already looking at,
-- so it must convert the on-screen mouse position into the world cell under
-- the cursor, and project a highlighted cell back out for the overlay cursor.
--
-- The mapping mirrors src/render/Renderer.endFrame's flat world blit: the world
-- pass is a vw x vh canvas (Renderer:worldViewSize) centred in the window at
-- the zoomed scale and blitted with an integer letterbox origin.  The camera
-- (OverworldController.camera) holds the world-pixel origin of that canvas's
-- top-left corner, so:
--
--     screenUnit = wox + (worldPx - cam.x) * sx
--     worldPx    = cam.x + (screenUnit - wox) / sx
--
-- where sx = sp/dpiX, sy = sp/dpiY and sp = Zoom.scale(fitScale).
--
-- Tilt mode projects the ground plane through a perspective mesh, so no single
-- affine matrix describes it here; editing is gated off while tilt is active
-- (Tilt.hasProjection()).  Returned transform values assume the flat blit.

local Renderer = require("src.render.Renderer")
local Zoom = require("src.render.Zoom")
local Tilt = require("src.render.Tilt")

local Coords = {}

local function metrics()
  local ww, wh = love.graphics.getDimensions()
  local pw, ph = ww, wh
  if love.graphics.getPixelDimensions then
    pw, ph = love.graphics.getPixelDimensions()
  end
  local dx, dy = 1, 1
  if ww > 0 and pw > 0 then dx = pw / ww end
  if wh > 0 and ph > 0 then dy = ph / wh end
  return ww, wh, pw, ph, dx, dy
end

-- Returns the flat transform for the current frame, or nil when editing must
-- be disabled (tilt projection or no camera).  Table fields:
--   camx, camy, vw, vh, sp, sx, sy, wox, woy  (sx, sy = units per world px)
function Coords.transform(game)
  if Tilt.active() then return nil end
  local ow = game and game.overworld
  local cam = ow and ow.camera
  if not cam then return nil end

  local ww, wh, pw, ph, dx, dy = metrics()
  local Sp = Renderer:fitScale()
  local sp = Zoom.scale(Sp)
  local sx, sy = sp / dx, sp / dy
  local vw, vh = Renderer:worldViewSize()
  local wox = math.floor((pw - vw * sp) / 2) / dx
  local woy = math.floor((ph - vh * sp) / 2) / dy
  return {
    camx = cam.x, camy = cam.y,
    vw = vw, vh = vh, sp = sp, sx = sx, sy = sy,
    wox = wox, woy = woy,
  }
end

-- Screen (LOVE units) point -> world pixel.  Returns wx, wy.
function Coords.toWorld(t, sxU, syU)
  if not t then return nil end
  local wx = t.camx + (sxU - t.wox) / t.sx
  local wy = t.camy + (syU - t.woy) / t.sy
  return wx, wy
end

-- World pixel (input wx, wy) -> screen top-left in LOVE units.
function Coords.toScreen(t, wx, wy)
  if not t then return nil end
  local sxU = t.wox + (wx - t.camx) * t.sx
  local syU = t.woy + (wy - t.camy) * t.sy
  return sxU, syU
end

-- The on-screen rect (x, y, w, h, units) a world tile cell occupies.
function Coords.cellRect(t, tileX, tileY)
  if not t then return nil end
  local x, y = Coords.toScreen(t, tileX * 16, tileY * 16)
  return x, y, 16 * t.sx, 16 * t.sy
end

-- The on-screen rect (units) of a whole 2x2-cell block whose top-left cell is
-- (blockCellX, blockCellY).  Blocks are 32px (2 cells) in MAP mode.
function Coords.blockRect(t, blockCellX, blockCellY)
  if not t then return nil end
  local x, y = Coords.toScreen(t, blockCellX * 16, blockCellY * 16)
  return x, y, 32 * t.sx, 32 * t.sy
end

-- The world cell under the mouse cursor (LOVE units (mxU, myU)).  Returns
-- tileX, tileY (integer, may be negative for maps placed left of the root).
function Coords.toWorldCell(t, mxU, myU)
  if not t then return nil end
  local wx, wy = Coords.toWorld(t, mxU, myU)
  local tx = math.floor(wx / 16)
  local ty = math.floor(wy / 16)
  return tx, ty
end

return Coords