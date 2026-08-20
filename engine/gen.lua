-- Generation compatibility layer: abstracts Gen 1 vs Gen 2 differences
-- so the rest of mapamap can be generation-agnostic.

local Gen = {}

local _gen2

function Gen.isGen2()
  if _gen2 == nil then
    local ok, ver = pcall(require, "src.core.GameVersion")
    _gen2 = ok and ver and ver.generation and ver.generation() == 2
  end
  return _gen2
end

-- Returns the live overworld object from a game instance.
-- Gen 1: game.overworld is the OverworldState singleton.
-- Gen 2: the World lives at game.world (the Gen2Compat facade may or may not
--         have built game.overworld as a proxy).
function Gen.overworld(game)
  if not game then return nil end
  return game.overworld or game.world
end

-- Creates an editor-internal Map instance for the given map id.
-- Gen 1: MapLoader.load builds a Map with a TileRenderer.
-- Gen 2: gen2.Map.new builds a bare Map (no renderer; the World manages its
--         own canvas images).
function Gen.loadMap(data, mapId)
  local def = data.maps[mapId]
  if not def then return nil end
  local tileset = data.tilesets[def.tileset]
  if not tileset then return nil end
  if Gen.isGen2() then
    local Map2 = require("src.world.gen2.Map")
    local ok, m = pcall(Map2.new, def, tileset)
    if not ok or not m then return nil end
    return m
  else
    local MapLoader = require("src.world.MapLoader")
    local ok, m = pcall(MapLoader.load, data, mapId)
    if not ok or not m then return nil end
    return m
  end
end

-- Rebuilds a map's renderer so pending block edits become visible.
-- Gen 1: TileRenderer:rebuild() drops the cached window.
-- Gen 2: no-op; the World handles rendering through its own canvas pipeline.
function Gen.rebuildRenderer(map)
  if Gen.isGen2() then return end -- session:reloadGraftedRenderers()
  if map and map.renderer then map.renderer:rebuild() end
end

-- Invalidates a map in the loader/World cache.
-- Gen 1: MapLoader.invalidate drops the cached Map instance.
-- Gen 2: World:dropMapImages clears baked canvases for the map.
-- The game instance (session.game) is authoritative; Game.state is a legacy
-- probe kept for callers that predate threading one through -- nothing in
-- src/ ever assigns Game.state, so only the game instance resolves on Gen 2.
function Gen.invalidateMap(data, mapId, game)
  if Gen.isGen2() then
    local ow = Gen.overworld(game)
    if not ow then
      local ok, Game = pcall(require, "src.core.Game")
      if ok and Game and Game.state then
        ow = Game.state.overworld or Game.state.world
      end
    end
    -- pcall: World:dropMapImages bakes canvases; an open-path failure must
    -- not hard-crash the game.
    if ow and ow.dropMapImages then pcall(ow.dropMapImages, ow, mapId) end
  else
    local ok, MapLoader = pcall(require, "src.world.MapLoader")
    if ok and MapLoader and MapLoader.invalidate then MapLoader.invalidate(mapId) end
  end
end

-- Invalidates all cached maps/renderers.
-- Gen 1: MapLoader.invalidateAll.
-- Gen 2: drop cached canvases for every known map so they re-bake lazily.
function Gen.invalidateAll(data, game)
  if Gen.isGen2() then
    local ow = Gen.overworld(game)
    if not ow then
      local ok, Game = pcall(require, "src.core.Game")
      if ok and Game and Game.state then
        ow = Game.state.overworld or Game.state.world
      end
    end
    if ow and ow.dropMapImages and data and data.maps then
      for mapId in pairs(data.maps) do
        pcall(ow.dropMapImages, ow, mapId)
      end
    end
  else
    local ok, MapLoader = pcall(require, "src.world.MapLoader")
    if ok and MapLoader and MapLoader.invalidateAll then MapLoader.invalidateAll() end
  end
end

-- Returns the map def for a live overworld neighbor entry.
-- Gen 1: nb.map.def (neighbor has a full Map instance).
-- Gen 2: ow.maps[nb.id] (neighbor has only an id string + image).
function Gen.neighborDef(ow, nb)
  if not nb then return nil end
  if nb.map and nb.map.def then return nb.map.def end
  if nb.id and ow and ow.maps then return ow.maps[nb.id] end
  return nil
end

-- Returns the live neighbor list from the overworld, in the canonical
-- { map/def, ox, oy } format the overlay expects.
-- Gen 1: ow.neighbors already has this shape.
-- Gen 2: ow.neighbors has { id, ox, oy, image }; we look up the def.
function Gen.liveNeighbors(ow)
  if not ow then return {} end
  local raw = ow.neighbors
  if not raw then return {} end
  if Gen.isGen2() then
    local out = {}
    for _, nb in ipairs(raw) do
      local def = nb.id and ow.maps and ow.maps[nb.id]
      if def then
        out[#out + 1] = { map = { def = def }, ox = nb.ox, oy = nb.oy, id = nb.id }
      end
    end
    return out
  end
  return raw
end

-- Builds a thumbnail bundle for a tileset so the picker/hotbar can draw
-- block thumbnails.  Returns { image, quads, aliasMap, blocks } or nil.
-- Both gens try the TileRenderer first (which bakes the GBC palette into the
-- atlas image so thumbnails are coloured, not grayscale).  Gen 2 falls back to
-- a GbcPalette-baked atlas (coloured via the World's live palette data) when
-- the TileRenderer cannot build from that tileset, and finally to the raw
-- grayscale atlas as a last resort.
function Gen.thumbnailBundle(session, tsDef)
  if not tsDef then return nil end
  -- Try the TileRenderer path first: it builds a palette-baked GBC atlas so
  -- thumbnails are coloured instead of raw grayscale.
  local TileRenderer = require("src.render.TileRenderer")
  local mini = { tileset = tsDef, def = { width = 1, height = 1 }, id = tsDef.id }
  local ok, r = pcall(TileRenderer.new, mini, session.data)
  if ok and r and r.image and r.quads then
    -- Check if the TileRenderer actually produced a coloured atlas (GBC bake)
    -- or just a raw grayscale one (no PaletteFX data for this tileset).
    if r.gbcAtlas then
      return { image = r.image, quads = r.quads, aliasMap = r.aliasMap, blocks = tsDef.blocks }
    end
    -- Gen 2: TileRenderer succeeded but gave a raw grayscale atlas.  Try the
    -- Gen 2 palette bake below instead of using the grayscale image.
    if not Gen.isGen2() then
      return { image = r.image, quads = r.quads, aliasMap = r.aliasMap, blocks = tsDef.blocks }
    end
  end
  -- Gen 2 palette-baked atlas: render the grayscale tileset through the
  -- World's live GBC palette so thumbnails match the in-game colours.
  if Gen.isGen2() then
    local Assets = require("src.render.Assets")
    -- A materialized tileset draws from its GROWN atlas (vanilla rows plus the
    -- appended graft rows); a bundle built from the plain image would be a few
    -- rows short once a graft has landed, so prefer graftImage when present.
    local rawAtlas = tsDef.graftImage
    local imgPath = tsDef.image
    if (not rawAtlas) and imgPath then
      local ok2, img = pcall(Assets.image, imgPath)
      if ok2 and img then rawAtlas = img end
    end
    if rawAtlas then
      local tpr = tsDef.tilesPerRow or 16
      local iw, ih = rawAtlas:getDimensions()
      local totalTiles = math.floor(iw / 8) * math.floor(ih / 8)
      -- Build quads from the raw atlas (shared by both the raw and baked paths).
      local function buildQuads()
        local quads = {}
        for t = 0, totalTiles - 1 do
          local sx = (t % tpr) * 8
          local sy = math.floor(t / tpr) * 8
          if sx + 8 <= iw and sy + 8 <= ih then
            quads[t] = love.graphics.newQuad(sx, sy, 8, 8, iw, ih)
          end
        end
        return quads
      end
      -- Try to bake a coloured atlas through GbcPalette.
      local baked = Gen._bakeGen2Atlas(session, tsDef, rawAtlas, iw, ih, tpr,
        totalTiles)
      if baked then
        return { image = baked, quads = buildQuads(), aliasMap = nil,
                 blocks = tsDef.blocks }
      end
      -- Last resort: raw grayscale atlas (visible but not coloured).
      rawAtlas:setFilter("nearest", "nearest")
      return { image = rawAtlas, quads = buildQuads(), aliasMap = nil,
               blocks = tsDef.blocks }
    end
  end
  return nil
end

-- Bakes a palette-coloured version of a tileset atlas using the World's live
-- GbcPalette data.  Returns a LOVE Image (the coloured atlas) or nil when
-- palette data is unavailable.
function Gen._bakeGen2Atlas(session, tsDef, rawAtlas, iw, ih, tpr, totalTiles)
  -- The backing World lives on the GAME instance (game.world on Gen 2), never
  -- on the global Game.state -- nothing in src/ assigns Game.state -- so the
  -- palette sources resolve off the session the caller already has.
  local ow = session and session.game and Gen.overworld(session.game)
  local tilePalettes = tsDef.tilePalettes
  if not (ow and ow.palettes and tilePalettes) then return nil end
  local GbcPalette = require("src.render.GbcPalette")
  if not GbcPalette.available() then return nil end
  local Palettes = require("src.world.gen2.Palettes")
  local mapDef = (ow.map and ow.map.def) or session.def
  local daytime = ow.daytime or Palettes.daytimeFor(mapDef)
  local bgSet = Palettes.bgSet(ow.palettes, mapDef, daytime)
  if not bgSet then return nil end

  local PixelCanvas = require("src.render.PixelCanvas")
  local canvas = PixelCanvas.new(iw, ih, "nearest")
  local quads = {}
  -- Pre-build quads so each tile can be drawn individually.
  for t = 0, totalTiles - 1 do
    local sx = (t % tpr) * 8
    local sy = math.floor(t / tpr) * 8
    if sx + 8 <= iw and sy + 8 <= ih then
      quads[t] = love.graphics.newQuad(sx, sy, 8, 8, iw, ih)
    end
  end
  canvas:renderTo(function()
    love.graphics.clear(0, 0, 0, 0)
    love.graphics.push()
    love.graphics.origin()
    love.graphics.setColor(1, 1, 1, 1)
    for slot = 1, 8 do
      local colors = bgSet[slot]
      if colors then
        GbcPalette.with(colors, function()
          for t = 0, totalTiles - 1 do
            -- Grafted rows keep their SOURCE slot (Graft.applyBgSlots); the
            -- 96-entry tilePalettes has no entry for them, so without this
            -- they would all wash into slot 1.
            local tileSlot = (tsDef.graftBgSlots and tsDef.graftBgSlots[t])
              or tilePalettes[t + 1] or 1
            if tileSlot == slot then
              local q = quads[t]
              if q then
                love.graphics.draw(rawAtlas, q, (t % tpr) * 8,
                  math.floor(t / tpr) * 8)
              end
            end
          end
        end)
      end
    end
    love.graphics.pop()
  end)
  canvas:setFilter("nearest", "nearest")
  return canvas
end

-- Flushes the thumbnail cache key so a graft or tileset change is reflected.
-- Gen 1: TileRenderer.invalidateGbcAtlas.
-- Gen 2: drop the World's tileset atlas cache (and the current map's bake, so
-- the grown texture is re-read) -- keyed by slot count, so nothing needs to
-- clear it unless the reason is a materialize we cannot reach; the game
-- instance backs the World just like the other Gen 2 arms.
function Gen.invalidateAtlasCache(session)
  if Gen.isGen2() then
    local ow = session and session.game and Gen.overworld(session.game)
    if not ow then
      local ok, Game = pcall(require, "src.core.Game")
      if ok and Game and Game.state then
        ow = Game.state.overworld or Game.state.world
      end
    end
    if ow and ow.atlasCache then
      for k in pairs(ow.atlasCache) do ow.atlasCache[k] = nil end
    end
    if ow and session and session.mapId and ow.dropMapImages then
      pcall(ow.dropMapImages, ow, session.mapId)
    end
    return
  end
  local ok, TileRenderer = pcall(require, "src.render.TileRenderer")
  if ok and TileRenderer and TileRenderer.invalidateGbcAtlas then
    TileRenderer.invalidateGbcAtlas()
  end
end

-- Ticks animated tiles.  Gen 1: TileRenderer.tick.  Gen 2: no-op.
function Gen.tickAnim(dt)
  if Gen.isGen2() then return end
  local ok, TileRenderer = pcall(require, "src.render.TileRenderer")
  if ok and TileRenderer and TileRenderer.tick then TileRenderer.tick(dt) end
end

-- Computes the flat-screen transform for the overlay, compatible with both
-- gens.  Returns the same { camx, camy, vw, vh, sp, sx, sy, wox, woy }
-- table as Coords.transform, or nil when tilt is active / no camera.
function Gen.flatTransform(game)
  local Tilt = require("src.render.Tilt")
  if Tilt.active() then return nil end
  local ow = game and Gen.overworld(game)
  -- Gen 2: the facade may not forward .camera; fall back to game.world.
  local cam = (ow and ow.camera)
           or (game and game.world and game.world.camera)
  if not cam then return nil end

  local Zoom = require("src.render.Zoom")
  local ww, wh = love.graphics.getDimensions()
  local pw, ph = ww, wh
  if love.graphics.getPixelDimensions then pw, ph = love.graphics.getPixelDimensions() end
  local dx, dy = 1, 1
  if ww > 0 and pw > 0 then dx = pw / ww end
  if wh > 0 and ph > 0 then dy = ph / wh end

  local Sp, vw, vh
  if Gen.isGen2() then
    Sp = math.max(1, math.floor(math.min(pw / 160, ph / 144)))
    local ok, FaithfulRes = pcall(require, "src.render.FaithfulRes")
    if ok and FaithfulRes and FaithfulRes.scaleCap then
      local cap = FaithfulRes.scaleCap()
      if cap and cap < Sp then Sp = cap end
    end
    local sp2 = Zoom.scale(Sp)
    vw = math.ceil(pw / sp2)
    vh = math.ceil(ph / sp2)
    if vw % 2 ~= 0 then vw = vw + 1 end
    if vh % 2 ~= 0 then vh = vh + 1 end
  else
    local Renderer = require("src.render.Renderer")
    Sp = Renderer:fitScale()
    vw, vh = Renderer:worldViewSize()
  end
  local sp = Zoom.scale(Sp)
  local sx, sy = sp / dx, sp / dy
  local wox = math.floor((pw - vw * sp) / 2) / dx
  local woy = math.floor((ph - vh * sp) / 2) / dy
  return {
    camx = cam.x, camy = cam.y,
    vw = vw, vh = vh, sp = sp, sx = sx, sy = sy,
    wox = wox, woy = woy,
  }
end

return Gen
