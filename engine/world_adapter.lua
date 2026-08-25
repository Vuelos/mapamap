-- WorldAdapter: Engine bridge for Gen 1 / Gen 2 nuances.
-- Handles canvas cache dropping, live NPC pool refreshes, atlas/renderer rebuilds.
-- The EditSession delegates system side-effects to this adapter.

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
  -- Warp edits land in def.warps after this World's Map instance built its
  -- _warpAt lookup once in Map.new; without a rebuild the overworld answers a
  -- stale warp (a just-moved warp keeps snapping back).  refreshFromDef
  -- re-captures blocks/width/connections too: expansion and patch replay
  -- REPLACE those tables, and the live instance's stale references made
  -- collision answer the pre-edit grid.  Deferred here on the draw frame like
  -- every other gen2 bake.
  if ow.map and ow.map.def then
    local Map2 = require("src.world.gen2.Map")
    if Map2 then pcall(Map2.refreshFromDef, ow.map) end
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
  -- without recomputing the full neighbor list.  The World also caches a
  -- per-neighbor Map instance for seam collision (connectionMaps, built once);
  -- refresh it so a painted/expanded neighbor walks with the new grid too.
  if ow.imageFor and ow.neighbors then
    for nbId in pairs(session.neighborDirty or {}) do
      if ow.connectionMaps and ow.connectionMaps[nbId] then
        local Map2 = require("src.world.gen2.Map")
        if Map2 then pcall(Map2.refreshFromDef, ow.connectionMaps[nbId]) end
      end
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
-- The implementation lives on the session (domain/objects.lua) -- including
-- the Gen 2 delegation to World:rebuildPeople -- so there is exactly one.
function WorldAdapter.refreshObjects(session)
  if not (session and session.refreshObjects) then return false end
  return session:refreshObjects()
end

-- Reloads every renderer built on `tilesetId` after a graft grew its atlas.
-- Gen 1 TileRenderers capture the atlas IMAGE at construction and :rebuild()
-- only drops the draw window (src/render/TileRenderer.lua:987), so a grown
-- atlas stays invisible to live instances -- grafted ids point past the old
-- texture until each Map is reconstructed.  This remounts the editor session,
-- the editor neighbor set, and the RUNTIME overworld's current map + strip
-- instances for every map on that tileset.  Gen 2 re-bakes from defs, so a
-- deferred live-rebuild flag is enough there.
function WorldAdapter.reloadTilesetRenderers(session, tilesetId)
  Graft.invalidateTileset(session.data, tilesetId)
  Graft.materialize(session.data, tilesetId)
  Gen.invalidateAtlasCache(session)
  session._thumbBundles = {}
  if Gen.isGen2() then
    session._needsLiveRebuild = true
    return
  end
  local MapLoader = require("src.world.MapLoader")
  local function remount(mapId, fallback)
    MapLoader.invalidate(mapId)
    local m = MapLoader.load(session.data, mapId)
    if m and m.renderer then m.renderer:rebuild() end
    return m or fallback
  end
  local usesTileset = function(def)
    return def ~= nil and def.tileset == tilesetId
  end
  if usesTileset(session.def) then
    session.map = remount(session.mapId, session.map)
  end
  for nbId, m in pairs(session.neighborMaps or {}) do
    if usesTileset(session.data.maps[nbId]) then
      session.neighborMaps[nbId] = remount(nbId, m)
    end
  end
  local ow = session.game and Gen.overworld(session.game)
  if not ow then return end
  if ow.map and usesTileset(ow.map.def) then
    ow.map = remount(ow.map.id, ow.map)
  end
  if ow.neighbors then
    for _, nb in ipairs(ow.neighbors) do
      local ndef = (nb.id and session.data.maps[nb.id]) or nb.map and nb.map.def
      if usesTileset(ndef) then
        local id = nb.id or (nb.map and nb.map.id)
        if id then nb.map = remount(id, nb.map) end
      end
    end
  end
end

-- Materializes a graft and rebuilds all renderers using the grown atlas.
function WorldAdapter.reloadGraftedRenderers(session)
  Graft.invalidateTileset(session.data, session.tileset.id)
  Graft.materialize(session.data, session.tileset.id)
  Gen.invalidateAtlasCache(session)
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

-- Registers Lua talk handlers so editor entities carrying CUSTOM (raw string)
-- texts actually speak in-game on Gen 1: showMapText resolves only TEXT_*
-- constants through data.text_pointers, so a raw string just warns "no text"
-- without this bridge.  Handlers are keyed by the raw string and read the LIVE
-- entity's text at talk time, so later Details edits apply without
-- re-registration; stale keys after a deletion are unreferenced and harmless.
-- TEXT_*-prefixed strings stay engine-resolved (the handler would otherwise
-- shadow the real constant with its literal), and item balls keep their pickup
-- script (talkTo dispatches talk handlers before the ball logic).  Gen 2 talks
-- run through the VM scriptKey pipeline -- skipped there.
function WorldAdapter.registerTalkTexts(session)
  if Gen.isGen2() then return end
  local ok, MapScripts = pcall(require, "src.script.MapScripts")
  if not ok or not MapScripts or not session.def then return end
  local function hasItem(ent)
    return ent.item ~= nil and ent.item ~= "0" and ent.item ~= 0
  end
  local talk, n = {}, 0
  local function add(ent)
    -- Sleeping blockers get a WILD-BATTLE handler instead of a text box:
    -- the marker key is unique per placement, the battle is catchable, and
    -- winning/catching marks save.defeatedTrainers so refreshObjects stops
    -- spawning it (vanilla snorlax semantics).  Gen 1 only: gen 2 talks run
    -- through the VM scriptKey pipeline.
    if ent.blocker and type(ent.text) == "string" and ent.text ~= "" then
      local BattleStateOk, BattleState = pcall(require,
        "src.battle.BattleState")
      if not BattleStateOk then return end
      talk[ent.text] = function(game, _ow, npc, done)
        local def = npc and npc.def or ent
        local blk = def.blocker or {}
        -- Vanilla gate: a sleeping blocker only wakes for the POKé FLUTE.
        -- Without it the press prints the snore line and nothing happens.
        local inv = game.save and game.save.inventory
        if not (inv and inv.POKE_FLUTE) then
          local TextBox = require("src.render.TextBox")
          game.stack:push(TextBox.new(game,
            "SNORLAX is snoring\naway...", done))
          return
        end
        local battle = BattleState.newWild(game, blk.species,
          blk.level or 30)
        local prevFinish = battle.onFinish
        battle.onFinish = function(result)
          if result == "win" or result == "caught" then
            game.save.defeatedTrainers = game.save.defeatedTrainers or {}
            game.save.defeatedTrainers[npc and npc.id
              or (session.mapId .. "_obj_" .. tostring(def.index))] = true
            -- The session rebuilds live NPCs from defs; drop it right away.
            if session.refreshObjects then pcall(session.refreshObjects, session) end
          end
          if prevFinish then prevFinish(result) end
        end
        game.stack:push(battle)
        if done then done() end
      end
      n = n + 1
      return
    end
    if ent.healing then
      local text = ent.text
      if type(text) == "string" and text ~= "" then
        talk[text] = function(game, _ow, npc, done)
          if _ow and type(_ow.nurseHeal) == "function" then
            _ow:nurseHeal(done, npc)
          end
        end
        n = n + 1
      end
      return
    end
    local text = ent and ent.text
    if type(text) ~= "string" or text == "" or text:sub(1, 5) == "TEXT_" then
      return
    end
    if hasItem(ent) then return end
    -- Reads the talked-to NPC's LIVE def text so Details edits apply without
    -- re-registration; signs pass npc = nil and fall back to the keyed text.
    talk[text] = function(game, _ow, npc, done)
      local TextBox = require("src.render.TextBox")
      local def = npc and npc.def or ent
      local live = (type(def.text) == "string" and def.text ~= ""
                    and def.text:sub(1, 1) ~= "\1") and def.text or nil
      -- One-time gift item: given once per placement, then just dialog after.
      local key = session.mapId .. "_obj_" .. tostring(def.index)
      local save = game.save
      if type(def.prizeItem) == "string" and def.prizeItem ~= ""
          and save and not (save.giftsGiven and save.giftsGiven[key]) then
        local CommandsOk, Commands = pcall(require, "src.script.Commands")
        if CommandsOk and Commands and Commands.give_item then
          Commands.give_item({ game = game, save = save },
            def.prizeItem, tonumber(def.prizeCount) or 1)
          save.giftsGiven = save.giftsGiven or {}
          save.giftsGiven[key] = true
        end
      end
      if live then
        game.stack:push(TextBox.new(game, live, done))
      elseif done then
        done()
      end
    end
    n = n + 1
  end
  for _, o in ipairs(session.def.objects or {}) do add(o) end
  for _, s in ipairs(session.def.signs or {}) do add(s) end
  if n > 0 then MapScripts.attachBase(session.mapId, { talk = talk }) end
end

-- Applies saved patches and materializes grafts.
function WorldAdapter.applySavedPatches(session)
  WorldAdapter.registerTalkTexts(session)
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

-- Creates an adjacent map and switches the session onto it.  The creation is
-- engine-side (wires reciprocal connections into live data); every session
-- re-pointing step (dirty-bookkeeping, undo reset, renderer reload) lives in
-- EditSession:adoptNewMap so there is exactly one adoption implementation.
function WorldAdapter.createAdjacentMap(session, side)
  local NewMap = require("mods.mapamap.domain.new_map")
  local newId = NewMap.createConnectedMap(session, side)
  if not newId then return end
  session:adoptNewMap(newId)
  WorldAdapter.rebuildRuntimeNeighbors(session)
end

-- Reconciles the session when the player walks across map borders.
function WorldAdapter.reconcileSession(session, game)
  local currentMapId = game and (game.overworld and game.overworld.map and game.overworld.map.id
    or game.world and game.world.map and game.world.map.id)
  if not currentMapId or currentMapId == session.mapId then return end

  -- Save patches for the outgoing map
  local Save = require("mods.mapamap.storage.patch_saver")
  if session.mapChanged then
    Save.diffAndStore(session.mod, session.mapId, session.def,
      session._originalSnapshot)
  end

  -- Open fresh session on the incoming map
  local EditSession = require("mods.mapamap.domain.edit_session")
  local newSession = EditSession.new(session.mod, game, currentMapId, session.data)
  if not newSession then return end
  WorldAdapter.applySavedPatches(newSession)
  return newSession
end

return WorldAdapter