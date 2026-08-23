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
-- (Tilt.hasProjection()).  DRAMALESS_SHAPE's voxel pipeline is NOT gated: its
-- ground-plane projector (Voxel3D.project) is handed over by the bridge and
-- inverted numerically below, so editing works through the 3D view too.
-- Returned transform values assume the flat blit; a voxel transform instead
-- carries kind = "voxel", the bridge camera snapshot, and focus-local scales.

local ok_R, Renderer = pcall(require, "src.render.Renderer")
local ok_Z, Zoom = pcall(require, "src.render.Zoom")
local ok_T, Tilt = pcall(require, "src.render.Tilt")
local Gen = require("mods.mapamap.engine.gen")
local Bridge = require("mods.mapamap.engine.dramaless_bridge")
local function tiltActive() return ok_T and Tilt.active() end

local Coords = {}

-- ---- voxel (DRAMALESS_SHAPE) inversion ------------------------------------
--
-- projectGround maps ground world-px (wx, wz) -> scene canvas px; the mouse
-- needs the inverse.  No matrix is unpacked: the map is smooth and locally
-- affine, so a Newton iteration seeded at the camera's ground focus with a
-- finite-difference Jacobian converges in a few steps -- and absorbs the
-- WorldCurve ground bend exactly, because it inverts whatever the renderer
-- actually draws rather than an idealized plane.

local PROBE_PX = 24        -- finite-difference step, world px
local STEP_CAP = 2048      -- clamp: above-horizon targets must not run away
local CONVERGED_ERR2 = 25  -- accept when the final projection misses by <= 5 canvas px

local function invertGround(cam, txPx, tyPx)
  local P = cam.projectGround
  local gx, gz = cam.focus[1], cam.focus[3]
  for _ = 1, 6 do
    local p0x, p0y = P(gx, gz)
    local exr, eyr = P(gx + PROBE_PX, gz)
    local zxr, zyr = P(gx, gz + PROBE_PX)
    if not (p0x and exr and zxr) then return nil end
    local j11 = (exr - p0x) / PROBE_PX
    local j12 = (eyr - p0y) / PROBE_PX
    local j21 = (zxr - p0x) / PROBE_PX
    local j22 = (zyr - p0y) / PROBE_PX
    local det = j11 * j22 - j12 * j21
    if math.abs(det) < 1e-9 then return nil end
    local dxp, dyp = txPx - p0x, tyPx - p0y
    local sx = (j22 * dxp - j12 * dyp) / det
    local sy = (j11 * dyp - j21 * dxp) / det
    local len = math.sqrt(sx * sx + sy * sy)
    if len > STEP_CAP then
      sx, sy = sx * STEP_CAP / len, sy * STEP_CAP / len
    end
    gx, gz = gx + sx, gz + sy
    if math.abs(sx) < 0.05 and math.abs(sy) < 0.05 then break end
  end
  local fx, fy = P(gx, gz)
  if not fx then return nil end
  local errX, errY = fx - txPx, fy - tyPx
  if errX * errX + errY * errY > CONVERGED_ERR2 then return nil end
  return gx, gz
end

-- Screen units per world px around one ground point (the LOCAL scale that
-- replaces the flat transform's constant sx/sy under perspective).
local function localScale(cam, wx, wy)
  local kx, ky = cam.unitsToCanvasX, cam.unitsToCanvasY
  local ax = cam.projectGround(wx - 8, wy)
  local bx = cam.projectGround(wx + 8, wy)
  if ax and bx then
    local ay = cam.projectGround(wx, wy - 8)
    local by = cam.projectGround(wx, wy + 8)
    if ay and by then
      return (bx - ax) / 16 / kx, (by - ay) / 16 / ky
    end
    return (bx - ax) / 16 / kx, nil
  end
  return nil
end

-- Builds the editor transform from a Bridge.voxelCamera snapshot.  Exposed
-- for tests: any table with focus/projectGround/unitsToCanvas{X,Y} works.
function Coords.voxelTransform(cam)
  local t = { kind = "voxel", cam = cam }
  t.sx, t.sy = localScale(cam, cam.focus[1], cam.focus[3])
  if not t.sx then t.sx, t.sy = 1, 1 end
  if not t.sy then t.sy = t.sx end
  return t
end

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
  -- DRAMALESS_SHAPE's voxel pass: editing continues through the inverted
  -- ground projector instead of the flat blit math.
  if Bridge.voxelActive() then
    local cam = Bridge.voxelCamera(game)
    if cam then return Coords.voxelTransform(cam) end
    return nil
  end
  -- Any other mod world pipeline (e.g. tiltshift's mesh projection): the
  -- screen matches no transform Coords knows, so editing stays disabled.
  if Bridge.worldRendered() then return nil end
  -- Gen 2: delegate to the generation-aware transform which computes fitScale
  -- through FaithfulRes instead of the Renderer singleton (which Gen 2 never
  -- initialises as a standalone module -- the World composites in Game2:draw).
  if Gen.isGen2() then return Gen.flatTransform(game) end
  if tiltActive() then return nil end
  local ow = game and (game.overworld or game.world)
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
  if t.kind == "voxel" then
    local cam = t.cam
    local gx, gz = invertGround(cam, sxU * cam.unitsToCanvasX,
                                syU * cam.unitsToCanvasY)
    if not gx then return nil end
    return gx, gz
  end
  local wx = t.camx + (sxU - t.wox) / t.sx
  local wy = t.camy + (syU - t.woy) / t.sy
  return wx, wy
end

-- World pixel (input wx, wy) -> screen top-left in LOVE units.
function Coords.toScreen(t, wx, wy)
  if not t then return nil end
  if t.kind == "voxel" then
    local x, y = t.cam.projectGround(wx, wy)
    if not x then return nil end
    return x / t.cam.unitsToCanvasX, y / t.cam.unitsToCanvasY
  end
  local sxU = t.wox + (wx - t.camx) * t.sx
  local syU = t.woy + (wy - t.camy) * t.sy
  return sxU, syU
end

-- The on-screen rect (x, y, w, h, units) a world tile cell occupies.  Under
-- voxel the rect is the LOCAL frame at that cell (projected anchor + local
-- scale) -- callers drawing axis-aligned rects there should prefer blockPoly.
function Coords.cellRect(t, tileX, tileY)
  if not t then return nil end
  if t.kind == "voxel" then
    local wx, wy = tileX * 16, tileY * 16
    local x, y = Coords.toScreen(t, wx, wy)
    if not x then return nil end
    local sx, sy = localScale(t.cam, wx + 8, wy + 8)
    return x, y, 16 * (sx or t.sx), 16 * (sy or t.sy)
  end
  local x, y = Coords.toScreen(t, tileX * 16, tileY * 16)
  return x, y, 16 * t.sx, 16 * t.sy
end

-- The on-screen rect (units) of a whole 2x2-cell block whose top-left cell is
-- (blockCellX, blockCellY).  Blocks are 32px (2 cells) in MAP mode.
function Coords.blockRect(t, blockCellX, blockCellY)
  if not t then return nil end
  if t.kind == "voxel" then
    local wx, wy = blockCellX * 16, blockCellY * 16
    local x, y = Coords.toScreen(t, wx, wy)
    if not x then return nil end
    local sx, sy = localScale(t.cam, wx + 16, wy + 16)
    return x, y, 32 * (sx or t.sx), 32 * (sy or t.sy)
  end
  local x, y = Coords.toScreen(t, blockCellX * 16, blockCellY * 16)
  return x, y, 32 * t.sx, 32 * t.sy
end

-- The four screen corners (x1,y1, x2,y2, x3,y3, x4,y4) of a cellsW x cellsH
-- world-cell rect whose top-left cell is (cellX, cellY).  Flat mode returns
-- an axis-aligned quad; voxel mode projects each corner, so outlines drawn
-- through this follow the perspective ground instead of floating as screens-
-- pace rectangles.  nil when any corner falls off the camera.
function Coords.blockPoly(t, cellX, cellY, cellsW, cellsH)
  if not t then return nil end
  cellsW, cellsH = cellsW or 2, cellsH or 2
  local x0, y0 = cellX * 16, cellY * 16
  local x1, y1 = x0 + cellsW * 16, y0 + cellsH * 16
  local ax, ay = Coords.toScreen(t, x0, y0)
  local bx, by = Coords.toScreen(t, x1, y0)
  local cx, cy = Coords.toScreen(t, x1, y1)
  local dx, dy = Coords.toScreen(t, x0, y1)
  if not (ax and bx and cx and dx) then return nil end
  return ax, ay, bx, by, cx, cy, dx, dy
end

-- The world cell under the mouse cursor (LOVE units (mxU, myU)).  Returns
-- tileX, tileY (integer, may be negative for maps placed left of the root).
function Coords.toWorldCell(t, mxU, myU)
  if not t then return nil end
  local wx, wy = Coords.toWorld(t, mxU, myU)
  if not wx then return nil end
  local tx = math.floor(wx / 16)
  local ty = math.floor(wy / 16)
  return tx, ty
end

return Coords