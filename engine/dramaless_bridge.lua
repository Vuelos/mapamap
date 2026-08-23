-- DramalessBridge: integration surface between mapamap and renderer mods
-- that own the overworld world pass -- concretely DRAMALESS_SHAPE's voxel
-- pipeline (its "voxel" render_pipelines entry).
--
-- Two directions, one file:
--
-- GATE (renderer -> editor).  While a mod world pipeline renders the world,
-- the flat screen<->world blit math Coords.transform is built on no longer
-- describes what is on screen -- the same reason editing gates off under
-- Tilt -- so the overlay hides its GUIs and stops consuming input, and the
-- game's own keys (including the renderer mod's hotkeys) pass through.  The
-- signal is engine-side and mod-agnostic: Pipelines.worldPipeline() names
-- whichever registered drawWorld pipeline currently owns the pass.
--
-- NOTIFY (editor -> renderer).  mapamap edits Data.maps defs in place and
-- never walks Map.setBlock, so the engine's world.block_replaced event --
-- the hook DRAMALESS_SHAPE rebuilds its chunk meshes on -- never fires for
-- an editor paint.  The bridge reaches the installed renderer through its
-- exports (the sanctioned cross-mod channel; DRAMALESS_SHAPE exports lib,
-- its own module loader) and drives ChunkMesher.refresh per edited map:
-- stale meshes keep drawing while replacements cook, so a paint shows up in
-- the voxel view live instead of on the next map re-entry.  Object / sign /
-- warp edits deliberately do NOT notify: they change no geometry.
--
-- PICK (editor -> renderer, the inverse of GATE).  While DRAMALESS_SHAPE's
-- "voxel" pipeline owns the world pass the screen shows a perspective ground
-- plane, so Coords cannot use the flat blit math.  voxelCamera() hands Coords
-- a snapshot of the live scene camera -- eye/focus/fov plus a projectGround()
-- closure over Voxel3D.project(wx, 0, wz) and the canvas<->screen-unit scales
-- -- and Coords inverts it numerically to pick world cells under the mouse.
-- Only the "voxel" pipeline qualifies: other mod pipelines (tiltshift's mesh)
-- project differently and stay gated off entirely.
--
-- It also widens the runtime neighbor render radius while a session is open
-- (constants.world.neighborHops is re-read by every OverworldState:
-- rebuildNeighbors) so the expanded grid around the cursor renders in the
-- drawn set -- flat neighbor strips and the voxel scene alike -- and
-- restores the previous value on close.  Gen 2's World hardcodes its hop
-- count, so the radius work is Gen 1 only.

local Gen = require("mods.mapamap.engine.gen")

local Bridge = {}

-- connection hops rendered around the current map while a session is open
-- (vanilla default is 2)
Bridge.SESSION_HOPS = 4

local modApi = nil        -- mapamap's api object, set by init()
local savedHops = nil     -- radius undo record set by expandRenderRadius

-- lazy src.render.Pipelines resolve (pcall like coords.lua: a headless
-- harness has no renderer singleton)
local pipelinesMod = nil
local function pipelines()
  if pipelinesMod == nil then
    local ok, P = pcall(require, "src.render.Pipelines")
    pipelinesMod = ok and P or false
  end
  return pipelinesMod or nil
end

-- Test seam: drop every cached resolve so a suite can re-stub the engine.
function Bridge._resetForTest()
  pipelinesMod = nil
  savedHops = nil
end

-- Binds the mod api used for cross-mod lookups.  Called once from main.lua;
-- every entry point degrades to a no-op when it was never called (tests).
function Bridge.init(mod)
  modApi = mod
end

-- True while a mod-owned world pipeline (DRAMALESS_SHAPE's "voxel", or any
-- other registered drawWorld pipeline) is rendering the overworld world
-- pass.  The overlay must hide its GUIs and release input while this holds.
function Bridge.worldRendered()
  local P = pipelines()
  if not P then return false end
  local ok, id = pcall(P.worldPipeline)
  return (ok and id ~= nil) and true or false
end

-- True only while DRAMALESS_SHAPE's voxel pipeline is the one drawing the
-- world: the single pipeline whose projection Coords can invert for picking.
function Bridge.voxelActive()
  local P = pipelines()
  if not P then return false end
  local ok, id = pcall(P.worldPipeline)
  return (ok and id == "voxel") and true or false
end

-- The chunk mesher of an installed DRAMALESS_SHAPE, or nil.  Resolved fresh
-- every call: mod.find is a loader table lookup and their V.require memoizes
-- modules, so there is nothing worth caching across a mod hot-reload.
-- Overridable field so tests can inject a recorder.
Bridge._resolveMesher = function()
  if not (modApi and type(modApi.find) == "function") then return nil end
  local ok, found = pcall(modApi.find, "DRAMALESS_SHAPE")
  local lib = ok and found and found.exports and found.exports.lib or nil
  if not (lib and type(lib.require) == "function") then return nil end
  local okM, mesher = pcall(lib.require, "ChunkMesher")
  if not okM then return nil end
  return mesher
end

-- Rebuild one map's voxel meshes in place: ChunkMesher.refresh marks the
-- cached meshes stale and keeps them DRAWING while the replacements cook,
-- which is exactly the behavior a live paint wants (no whole-world blink).
function Bridge.refreshMap(mapId)
  if not mapId then return end
  local mesher = Bridge._resolveMesher()
  if mesher and mesher.refresh then pcall(mesher.refresh, mapId) end
end

-- The voxel scene surface of an installed DRAMALESS_SHAPE: Voxel3D's
-- world->canvas projector plus the AntiAlias factor the pass expanded by.
-- Resolved fresh every call (same reasoning as _resolveMesher).  Overridable
-- field so tests can inject a fake camera projector.
Bridge._resolveVoxel = function()
  if not (modApi and type(modApi.find) == "function") then return nil end
  local ok, found = pcall(modApi.find, "DRAMALESS_SHAPE")
  local lib = ok and found and found.exports and found.exports.lib or nil
  if not (lib and type(lib.require) == "function") then return nil end
  local okV, V3D = pcall(lib.require, "Voxel3D")
  if not okV or not (V3D and type(V3D.project) == "function"
                      and type(V3D.size) == "function") then
    return nil
  end
  local okAA, AA = pcall(lib.require, "AntiAlias")
  return {
    -- live camera fields (eye/focus/fovY) set by each frame's beginScene;
    -- read lazily by the caller so a snapshot always matches its frame
    state = V3D,
    size = function()
      local okS, w, h = pcall(V3D.size)
      if not okS then return nil end
      return w, h
    end,
    -- ground-plane projection in SCENE CANVAS pixels; wy is the world-pixel
    -- Y passed as Z (the same convention drawFx anchors use).  nil when the
    -- point is behind the camera.
    projectGround = function(wx, wz)
      local okP, x, y = pcall(V3D.project, wx, 0, wz)
      if not okP then return nil end
      return x, y
    end,
    aaFactor = function()
      if okAA and AA and type(AA.factor) == "function" then
        local okF, f = pcall(AA.factor)
        if okF and f and f > 0 then return f end
      end
      return 1
    end,
  }
end

-- Snapshot of the live voxel camera for Coords' picking math, or nil when
-- editing through the voxel view is impossible right now (pipeline not the
-- voxel one, scene never rendered this frame, no renderer mod installed).
-- All values are plain numbers/closures so Coords stays engine-free.
function Bridge.voxelCamera(_game)
  if not Bridge.voxelActive() then return nil end
  local vx = Bridge._resolveVoxel()
  if not vx then return nil end
  local W, H = vx.size()
  if not (W and H and W > 4 and H > 4) then return nil end
  local st = vx.state
  local eye, focus, fov = st.eye, st.focus, st.fovY
  if not (type(eye) == "table" and #eye >= 3
          and type(focus) == "table" and #focus >= 3 and fov) then
    return nil
  end
  local dpiX, dpiY = 1, 1
  if love and love.graphics and love.graphics.getDimensions then
    local okD, ww, wh = pcall(love.graphics.getDimensions)
    if okD and ww and ww > 0 and wh and wh > 0 then
      if love.graphics.getPixelDimensions then
        local okP, pw, ph = pcall(love.graphics.getPixelDimensions)
        if okP and pw and pw > 0 and ph and ph > 0 then
          dpiX, dpiY = pw / ww, ph / wh
        end
      end
    end
  end
  local aa = vx.aaFactor() or 1
  if aa <= 0 then aa = 1 end
  return {
    eye = { eye[1], eye[2], eye[3] },
    -- focus sits ON the ground plane (the camera aims at it), so its XZ is
    -- the natural Newton seed for picking
    focus = { focus[1], focus[2], focus[3] },
    fov = fov,
    canvasW = W,
    canvasH = H,
    unitsToCanvasX = dpiX * aa,
    unitsToCanvasY = dpiY * aa,
    projectGround = vx.projectGround,
  }
end

-- Drop every cached voxel mesh (bulk data changes: patch replay).  Cheap
-- when nothing was ever meshed.
function Bridge.invalidateAll()
  local mesher = Bridge._resolveMesher()
  if mesher and mesher.invalidate then pcall(mesher.invalidate) end
end

-- Block-edit notification from the domain operations.  mapId nil means the
-- session's primary map was edited; a laid-out map id means that neighbor
-- was.  Called after the def mutation landed.
function Bridge.edited(session, mapId)
  Bridge.refreshMap(mapId or (session and session.mapId))
end

-- Several maps touched by ONE operation (map creation wires reciprocal
-- connections into every flush contact).  Deduped; no implicit primary.
function Bridge.editedMaps(_, ids)
  if type(ids) ~= "table" then return end
  local seen = {}
  for _, id in ipairs(ids) do
    if id and not seen[id] then
      seen[id] = true
      Bridge.refreshMap(id)
    end
  end
end

-- Widens the rendered neighbor ring for the editing session.  Never lowers
-- a value a player or another mod raised above SESSION_HOPS (that case
-- records a no-op so restore stays symmetric).  Safe to call when the game
-- or overworld is unavailable: everything degrades to a no-op.
function Bridge.expandRenderRadius(game)
  if savedHops then return end
  if Gen.isGen2() then
    savedHops = { noop = true }
    return
  end
  local data = game and game.data
  if not data then
    savedHops = { noop = true }
    return
  end
  local constants = data.constants
  local world = constants and constants.world
  local current = world and world.neighborHops
  if current ~= nil and current >= Bridge.SESSION_HOPS then
    savedHops = { noop = true }
    return
  end
  savedHops = { value = current }
  if not constants then constants = {}; data.constants = constants end
  if not constants.world then constants.world = {} end
  constants.world.neighborHops = Bridge.SESSION_HOPS
  -- take effect on the live overworld immediately instead of waiting for
  -- the next zoom / map change
  local ok, ow = pcall(Gen.overworld, game)
  if ok and ow and ow.rebuildNeighbors then pcall(ow.rebuildNeighbors, ow) end
end

-- Undoes expandRenderRadius exactly (value back, key removed when there was
-- none) and re-derives the rendered set.
function Bridge.restoreRenderRadius(game)
  local record = savedHops
  savedHops = nil
  if not record or record.noop then return end
  local data = game and game.data
  local world = data and data.constants and data.constants.world
  if world and world.neighborHops == Bridge.SESSION_HOPS then
    if record.value == nil then
      world.neighborHops = nil
    else
      world.neighborHops = record.value
    end
  end
  if not (game and game.data) then return end
  local ok, ow = pcall(Gen.overworld, game)
  if ok and ow and ow.rebuildNeighbors then pcall(ow.rebuildNeighbors, ow) end
end

return Bridge
