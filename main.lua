-- mapamap: direct map painting on the live overworld render.
--
-- Press F6 while in the overworld to toggle the overlay.  While open you paint
-- blocks directly onto the map the game is already showing (Factorio-style
-- click-and-drag), select tools from the bottom hotbar, and open the full
-- inventory with E to drag items onto the hotbar.  Changes are saved
-- automatically to the mod save when you close the overlay.
--
-- Architecture: main.lua owns the toggle and the love hook-ups only; the
-- session lifecycle (open/close/border reconcile/grid growth/persistence)
-- lives in controllers/session_manager.lua; engine/coords.lua maps the mouse
-- to world cells through the live camera; controllers/input.lua routes events;
-- controllers/editor_tools.lua owns the brush drag state; domain/edit_session.lua
-- mixes in the reusable map-editor data operations; components/overlay.lua
-- draws the HUD via the render.hud hook.

local WorldAdapter = require("mods.mapamap.engine.world_adapter")
local Input = require("mods.mapamap.controllers.input")
local Overlay = require("mods.mapamap.components.overlay")
local SessionManager = require("mods.mapamap.controllers.session_manager")
local Gen = require("mods.mapamap.engine.gen")
local Bridge = require("mods.mapamap.engine.dramaless_bridge")

-- Safe xpcall error handler: the game's mod sandbox strips `debug`, so a bare
-- `debug.traceback` (evaluated as the 2nd arg to xpcall) raises "attempt to
-- index nil" OUTSIDE the protected call and hard-crashes the game.  This only
-- touches `debug` lazily, falling back to tostring when it is unavailable.
local function tb(err) return (debug and debug.traceback or tostring)(err) end

local function logCrash(mod, where, err)
  local msg = "[" .. tostring(where) .. "] " .. tostring(err) .. "\n" .. tb(err)
  -- Best-effort, never let the logger itself crash the handler.
  pcall(function() if mod and mod.log then mod.log:error("mapamap crash %s: %s", tostring(where), tostring(err)) end end)
  pcall(function() if io and io.stderr then io.stderr:write("MAPAMAP_CRASH " .. msg .. "\n") end end)
  pcall(function()
    if love and love.filesystem and love.filesystem.write then
      love.filesystem.write("mapamap_crash.log", msg)
    end
  end)
  pcall(function()
    local dir = (love and love.filesystem and love.filesystem.getSaveDirectory) and love.filesystem.getSaveDirectory() or "."
    local f = io.open(dir .. "/mapamap_crash.log", "w")
    if f then f:write(msg); f:close() end
  end)
  pcall(function()
    local f = io.open("mapamap_crash.log", "w")
    if f then f:write(msg); f:close() end
  end)
end

local function run(mod)
  Bridge.init(mod)
  -- Hooks run as (next, game, viewport); draw our overlay and continue the
  -- chain so lower-priority mods and the vanilla no-op still run.
  local firstDrawLogged = false
  mod.hooks:wrap("render.hud", function(nextFn, game, viewport)
    if SessionManager.active and SessionManager.session then
      if not firstDrawLogged then
        firstDrawLogged = true
        mod.log:info("mapamap: first overlay draw (gen2=%s)", tostring(Gen.isGen2()))
      end
      SessionManager.reconcile(game)
      local session = SessionManager.session
      -- The overlay draws over whichever pipeline rendered the world this
      -- frame.  Under DRAMALESS_SHAPE's voxel pass Coords hands back a
      -- perspective transform (engine/coords.lua), so painting works through
      -- the 3D view exactly like the flat one; other mod pipelines still gate
      -- editing off inside Coords (transform nil -> world draws no-op).
      do
        local ok, err = xpcall(function()
          Overlay.draw(session, game, viewport)
        end, tb)
        if not ok then logCrash(mod, "render.hud", err) end
      end
      -- Deferred live rebakes are canvas work for the FLAT path; flush them
      -- regardless of which pipeline drew this frame.
      WorldAdapter.flushLiveRebuild(session)
      -- The vanilla world render runs after the overlay.  If it raises (Lua or
      -- otherwise), Hooks:call re-raises it to the engine and the game hard
      -- stops with no message.  Catch + log it here so a vanilla-render failure
      -- becomes a logged error instead of a crash, and we learn the cause.
      local nok, nerr = pcall(nextFn, game, viewport)
      if not nok then logCrash(mod, "render.hud.nextFn", nerr) end
      return
    end
    if nextFn then
      local nok, nerr = pcall(nextFn, game, viewport)
      if not nok then logCrash(mod, "render.hud.nextFn(inactive)", nerr) end
      return
    end
  end, 200)

  -- F6 toggles the overlay; while active, keyboard shortcuts are routed to
  -- the overlay (E inventory, P pick, 1-8 slots, N.. new-map edges on the
  -- same keys the editor used is NOT reused here -- we keep it simple).
  do
    local Game = require("src.core.Game")
    local orig = Game.keypressed
    Game.keypressed = function(self, key)
      if SessionManager.active and SessionManager.session then
        SessionManager.reconcile(self)
        local consumed = Input.keypressed(SessionManager.session, key)
        if consumed then return end
        if key == "escape" then
          SessionManager.close(); return
        end
        if key == "f6" then
          SessionManager.close(); return
        end
      else
        if key == "f6" then
          local ok, err = xpcall(function()
            SessionManager.open(mod, self)
          end, tb)
          if not ok then
            logCrash(mod, "f6-open", err)
          else
            mod.log:info("mapamap: F6 open %s (gen2=%s)", SessionManager.active and "OK" or "no-session", tostring(Gen.isGen2()))
          end
          return
        end
      end
      return orig(self, key)
    end
  end

  -- Mouse routing: the mod sandbox blocks direct love.* assignment, so we
  -- use the sanctioned input.pointer hook for press/release/move.  Wheel has
  -- no pointer event, so we wrap the Game method directly (requires
  -- engine_internals, already granted in the manifest).
  mod.hooks:wrap("input.pointer", function(nextFn, game, ev)
    if not (SessionManager.active and SessionManager.session) then return nextFn(game, ev) end
    SessionManager.reconcile(game)
    local session = SessionManager.session
    if ev.source == "mouse" then
      if ev.phase == "pressed" then
        if Input.mousepressed(session, game, ev.x, ev.y, ev.button) then return true end
      elseif ev.phase == "released" then
        if Input.mousereleased(session, ev.x, ev.y, ev.button) then return true end
      elseif ev.phase == "moved" then
        if Input.mousemoved(session, ev.x, ev.y) then return true end
      elseif ev.phase == "cancelled" then
        -- Focus loss / input recovery retires every live pointer; clear the
        -- mod's held buttons so the brush cannot stay armed without a release.
        Input.cancelled()
      end
    end
    return nextFn(game, ev)
  end)

  do
    local Game = require("src.core.Game")
    local origWheel = Game.wheelmoved
    function Game:wheelmoved(dx, dy)
      if SessionManager.active and SessionManager.session then
        SessionManager.reconcile(SessionManager.session.game)
        if Input.wheelmoved(SessionManager.session, dy) then return end
      end
      if origWheel then return origWheel(self, dx, dy) end
    end
  end

  -- On save.loaded, replay any saved map patches so edits survive a reload
  mod.events:on("save.loaded", function()
    SessionManager.replayPatches(mod)
  end)

  mod.log:info("mapamap loaded - F6 to paint directly on the overworld")
end

local Main = function(mod)
  return run(mod)
end

return Main