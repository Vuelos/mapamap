-- WorldAdapter: Engine bridge for Gen 1 / Gen 2 nuances.
-- Handles canvas cache dropping, live NPC pool refreshes, atlas/renderer rebuilds.
-- The EditSession delegates system side-effects to this adapter.

local Common = require("mods.mapamap.common")
local Gen = require("mods.mapamap.engine.gen")
local Graft = require("mods.mapamap.engine.graft")

local WorldAdapter = {}

-- Force the renderers the PLAYER actually sees to rebuild so an edit shows up
-- immediately. The session mutates the live map `def` records, and rebuilds
-- the session's own cached Map instances, but the overworld may be holding a
-- different (pre-walk) Map object for the edited map.
function WorldAdapter.refreshLiveRenderers(session)
  local ow = session.game and Gen.overworld(session.game)
  if not ow then return end

  if Gen.isGen2() then
    -- Gen 2: the World manages its own baked canvas images. Dropping the
    -- map's cached canvas and the neighbor strip images forces a rebake on
    -- the next draw. refreshMapImages handles the current map; for
    -- non-current maps dropMapImages is enough.
    --
    -- CRITICAL: this bake must NOT run inside the keypress/open/mouse event.
    -- World:rebuildNeighbors bakes neighbor strip canvases (World:imageFor)
    -- and doing that during the input event hard-crashes on Gen 2 with no
    -- Lua error log. Defer it to the draw frame via _needsLiveRebuild; the
    -- render.hud hook calls flushLiveRebuild() every frame.
    session._needsLiveRebuild = true
    return
  end

  local MapLoader = require("src.world.MapLoader")
  if ow and ow.map and ow.map.renderer then
    ow.map.renderer:rebuild()
    local live = MapLoader.cached(ow.map.id)
    if live and live ~= ow.map and live.renderer then live.renderer:rebuild() end
  end
  if ow and ow.neighbors then
    for _, nb in ipairs(ow.neighbors) do
      if nb and nb.map and nb.map.renderer then
        nb.map.renderer:rebuild()
        local live = MapLoader.cached(nb.map.id)
        if live and live ~= nb.map and live.renderer then live.renderer:rebuild() end
      end
    end
  end
  Gen.rebuildRenderer(session.map)
end

-- Makes the runtime overworld's neighbor strip set include maps that the
-- editor just created or wired (new _EXT maps, fresh connections).  The
-- session's own `neighbors` list (EditorNeighbors) is editor-side only; the
-- engine draws non-current maps as neighbor strips from ITS list, which is
-- rebuilt only on zoom/map-change -- so a freshly created map never appears
-- (and later edits to it never refresh) until the player zooms or re-enters.
-- Gen 1 may rebuild inline safely; Gen 2 bakes canvases inside
-- rebuildNeighbors, so it is deferred to the draw frame (see flushLiveRebuild
-- and the CRITICAL note in refreshLiveRenderers).
function WorldAdapter.rebuildRuntimeNeighbors(session)
  local ow = session.game and Gen.overworld(session.game)
  if not ow then return end
  if Gen.isGen2() then
    session._needsLiveRebuild = true
    session._needsNeighborRebuild = true
    return
  end
  if ow.rebuildNeighbors then pcall(ow.rebuildNeighbors, ow) end
end

-- Flushes a deferred live-World rebake (set by refreshLiveRenderers on Gen 2).
-- Called from the render.hud hook in the DRAW frame, never from an input event.
function WorldAdapter.flushLiveRebuild(session)
  if not session._needsLiveRebuild then return end
  session._needsLiveRebuild = false
  local ow = session.game and Gen.overworld(session.game)
  if not ow then return end

  if not Gen.isGen2() then
    if ow.dropMapImages then
      pcall(ow.dropMapImages, ow, session.mapId)
      for nbId in pairs(session.neighborDirty or {}) do
        pcall(ow.dropMapImages, ow, nbId)
      end
    end
    if ow.rebuildNeighbors then pcall(ow.rebuildNeighbors, ow) end
    return
  end

  -- Gen 2 path: re-bake current map + dirty neighbors without rebuildNeighbors.
  -- dropMapImages clears the cache; imageFor re-bakes from the live def.blocks.
  if ow.dropMapImages then
    pcall(ow.dropMapImages, ow, session.mapId)
  end
  if ow.imageFor then
    local ok, img = pcall(ow.imageFor, ow, session.mapId)
    if ok and img then ow.mapImage = img end
  end
  -- A new map / new connection needs the full runtime neighbor set re-derived
  -- (rebuildNeighbors re-bakes every strip via imageFor, picking up the fresh
  -- graph node).  Kept on failure so a later frame retries.
  if session._needsNeighborRebuild then
    if ow.rebuildNeighbors and pcall(ow.rebuildNeighbors, ow) then
      session._needsNeighborRebuild = false
    end
    return
  end
  -- Update dirty neighbor images in place so their canvases stay current
  -- without recomputing the full neighbor list.
  if ow.imageFor and ow.neighbors then
    for nbId in pairs(session.neighborDirty or {}) do
      if ow.dropMapImages then pcall(ow.dropMapImages, ow, nbId) end
      local ok, img = pcall(ow.imageFor, ow, nbId)
      if ok and img then
        for _, nb in ipairs(ow.neighbors) do
          if nb.id == nbId then nb.image = img; break end
        end
      end
    end
  end
end

-- Rebuilds the overworld's live NPC list for the current map from def.objects.
function WorldAdapter.refreshObjects(session)
  local ow = session.game and Gen.overworld(session.game)
  if not (ow and ow.map and ow.map.id == session.mapId) then return false end
  local fn = ow.pooledNPC
  if not fn then return false end
  ow.npcs = {}
  for _, obj in ipairs(session.def.objects or {}) do
    local npc = fn(ow.npcPool, session.data, session.mapId, obj)
    npc.frozen = false
    table.insert(ow.npcs, npc)
  end
  if ow.player then
    ow.entities = { ow.player }
    for _, n in ipairs(ow.npcs) do table.insert(ow.entities, n) end
  end
  return true
end

-- Materializes a graft and rebuilds all renderers using the grown atlas.
function WorldAdapter.reloadGraftedRenderers(session)
  Graft.invalidateTileset(session.data, session.tileset.id)
  Graft.materialize(session.data, session.tileset.id)
  Gen.invalidateAtlasCache()
  session._thumbBundles = {}
  if Gen.isGen2() then
    local Map2 = require("src.world.gen2.Map")
    session.map = Map2.new(session.def, session.tileset)
    session._needsLiveRebuild = true
    return
  end
  local MapLoader = require("src.world.MapLoader")
  MapLoader.invalidate(session.mapId)
  session.map = MapLoader.load(session.data, session.mapId)
  if session.map and session.map.renderer then session.map.renderer:rebuild() end
  local ow = session.game and Gen.overworld(session.game)
  if ow and ow.map and ow.map.tileset == session.tileset then
    local m = MapLoader.load(session.data, ow.map.id)
    if m and m.renderer then
      ow.map = m
      ow.map.renderer:rebuild()
    end
  end
  WorldAdapter.refreshLiveRenderers(session)
end

-- Applies saved patches and materializes grafts.
function WorldAdapter.applySavedPatches(session)
  local Save = require("mods.mapamap.storage.patch_saver")
  local patch = Save.getPatches(session.mod)[session.mapId]
  if not patch then return end
  for key, value in pairs(patch) do
    if key == "blocks" then
      for i, v in ipairs(value) do
        if session.def.blocks[i] ~= nil then session.def.blocks[i] = v end
      end
    elseif key ~= "id" then
      session.def[key] = value
    end
  end
  Graft.invalidateTileset(session.data, session.tileset.id)
  Graft.materialize(session.data, session.tileset.id)
  session._thumbBundles = {}
  WorldAdapter.reloadGraftedRenderers(session)
  session:rebuildNeighbors()
  session:storeOriginal()
end

-- Creates an adjacent map and switches the session onto it.
function WorldAdapter.createAdjacentMap(session, side)
  local fromId = session.mapId
  local NewMap = require("mods.mapamap.domain.new_map")
  local newId = NewMap.createConnectedMap(session, side)
  if not newId then return end
  session._sessionOriginals[fromId] = session._originalSnapshot
  session._sessionEncounters[fromId] = session.originalEncounters
  session._sessionDirty[fromId] = true
  session._newMaps = session._newMaps or {}
  session._newMaps[newId] = Common.deepCopy(session.data.maps[newId])
  session:rebuildNeighbors()
  WorldAdapter.rebuildRuntimeNeighbors(session)
  local data = session.data
  local newDef = data.maps[newId]
  local tileset = data.tilesets[newDef.tileset]
  local m = Gen.loadMap(data, newId)
  session.mapId = newId
  session.def = newDef
  session.tileset = tileset
  session.map = m
  session.mapW = newDef.width * Common.BLOCK_PX
  session.mapH = newDef.height * Common.BLOCK_PX
  session.undo = require("mods.mapamap.domain.undo").new()
  session.expandShiftL = 0
  session.expandShiftT = 0
  session:rebuildNeighbors()
  session:storeOriginal()
end

-- Reconciles the session when the player walks across map borders.
function WorldAdapter.reconcileSession(session, game)
  local currentMapId = game and (game.overworld and game.overworld.map and game.overworld.map.id
    or game.world and game.world.map and game.world.map.id)
  if not currentMapId or currentMapId == session.mapId then return end

  -- Save patches for the outgoing map
  local Save = require("mods.mapamap.storage.patch_saver")
  local patches = Save.getPatches(session.mod)
  if session.mapChanged and session._originalSnapshot then
    local patch = require("mods.mapamap.domain.snapshot").diff(session.def, session._originalSnapshot)
    if next(patch) then
      for key, value in pairs(patch) do
        Save.updatePatchField(session.mod, session.mapId, key, value)
      end
    end
  end

  -- Open fresh session on the incoming map
  local EditSession = require("mods.mapamap.domain.edit_session")
  local newSession = EditSession.new(session.mod, game, currentMapId, session.data)
  if not newSession then return end
  WorldAdapter.applySavedPatches(newSession)
  return newSession
end

return WorldAdapter