-- mapamap: direct map painting on the live overworld render.
--
-- Press F6 while in the overworld to toggle the overlay.  While open you paint
-- blocks directly onto the map the game is already showing (Factorio-style
-- click-and-drag), select tools from the bottom hotbar, and open the full
-- inventory with E to drag items onto the hotbar.  Changes are saved
-- automatically to the mod save when you close the overlay.
--
-- Architecture: main.lua owns the toggle and the love hook-ups; func/coords.lua
-- maps the mouse to world cells through the live camera; input.lua is the
-- Factorio-style brush; session.lua mixes in the reusable map-editor data
-- operations; components/overlay.lua draws the HUD via the render.hud hook.

local Session = require("mods.mapamap.session")
local Input = require("mods.mapamap.input")
local Overlay = require("mods.mapamap.components.overlay")
local Coords = require("mods.mapamap.func.coords")
local Save = require("mods.mapamap.func.save")
local Snapshot = require("mods.mapamap.func.snapshot")
local Common = require("mods.mapamap.func.common")
local Connections = require("mods.mapamap.func.connections")
local NewMap = require("mods.mapamap.func.new_map")
local MapGrid = require("mods.mapamap.func.map_grid")
local Hotbar = require("mods.mapamap.components.hotbar")

local active = false
local session = nil

-- Walks the game state stack and save data to find the current overworld
-- map ID (same logic as map_editor).
local function currentMapId(game)
  if not game then return nil end

  if game.overworld and game.overworld.map and game.overworld.map.id then
    return game.overworld.map.id
  end

  if game.state and game.state.map and game.state.map.id then
    return game.state.map.id
  end

  local stack = game.stack
  if stack then
    local states = stack.states
    if states then
      for i = #states, 1, -1 do
        local s = states[i]
        if s and s.isOverworld and s.map and s.map.id then
          return s.map.id
        end
      end
    end
  end

  if game.map and game.map.id then return game.map.id end

  local save = game.save
  if save and save.player then
    if save.player.map then return save.player.map end
    if save.player.currentMap then return save.player.currentMap end
  end

  return nil
end

-- Merges connectionsExtra into connections so the engine can use extra
-- connections during neighbor computation. Extra connections are stored in
-- connectionsExtra[dir] as an array; this function makes them visible to the
-- engine by merging them with the primary connection in connections[dir].
local function mergeExtraConnections(mod, data)
  if not data or not data.maps then return end
  for mapId, def in pairs(data.maps) do
    if def.connectionsExtra then
      if not def.connections then def.connections = {} end
      for dir, extras in pairs(def.connectionsExtra) do
        if extras and #extras > 0 then
          local merged = {}
          local primary = def.connections[dir]
          if primary then
            for _, conn in ipairs(Connections.connectionList(primary)) do
              merged[#merged + 1] = conn
            end
          end
          for i = 1, #extras do
            merged[#merged + 1] = extras[i]
          end
          table.sort(merged, function(a, b)
            local ao = a and a.offset or 0
            local bo = b and b.offset or 0
            if ao == bo then
              local am = a and a.map or ""
              local bm = b and b.map or ""
              return am < bm
            end
            return ao < bo
          end)
          if #merged == 1 then
            def.connections[dir] = merged[1]
          elseif #merged > 1 then
            def.connections[dir] = merged
          end
          local entries = {}
          for _, conn in ipairs(merged) do
            entries[#entries + 1] = string.format("%s@%s", tostring(conn.map), tostring(conn.offset or 0))
          end
          mod.log:info("mapamap debug: merged %d extra connection(s) on %s.%s -> %s",
            #extras, mapId, dir, table.concat(entries, ", "))
          mod.log:info("mapamap: merged %d extra connection(s) on %s.%s",
            #extras, mapId, dir)
        end
      end
    end
  end
end

-- Persists every map edited during this session (primary + neighbors + new
-- maps) as minimal diff patches so a reload replays them.  Leaves `session`
-- untouched so the caller may keep using or rebind it.
local function saveMapPatches(mod, s)
  -- Primary map: diff against the original snapshot taken at its open.
  if s.mapChanged and s._originalSnapshot then
    local patch = Snapshot.diff(s.def, s._originalSnapshot)
    if next(patch) then
      for key, value in pairs(patch) do
        Save.updatePatchField(mod, s.mapId, key, value)
      end
    end
  end
  for mapId in pairs(s._sessionDirty or {}) do
    local def = s.data and s.data.maps[mapId]
    local orig = s._sessionOriginals and s._sessionOriginals[mapId]
    if def and orig then
      local patch = Snapshot.diff(def, orig)
      if next(patch) then
        for key, value in pairs(patch) do
          Save.updatePatchField(mod, mapId, key, value)
        end
      end
    end
  end
  for nbId in pairs(s.neighborDirty or {}) do
    local m = s.neighborMaps and s.neighborMaps[nbId]
    local orig = s.neighborOriginals and s.neighborOriginals[nbId]
    if m and m.def and orig then
      local patch = Snapshot.diff(m.def, orig)
      if next(patch) then
        for key, value in pairs(patch) do
          Save.updatePatchField(mod, nbId, key, value)
        end
      end
    end
  end
  -- New maps are stored whole (data.maps has no entry to diff against yet).
  if s._newMaps then
    local newMaps = mod.save:get("mapamap_new_maps", {})
    for id, def in pairs(s._newMaps) do newMaps[id] = def end
    mod.save:set("mapamap_new_maps", newMaps)
  end
end

local function persistSession(mod, game)
  if not session then return end
  saveMapPatches(mod, session)
  Input.saveHotbar(mod)
  Input.saveInventory(mod)
  session = nil
end

-- Applies persisted patches for the session map to live data, then builds a
-- session on it.  Returns the session or nil.
local function ensureConnectedMaps(s)
  if not s then return 0 end
  local created = MapGrid.autofill(s, MapGrid.DEFAULT_DEPTH)
  return created or 0
end

local function openSession(mod, game)
  local mapId = currentMapId(game)
  if not mapId then
    mod.log:warn("mapamap: no overworld map to edit")
    return nil
  end
  local s = Session.new(mod, game, mapId)
  if not s then
    mod.log:error("mapamap: could not create session for %s", mapId)
    return nil
  end
  s:applySavedPatches()
  -- Merge extra connections into primary connections so the engine can use them
  mergeExtraConnections(mod, s.data)
  -- Grid expansion runs on both the initial open and every map-entry: the
  -- session must always have a connected ring around it before edits/draws use
  -- the live map graph.
  ensureConnectedMaps(s)
  -- Hotbar: restore a saved layout, else seed with the first few blocks.
  local saved = mod.save:get("mapamap_hotbar", nil)
  if saved and type(saved) == "table" and #saved > 0 then
    Input.configure(saved)
  else
    Input.configure(nil)
    local seeds = {}
    for _, id in ipairs(s.paletteList or {}) do
      if #seeds >= 8 then break end
      seeds[#seeds + 1] = { kind = "block", id = id }
    end
    Input.configure(seeds)
    Input.saveHotbar(mod)
  end
  Input.applySelection(s)
  -- Lock block slots to this map's tileset immediately so crossing a border
  -- never re-seeds them onto the incoming map's palette (tiles stay stable).
  for i = 1, Hotbar.SLOTS do
    Input.tagBlock(s, Input.hotbar[i])
  end
  Input.loadInventory(mod)
  -- A fresh inventory starts seeded with the default hotbar blocks so the
  -- panel is never empty on first use.
  if #Input.inventory.items == 0 then
    for i = 1, Hotbar.SLOTS do
      if Input.hotbar[i] then Input.addInventory(Input.hotbar[i]) end
    end
  end
  return s
end

local function closeSession(mod, game)
  if session then persistSession(mod, game) end
  Input.reset()
  active = false
end

-- While the overlay is open the player can still walk across map borders, so
-- the session must follow the map the cursor is actually over.  On a change,
-- persist the outgoing map and open a fresh session on the incoming one
-- (hotbar / selection survive, since they live on Input).
local function reconcileSession(mod, game)
  if not session then return end
  local mapId = currentMapId(game)
  if not mapId or mapId == session.mapId then return end
  saveMapPatches(mod, session)
  local s = Session.new(mod, game, mapId)
  if not s then return end
  s:applySavedPatches()
  session = s
  -- Re-point picker/hotbar onto the incoming map's tileset and grow the
  -- connected map ring on entry so the new map always has neighbors to paint on.
  ensureConnectedMaps(session)
  Input.onMapEntry(session)
  Input.applySelection(session)
  -- Re-sync the cursor from the current mouse position so the highlight
  -- doesn't snap to (0,0) until the next physical mouse move event.
  local mx, my = love.mouse.getPosition()
  local t = Coords.transform(game)
  if t then
    local tx, ty = Coords.toWorldCell(t, mx, my)
    session.cursorBx, session.cursorBy = tx, ty
  end
end

-- New-map creation: builds an adjacent map (with reciprocal connection),
-- tracks it for persistence, and switches the session onto it.
local function createAdjacentMap(mod, game, side)
  if not session then return end
  local fromId = session.mapId
  local newId = NewMap.createConnectedMap(session, side)
  if not newId then return end
  -- Hand the previous map off to session tracking so its connection change
  -- (the new edge) is persisted when the overlay closes.
  session._sessionOriginals[fromId] = session._originalSnapshot
  session._sessionEncounters[fromId] = session.originalEncounters
  session._sessionDirty[fromId] = true
  session._newMaps = session._newMaps or {}
  session._newMaps[newId] = Common.deepCopy(session.data.maps[newId])
  session:rebuildNeighbors()
  local data = session.data
  local newDef = data.maps[newId]
  local tileset = data.tilesets[newDef.tileset]
  local MapLoader = require("src.world.MapLoader")
  local m = MapLoader.load(data, newId)
  session.mapId = newId
  session.def = newDef
  session.tileset = tileset
  session.map = m
  session.mapW = newDef.width * Common.BLOCK_PX
  session.mapH = newDef.height * Common.BLOCK_PX
  session.undo = require("mods.mapamap.func.undo").new()
  session.expandShiftL = 0
  session.expandShiftT = 0
  session:rebuildNeighbors()
  session:storeOriginal()
end

local function run(mod)

  -- render.hud: draw the overlay on top of the finished frame while active.
  -- Hooks run as (next, game, viewport); draw our overlay and continue the
  -- chain so lower-priority mods and the vanilla no-op still run.
  mod.hooks:wrap("render.hud", function(nextFn, game, viewport)
    if active and session then
      reconcileSession(mod, game)
      Overlay.draw(session, game, viewport)
    end
    if nextFn then return nextFn(game, viewport) end
  end, 200)

  -- F6 toggles the overlay; while active, keyboard shortcuts are routed to
  -- the overlay (E inventory, P pick, 1-8 slots, N.. new-map edges on the
  -- same keys the editor used is NOT reused here -- we keep it simple).
  do
    local Game = require("src.core.Game")
    local orig = Game.keypressed
    Game.keypressed = function(self, key)
      if active and session then
        reconcileSession(mod, self)
        local consumed = Input.keypressed(session, key)
        if consumed then return end
        if key == "escape" then
          closeSession(mod, self); return
        end
        if key == "f6" then
          closeSession(mod, self); return
        end
      else
        if key == "f6" then
          session = openSession(mod, self)
          if session then
            active = true
            Input.reset()
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
    if not (active and session) then return nextFn(game, ev) end
    reconcileSession(mod, game)
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
      if active and session then
        reconcileSession(mod, session.game)
        if Input.wheelmoved(session, dy) then return end
      end
      if origWheel then return origWheel(self, dx, dy) end
    end
  end

  -- Auto-save on quit, and on save.loaded replay any saved map patches (like
  -- map_editor does) so edits survive a reload.
  mod.events:on("save.loaded", function()
    local patches = mod.save:get("mapamap_patches", {})
    if next(patches) then
      local Data = require("src.core.Data")
      Save.applyPatchesToData(patches, Data)
    end
    -- Replay whole new-map defs.
    local newMaps = mod.save:get("mapamap_new_maps", {})
    if next(newMaps) then
      local Data = require("src.core.Data")
      for id, def in pairs(newMaps) do
        if not Data.maps[id] then Data.maps[id] = def end
      end
    end
    -- Merge extra connections into primary connections so the engine can use them
    local Data = require("src.core.Data")
    mergeExtraConnections(mod, Data)
    -- Any replayed patch may reference grafted foreign blocks -- grow every
    -- touched tileset's atlas from the live defs before maps rebuild, so a
    -- patched map renders its imports instead of drawing blank cells.
    local Graft = require("mods.mapamap.func.graft")
    Graft.materializeAll(Data)
    local MapLoader = require("src.world.MapLoader")
    if MapLoader and MapLoader.invalidateAll then MapLoader.invalidateAll() end
  end)

  mod.log:info("mapamap loaded — F6 to paint directly on the overworld")
end

local Main = function(mod)
  return run(mod)
end

return Main