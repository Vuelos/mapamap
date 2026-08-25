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
local Slots = require("mods.mapamap.storage.slots")
local Connections = require("mods.mapamap.domain.connections")
local MapGrid = require("mods.mapamap.domain.map_grid")
local Gen = require("mods.mapamap.engine.gen")
local Hotbar = require("mods.mapamap.components.hotbar")
local Bridge = require("mods.mapamap.engine.dramaless_bridge")

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
  if s.mapChanged then
    Save.diffAndStore(mod, s.mapId, s.def, s._originalSnapshot)
  end
  for mapId in pairs(s._sessionDirty or {}) do
    Save.diffAndStore(mod, mapId, s.data and s.data.maps[mapId],
      s._sessionOriginals and s._sessionOriginals[mapId])
  end
  for nbId in pairs(s.neighborDirty or {}) do
    local m = s.neighborMaps and s.neighborMaps[nbId]
    Save.diffAndStore(mod, nbId, m and m.def,
      s.neighborOriginals and s.neighborOriginals[nbId])
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
      -- Silent: seeding files each hotbar entry on its own tab without
      -- dragging the panel's view along.
      if Input.hotbar[i] then
        Input.addInventory(Input.hotbar[i], { silent = true })
      end
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
  -- Gen 2 renames: raw game.data carries gen2Xxx keys (the engine's
  -- Gen2Compat facade is what exposes them under the Gen 1 names, and this
  -- reads raw) -- forward the whole set or the picker's sprite catalog,
  -- encounter editor, etc. find no source table at all.
  if data then
    local RENAMES = {
      sprites = "gen2Sprites", maps = "gen2Maps", tilesets = "gen2Tilesets",
      text = "gen2Text", encounters = "gen2Encounters",
      palettes = "gen2Palettes", icons = "gen2Icons",
      battle_anims = "gen2BattleAnims",
    }
    for name, raw in pairs(RENAMES) do
      merged[name] = merged[name] or data[raw]
    end
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
  -- Renderer-mod integration: widen the rendered neighbor ring while the
  -- session is open so the expanded grid shows in the drawn set (flat strips
  -- and a voxel scene alike), and register the mod api for cross-mod lookups.
  Bridge.init(mod)
  Bridge.expandRenderRadius(game)
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

-- Tears the active session down WITHOUT persisting it.  Only the slot
-- activation path uses this: persisting after the edit buckets were already
-- swapped would re-write the outgoing edit-set over the activated slot.
local function deactivate()
  local game = Manager.session and Manager.session.game
  Input.reset()
  Bridge.restoreRenderRadius(game)
  Manager.active = false
  Manager.session = nil
  Manager.mod = nil
end

-- Closes the active session: persists every edit, resets the controller/brush
-- state, restores the rendered neighbor ring, and deactivates the overlay.
function Manager.close()
  if Manager.mod then Manager.persist(Manager.mod) end
  deactivate()
end

-- Switches the running edit-set to a stored map-slot (the Map Slots panel's
-- LOAD).  Order matters:
--   1. persist the open session first, so unsaved paints land in the live
--      buckets;
--   2. stash those buckets as the auto "previous" slot (activating without
--      a prior SAVE stays recoverable);
--   3. swap the buckets to the slot's contents;
--   4. replay them into the loaded data (renderer invalidation included);
--   5. reopen the session fresh, so its snapshots and dirty-bookkeeping
--      describe the ACTIVATED state -- a stale session would diff its old
--      world view back over the new buckets on the next persist.
-- Maps edited by the outgoing set but untouched by the incoming one keep
-- their painted look until the game save reloads; everything else applies
-- immediately.  Returns true on success, or false + an error message.
function Manager.activateSlot(mod, name)
  local rec = Slots.get(mod, name)
  if not rec then return false, "no slot named " .. tostring(name) end
  local game = Manager.session and Manager.session.game
  local reopen = Manager.active and game ~= nil
  if Manager.mod then Manager.persist(Manager.mod) end
  Slots.store(mod, Slots.PREVIOUS)
  Slots.applyBuckets(mod, rec)
  Manager.replayPatches(mod)
  if reopen then
    local keepPanel = Input.slotsOpen
    deactivate()
    Manager.open(mod, game)
    Input.slotsOpen = keepPanel
  end
  return true
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
  -- Replay edited trainer parties over data.trainers so shared-team edits
-- survive a reload (battles read the tables live at battle start).
  local TrainerParty = require("mods.mapamap.domain.trainer_party")
  local Keys = require("mods.mapamap.storage.save_keys")
  local savedParties = mod.save:get(Keys.TRAINER_PARTIES, {})
  if next(savedParties) then
    TrainerParty.replayInto(data, savedParties)
  end
  -- Any replayed patch may reference grafted foreign blocks -- grow every
  -- touched tileset's atlas from the live defs before maps rebuild, so a
  -- patched map renders its imports instead of drawing blank cells.
  local Graft = require("mods.mapamap.engine.graft")
  Graft.materializeAll(data)
  Gen.invalidateAll(data, game)
  -- Renderer-mod integration: a replay rewrites whole block layers behind
  -- any voxel mesher's back.  Drop its caches wholesale -- cheap when the
  -- renderer mod is absent or nothing was ever meshed.
  Bridge.invalidateAll()
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
    -- The World's live Map instances (self.map + the connectionMaps seam-
    -- collision cache) captured def.blocks / width / connections by reference
    -- when they were built -- BEFORE save.loaded fired.  Patch replay swapped
    -- those tables wholesale, so without this re-capture the player walks the
    -- PRE-edit collision grid until they re-enter each map.  The overlay is
    -- closed on this event, so no draw-frame flush would ever run either.
    local Map2 = require("src.world.gen2.Map")
    if ow and Map2 and Map2.refreshFromDef then
      if ow.map then pcall(Map2.refreshFromDef, ow.map) end
      if ow.connectionMaps then
        for _, m in pairs(ow.connectionMaps) do
          if m then pcall(Map2.refreshFromDef, m) end
        end
      end
    end
  end
end

return Manager