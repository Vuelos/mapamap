-- SessionManager: lifecycle for the direct-paint overlay session.
--
-- Owns opening a session over the current overworld map, closing it (persisting
-- every edited map as diff patches to the mod save), reconciling the session
-- when the player walks across a map border, expanding the connected map grid
-- on open/entry, creating adjacent maps on demand, and replaying persisted
-- patches when a save loads.  main.lua stays a thin hook-wiring entry point and
-- delegates all session work here.
--
-- The overlay is non-modal: the player keeps walking while editing, so the
-- session must follow the map under the cursor (reconcile) and every edit has
-- to be visible immediately (WorldAdapter.flushLiveRebuild on the draw frame).

local EditSession = require("mods.mapamap.domain.edit_session")
local WorldAdapter = require("mods.mapamap.engine.world_adapter")
local Input = require("mods.mapamap.controllers.input")
local Coords = require("mods.mapamap.engine.coords")
local Save = require("mods.mapamap.storage.patch_saver")
local Snapshot = require("mods.mapamap.domain.snapshot")
local Connections = require("mods.mapamap.domain.connections")
local MapGrid = require("mods.mapamap.domain.map_grid")
local Gen = require("mods.mapamap.engine.gen")
local Hotbar = require("mods.mapamap.components.hotbar")

local Manager = {
  mod = nil,     -- the mod context the active session belongs to
  active = false,
  session = nil,
}

-- Walks the game state stack and save data to find the current overworld
-- map ID (same logic as map_editor).
function Manager.currentMapId(game)
  if not game then return nil end

  -- Gen 1: game.overworld is the live OverworldState (or the Gen2Compat facade).
  if game.overworld and game.overworld.map and game.overworld.map.id then
    return game.overworld.map.id
  end

  -- Gen 2 native: the World lives at game.world, not game.overworld.
  if game.world and game.world.map and game.world.map.id then
    return game.world.map.id
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
  -- Gen 2 save: position is at save.position, not save.player.
  if save and save.position and save.position.map then
    return save.position.map
  end

  return nil
end

-- Persists every map edited during this session (primary + neighbors + new
-- maps) as minimal diff patches so a reload replays them.  Leaves `session`
-- untouched so the caller may keep using or rebind it.
function Manager.saveMapPatches(mod, s)
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

-- Applies saved patches for the session map to live data, then grows the
-- connected map grid (closes open voids around the loaded map).
function Manager.ensureConnectedMaps(s)
  if not s then return 0 end
  local created = MapGrid.autofill(s, MapGrid.DEFAULT_DEPTH)
  return created or 0
end

-- Re-points the controller's hotbar onto a fresh session: restores a saved
-- layout (or seeds the palette), tags the slots for the session tileset, and
-- loads the persistent inventory collection.
function Manager.seedInput(mod, s)
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
  for i = 1, Hotbar.SLOTS do
    Input.tagBlock(s, Input.hotbar[i])
  end
  Input.loadInventory(mod)
  if #Input.inventory.items == 0 then
    for i = 1, Hotbar.SLOTS do
      if Input.hotbar[i] then Input.addInventory(Input.hotbar[i]) end
    end
  end
end

-- Resolve the data registry to edit against (handles the Gen 1 vs Gen 2 split).
function Manager.resolveData(game)
  local data = game.data
  local ok, w = pcall(Gen.overworld, game)
  local world = ok and w
  local merged = {}
  if data then for k, v in pairs(data) do merged[k] = v end end
  if world then
    merged.maps = world.maps or merged.maps
    merged.tilesets = world.tilesets or merged.tilesets
  end
  if not merged.maps then
    local Data = require("src.core.Data")
    if Data and Data.maps then merged = Data end
  end
  return merged
end

-- Opens a session over the current overworld map and activates the overlay.
-- Returns true when a session was created.  The overlay stays non-modal: the
-- game keeps running underneath.
function Manager.open(mod, game)
  local mapId = Manager.currentMapId(game)
  if not mapId then
    mod.log:warn("mapamap: no overworld map to edit")
    return false
  end

  local s = EditSession.new(mod, game, mapId, Manager.resolveData(game))
  if not s then
    mod.log:error("mapamap: could not create session for %s", mapId)
    return false
  end
  Manager.mod = mod
  WorldAdapter.applySavedPatches(s)
  Connections.mergeExtraConnections(mod, s.data)
  local okExpand, expandErr = pcall(Manager.ensureConnectedMaps, s)
  if not okExpand then
    mod.log:warn("mapamap: grid expansion failed on open: %s", tostring(expandErr))
  end
  -- Gen 2: invalidate cached map images so newly created maps' collision
  -- and render data are picked up on the next draw frame.
  if Gen.isGen2() then
    Gen.invalidateAll(s.data, game)
  end
  Manager.seedInput(mod, s)
  Manager.session = s
  Manager.active = true
  -- Retire any brush held from a previous session and clear transient UI state.
  Input.reset()
  return true
end

-- Persists every edit of the active session to the mod save (diff patches for
-- edited maps, whole defs for created maps, hotbar + inventory layouts) so a
-- reload replays the work.  Leaves the session open; used on quit and on the
-- map-border reconcile of the outgoing map.
function Manager.persist(mod)
  local s = Manager.session
  if not s then return end
  Manager.saveMapPatches(mod, s)
  Input.saveHotbar(mod)
  Input.saveInventory(mod)
end

-- Auto-save entry point: persists the active session without closing it.
function Manager.autoSave()
  if Manager.mod then Manager.persist(Manager.mod) end
end

-- Closes the active session: persists every edit, resets the controller/brush
-- state, and deactivates the overlay.
function Manager.close()
  if Manager.mod then Manager.persist(Manager.mod) end
  Input.reset()
  Manager.active = false
  Manager.session = nil
  Manager.mod = nil
end

-- While the overlay is open the player can still walk across map borders, so
-- the session must follow the map the cursor is actually over.  On a change,
-- persist the outgoing map and open a fresh session on the incoming one
-- (hotbar / selection survive, since they live on Input).
function Manager.reconcile(game)
  if not (Manager.active and Manager.session) then return end
  local newSession = WorldAdapter.reconcileSession(Manager.session, game)
  if newSession then
    Manager.session = newSession
    -- Re-point picker/hotbar onto the incoming map's tileset and grow the
    -- connected map ring on entry so the new map always has neighbors to paint on.
    local mod = Manager.mod
    local okExpand, expandErr = pcall(Manager.ensureConnectedMaps, newSession)
    if not okExpand then
      mod.log:warn("mapamap: grid expansion failed on map entry: %s", tostring(expandErr))
    end
    Input.onMapEntry(newSession)
    Input.applySelection(newSession)
    -- Re-sync the cursor from the current mouse position so the highlight
    -- doesn't snap to (0,0) until the next physical mouse move event.
    local mx, my = love.mouse.getPosition()
    local t = Coords.transform(game)
    if t then
      local tx, ty = Coords.toWorldCell(t, mx, my)
      newSession.cursorBx, newSession.cursorBy = tx, ty
    end
  end
end

-- New-map creation: builds an adjacent map (with reciprocal connection),
-- tracks it for persistence, and switches the session onto it.
function Manager.createAdjacentMap(side)
  if not Manager.session then return end
  WorldAdapter.createAdjacentMap(Manager.session, side)
end

-- Replays persisted map patches, new-map defs, and extra connections into the
-- loaded save (both the Data registry and, on Gen 2, the World's own maps) so
-- edits survive a reload.  Runs on the save.loaded event.
-- The data authority resolves off mod.game exactly like a session does
-- (Manager.resolveData): on Gen 2 that is the World holding maps/tilesets at
-- game.world; src.core.Data is the Gen 1 registry and Game.state is never
-- assigned by any game -- both were silent wrong targets here.
function Manager.replayPatches(mod)
  local game = mod and mod.game
  local data = Manager.resolveData(game)
  if not (data and data.maps) then
    local Data = require("src.core.Data")
    if Data and Data.maps then data = Data end
  end
  if not (data and data.maps) then return end
  local patches = mod.save:get("mapamap_patches", {})
  if next(patches) then
    Save.applyPatchesToData(patches, data)
  end
  -- Replay whole new-map defs.
  local newMaps = mod.save:get("mapamap_new_maps", {})
  if next(newMaps) then
    for id, def in pairs(newMaps) do
      if not data.maps[id] then data.maps[id] = def end
    end
  end
  -- Merge extra connections into primary connections so the engine can use them.
  Connections.mergeExtraConnections(mod, data)
  -- Any replayed patch may reference grafted foreign blocks -- grow every
  -- touched tileset's atlas from the live defs before maps rebuild, so a
  -- patched map renders its imports instead of drawing blank cells.
  local Graft = require("mods.mapamap.engine.graft")
  Graft.materializeAll(data)
  Gen.invalidateAll(data, game)
  -- Gen 2: the World caches its neighbor strip list in `world.neighbors`; a
  -- save.loaded replay can add brand-new map defs (and new connections on
  -- existing ones) that the cached neighbor set does not know about yet.
  -- Rebuild so the new maps are visible and traversable immediately instead
  -- of waiting for a zoom or map change.
  if Gen.isGen2() then
    local ow = Gen.overworld(game)
    if ow and ow.rebuildNeighbors then
      pcall(ow.rebuildNeighbors, ow)
    end
  end
end

return Manager