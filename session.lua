-- mapamap editing session: a state holder that mixes in the reusable map
-- editor data-op modules (map_ops, editor_neighbors, new_map) so the overlay
-- can paint and expand maps against the same live Data tables the game reads,
-- then persist minimal patches through func.save.
--
-- Unlike the full-screen map_editor scene it derives from, this has no draw,
-- update, or screen-stack lifecycle: main.lua drives it in response to mouse
-- input and render.hud.  The cursor lives in world-cell coordinates (cursorBx /
-- cursorBy) that the Coords module fills each mouse move, and painting converts
-- through the func.op helpers exactly as map_editor does.

local Common = require("mods.mapamap.func.common")
local Snapshot = require("mods.mapamap.func.snapshot")
local Undo = require("mods.mapamap.func.undo")
local Save = require("mods.mapamap.func.save")
local Graft = require("mods.mapamap.func.graft")
local Gen = require("mods.mapamap.func.gen")
local PaletteFX = require("src.render.PaletteFX")

local Session = {}

local function fallbackFont()
  return {
    draw = function() end,
    width = function(str) return #tostring(str) * 8 end,
    getWidth = function(str) return #tostring(str) * 8 end,
  }
end

local function resolveFont(mod)
  local ui = mod and mod.ui or {}
  if ui.Font and type(ui.Font) == "table" then return ui.Font end
  if love and love.graphics and love.graphics.getFont then
    local font = love.graphics.getFont()
    if font then
      local wrapped = {
        draw = function(str, x, y)
          if font.draw then return font.draw(str, x, y) end
          if font.print then return font:print(str, x, y) end
          return nil
        end,
        width = function(str)
          if font.getWidth then return font:getWidth(str) end
          if font.width then return font.width(str) end
          return #tostring(str) * 8
        end,
        getWidth = function(str)
          if font.getWidth then return font:getWidth(str) end
          if font.width then return font.width(str) end
          return #tostring(str) * 8
        end,
      }
      ui.Font = wrapped
      if mod then mod.ui = ui end
      return wrapped
    end
  end
  local font = fallbackFont()
  ui.Font = font
  if mod then mod.ui = ui end
  return font
end

-- Mix reusable method tables onto the session.
local function mixin(t, src) for k, v in pairs(src) do t[k] = v end end
mixin(Session, require("mods.mapamap.func.map_ops"))
mixin(Session, require("mods.mapamap.func.editor_neighbors"))
mixin(Session, require("mods.mapamap.func.warps"))
mixin(Session, require("mods.mapamap.func.encounters"))
mixin(Session, require("mods.mapamap.func.objects"))

-- Creates a session editing `mapId`.  Returns the session or nil when the
-- The object the engine hands the mod as `game` is not the Game singleton (it
-- has no `.overworld`).  Gen 2 splits the data registry: the non-map tables
-- (palettes, field, ...) live on `game.data`, while maps/tilesets live on the
-- live World (`game.world`).  Merge them into one registry so Session.new,
-- PaletteFX, etc. all find what they expect.  Gen 1's `game.data` already holds
-- the full registry, so the merge is a harmless copy there.
local function resolveData(game)
  local d = game and game.data
  local ok, w = pcall(Gen.overworld, game)
  local world = ok and w
  -- Build merged from all available sources.
  local merged = {}
  if d then for k, v in pairs(d) do merged[k] = v end end
  if world then
    merged.maps = world.maps or merged.maps
    merged.tilesets = world.tilesets or merged.tilesets
  end
  if merged.maps then return merged end
  -- Last resort: the canonical data singleton (Gen 1 path).
  local Data = require("src.core.Data")
  if Data and Data.maps then return Data end
  return merged
end

-- Creates a session editing `mapId`.  Returns the session or nil when the
-- map or its tileset cannot be loaded.
function Session.new(mod, game, mapId)
  local data = resolveData(game)
  if not (data and data.maps) then return nil end
  activeData = data
  local def = data.maps[mapId]
  if not def then return nil end
  local tileset = data.tilesets[def.tileset]
  if not tileset then return nil end

  local map = Gen.loadMap(data, mapId)
  if not map then return nil end

  local self = {
    mod = mod, game = game, data = data,
    mapId = mapId, def = def, tileset = tileset, map = map,
    cursorBx = 0, cursorBy = 0,
    selectedBlock = 1,
    brushSize = 1,
    mapChanged = false,
    undo = Undo.new(),
    _originalSnapshot = nil,
    originalRecipConnections = {},
    originalEncounters = nil,
    font = resolveFont(mod),
    mapW = def.width * Common.BLOCK_PX,
    mapH = def.height * Common.BLOCK_PX,
    neighbors = {},
    neighborMaps = {},
    neighborOriginals = {},
    neighborDirty = {},
    _sessionOriginals = {},
    _sessionEncounters = {},
    _sessionDirty = {},
    _thumbBundles = {},
    paletteList = {},
    spriteList = {},
    paletteColors = nil,
  }

  setmetatable(self, { __index = Session })
  self:rebuildNeighbors()
  self:storeOriginal()
  self.paletteColors = self:mapPaletteColors()
  return self
end

-- Refreshes the editor state after a patch was applied (pin the map renderer
-- to the live world data and re-baseline originals so an unsaved exit only
-- reverts what changed after this point).
function Session:refreshAfterLoad()
  self:rebuildNeighbors()
  self:storeOriginal()
  Gen.rebuildRenderer(self.map)
end

-- Force the renderers the PLAYER actually sees to rebuild so an edit shows up
-- immediately.  The session mutates the live map `def` records, and rebuild
-- the session's own cached Map instances, but the overworld may be holding a
-- different (pre-walk) Map object for the edited map; rebuilding the live
-- overworld map + neighbor renderers too guarantees the screen updates at
-- once instead of waiting for the next map enter.
function Session:refreshLiveRenderers()
  local ow = self.game and Gen.overworld(self.game)
  if Gen.isGen2() then
    -- Gen 2: the World manages its own baked canvas images.  Dropping the
    -- map's cached canvas and the neighbor strip images forces a rebake on
    -- the next draw.  refreshMapImages handles the current map; for
    -- non-current maps dropMapImages is enough.
    --
    -- CRITICAL: this bake must NOT run inside the keypress/open/mouse event.
    -- World:rebuildNeighbors bakes neighbor strip canvases (World:imageFor)
    -- and doing that during the input event hard-crashes on Gen 2 with no
    -- Lua error log.  Defer it to the draw frame via _needsLiveRebuild; the
    -- render.hud hook calls flushLiveRebuild() every frame.
    self._needsLiveRebuild = true
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
  Gen.rebuildRenderer(self.map)
end

-- Flushes a deferred live-World rebake (set by refreshLiveRenderers on Gen 2).
-- Called from the render.hud hook in the DRAW frame, never from an input event.
--
-- On Gen 1, drops cached images and rebuilds neighbor canvases immediately.
-- On Gen 2, dropMapImages + imageFor are safe (they just clear/re-bake cache
-- entries).  rebuildNeighbors hard-crashes on Gen 2 (C-level fault inside the
-- neighbor strip baker), so we avoid it entirely: drop + re-bake the current
-- map and any dirty neighbors individually instead of recomputing the full
-- neighbor list.
function Session:flushLiveRebuild()
  if not self._needsLiveRebuild then return end
  self._needsLiveRebuild = false
  local ow = self.game and Gen.overworld(self.game)
  if not ow then return end

  if not Gen.isGen2() then
    if ow.dropMapImages then
      pcall(ow.dropMapImages, ow, self.mapId)
      for nbId in pairs(self.neighborDirty or {}) do
        pcall(ow.dropMapImages, ow, nbId)
      end
    end
    if ow.rebuildNeighbors then pcall(ow.rebuildNeighbors, ow) end
    return
  end

  -- Gen 2 path: re-bake current map + dirty neighbors without rebuildNeighbors.
  -- dropMapImages clears the cache; imageFor re-bakes from the live def.blocks.
  if ow.dropMapImages then
    pcall(ow.dropMapImages, ow, self.mapId)
  end
  if ow.imageFor then
    local ok, img = pcall(ow.imageFor, ow, self.mapId)
    if ok and img then ow.mapImage = img end
  end
  -- Update dirty neighbor images in place so their canvases stay current
  -- without recomputing the full neighbor list.
  if ow.imageFor and ow.neighbors then
    for nbId in pairs(self.neighborDirty or {}) do
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

-- Full renderer reload for the tileset whose grown atlas a graft just
-- changed.  rebuild() only drops the cached window; a new grown image needs
-- fresh TileRenderers for every map that uses the tileset (the edited map
-- and any overworld instance / neighbor strips) so the grown atlas is
-- re-derived from the updated defs on the next build.
function Session:reloadGraftedRenderers()
  Graft.invalidateTileset(self.data, self.tileset.id)
  Graft.materialize(self.data, self.tileset.id)
  Gen.invalidateAtlasCache()
  self._thumbBundles = {}
  if Gen.isGen2() then
    -- Gen 2: rebuild the Map instance so its block data is current, then defer
    -- the baked-canvas drop/neighbour rebake to the draw frame (World bakes
    -- canvases and crash inside the keypress/open/mouse event on Gen 2).
    local Map2 = require("src.world.gen2.Map")
    self.map = Map2.new(self.def, self.tileset)
    self._needsLiveRebuild = true
    return
  end
  local MapLoader = require("src.world.MapLoader")
  -- The session's own cached Map is reloaded so its TileRenderer is rebuilt
  -- against the new grown atlas.
  MapLoader.invalidate(self.mapId)
  self.map = MapLoader.load(self.data, self.mapId)
  if self.map and self.map.renderer then self.map.renderer:rebuild() end
  -- The overworld may hold a different Map instance for this tileset; swap it
  -- for a fresh one right away so the player sees the graft immediately.
  local ow = self.game and Gen.overworld(self.game)
  if ow and ow.map and ow.map.tileset == self.tileset then
    local m = MapLoader.load(self.data, ow.map.id)
    if m and m.renderer then
      ow.map = m
      ow.map.renderer:rebuild()
    end
  end
  self:refreshLiveRenderers()
end

-- Lazily builds (and caches) a renderer bundle for a non-current tileset so the
-- picker can thumbnail its blocks against that tileset's OWN atlas -- not the
-- live map's tileset.  Building a real TileRenderer (via a 1x1 dummy map) makes
-- the thumbnails go through the same palette / GBC-atlas bake as the world, so a
-- non-current tileset is colored instead of rendering in grayscale.  Returns
-- { image, quads, aliasMap, blocks } or nil when the tileset has no drawable
-- image.  The cache is keyed by tileset id + current lighting (darkKey) so a
-- cave/light toggle rebuilds the bake; warping swaps the whole session, so it
-- starts unpopulated each map.
function Session:thumbnailBundle(tsDef)
  if not tsDef then return nil end
  local tid = tsDef.id or "?"
  local key = tid .. PaletteFX.darkKey()
  if not self._thumbBundles then self._thumbBundles = {} end
  local b = self._thumbBundles[key]
  if b ~= nil then return b end
  b = Gen.thumbnailBundle(self, tsDef)
  self._thumbBundles[key] = b or false
  return b
end

-- Reloads the session's map from the live data and rebuilds its renderer.
-- Mirrors map_editor's MapEditor:reloadMap but keeps the mapamap live-data
-- model (the def table is the same one the game draws, so a reload just
-- re-points the Map instance and refreshes originals).  Used by undo/redo
-- restores when the edited map's body changed.
function Session:reloadMap()
  Gen.invalidateMap(self.data, self.mapId)
  self.map = Gen.loadMap(self.data, self.mapId)
  Gen.rebuildRenderer(self.map)
  self:storeOriginal()
end

-- Re-runs the overworld's neighbor resolution so a freshly created edge map
-- (which lives in data.maps but not yet in ow.neighbors) shows up on screen
-- without waiting for the player to step off the map and back in.  The
-- session's own neighbor layout is rebuilt first so the new body joins both
-- the editor's hit-testing set and the live drawn set.
function Session:rebuildWorldNeighbors()
  self:rebuildNeighbors()
  -- refreshLiveRenderers pcall-guards the per-generation World bake, so a
  -- baker failure (Gen 2) cannot hard-crash the game -- this runs from the
  -- open/keypress path, outside the normal update/draw cycle.
  self:refreshLiveRenderers()
end

-- Confirms the session's map still resolves (the world may have warped while
-- the overlay was open, or the loader cache dropped the instance).
function Session:assertResolvable()
  if self.map and self.map.def then return true end
  local m = Gen.loadMap(self.data, self.mapId)
  if not m then return false end
  self.map = m
  return true
end

-- Applies the mod's saved patches for the edited map to the live data, then
-- re-baselines the session so originals reflect the last saved state.  Mirrors
-- map_editor's editor enter().
function Session:applySavedPatches()
  local patch = Save.getPatches(self.mod)[self.mapId]
  if not patch then return end
  for key, value in pairs(patch) do
    if key == "blocks" then
      for i, v in ipairs(value) do
        if self.def.blocks[i] ~= nil then self.def.blocks[i] = v end
      end
    elseif key ~= "id" then
      self.def[key] = value
    end
  end
  -- A patch may carry graftBlocks (imported foreign blocks) -- grow the atlas
  -- from the freshly applied defs and rebuild the session's renderer so the
  -- grafted blocks draw immediately.
  Graft.invalidateTileset(self.data, self.tileset.id)
  Graft.materialize(self.data, self.tileset.id)
  self._thumbBundles = {}
  self:reloadGraftedRenderers()
  self:rebuildNeighbors()
  self:storeOriginal()
end

-- Imports a foreign tileset block into the edited map: reserves the map-local
-- block id in def.graftBlocks (deduped across the tileset's grafts) and marks
-- the map changed.  Does NOT reload renderers; the caller is responsible for
-- calling reloadGraftedRenderers when the new block must be drawable.
-- Returns the map-local block id, or nil on failure.
function Session:importBlock(srcTileset, srcBlock)
  local id = Graft.importBlock(self.data, self.tileset.id, self.def,
                               srcTileset, srcBlock)
  if id then
    self.mapChanged = true
  end
  return id
end

-- Imports a foreign tileset block into the edited map: reserves the map-local
-- block id in def.graftBlocks (deduped across the tileset's grafts), grows
-- the atlas, and reloads renderers so the new block is drawable immediately.
-- Returns the map-local block id, or nil on failure.  The id is what the
-- caller stores into def.blocks / the paint brush.
function Session:graftBlock(srcTileset, srcBlock)
  local id = Graft.importBlock(self.data, self.tileset.id, self.def,
                               srcTileset, srcBlock)
  if id then
    self.mapChanged = true
    self:reloadGraftedRenderers()
  end
  return id
end

-- Splits the session onto a freshly created map (from NewMap.createSidedMap):
-- records the source map's pending state, loads the new map, and re-bases the
-- session on it.  Returns the new map id, or nil.
function Session:adoptNewMap(newId)
  local fromId = self.mapId
  self._sessionOriginals = self._sessionOriginals or {}
  self._sessionEncounters = self._sessionEncounters or {}
  self._sessionDirty = self._sessionDirty or {}
  self._sessionOriginals[fromId] = self._originalSnapshot
  self._sessionEncounters[fromId] = self.originalEncounters
  self._sessionDirty[fromId] = true
  self._newMaps = self._newMaps or {}
  self._newMaps[newId] = Common.deepCopy(self.data.maps[newId])
  self:rebuildNeighbors()
  local data = self.data
  local newDef = data.maps[newId]
  local tileset = data.tilesets[newDef.tileset]
  local m = Gen.loadMap(data, newId)
  self.mapId = newId
  self.def = newDef
  self.tileset = tileset
  self.map = m
  self.mapW = newDef.width * Common.BLOCK_PX
  self.mapH = newDef.height * Common.BLOCK_PX
  self.undo = Undo.new()
  self.expandShiftL = 0
  self.expandShiftT = 0
  self:rebuildNeighbors()
  self:storeOriginal()
  return newId
end

-- Attempts to create a map on the void at the cursor position (single block)
-- or covering the given block rect.  Returns the new map id or nil when no
-- flush connection is possible.  The new map is wired with reciprocal
-- connections and added to the neighbor set immediately.
function Session:createMapAtCursor(bx0, by0, bw, bh)
  local MapGrid = require("mods.mapamap.func.map_grid")
  if bx0 and by0 and bw and bh then
    return MapGrid.createForBlocks(self, bx0, by0, bw, bh)
  end
  local bx = math.floor(self.cursorBx / 2)
  local by = math.floor(self.cursorBy / 2)
  return MapGrid.createForPaint(self, bx, by)
end

-- --- object editing (mirrors the warp helpers) ------------------------------
--
-- Objects live in `def.objects` (the same table the engine reads on map
-- enter) as { x, y, sprite|item, object_type, index, ... } records.

-- Bounds check for a walk-grid cell against a map def.
local function cellIn(def, x, y)
  return x >= 0 and y >= 0 and x < def.width * 2 and y < def.height * 2
end

-- Renames a laid-out map (the edited map or any loaded neighbor).  The name is
-- what the border overlay draws as the map's chip, and it is diff-persisted
-- (tracked field) when the map is a loaded neighbor.
function Session:setMapName(mapId, name)
  if not mapId then return false end
  local def = (mapId == self.mapId) and self.def or (self.data.maps[mapId])
  if not def then return false end
  if self.undo then self.undo:capture(def) end
  def.name = name
  self.mapChanged = true
  if mapId ~= self.mapId then
    self.neighborDirty = self.neighborDirty or {}
    self.neighborDirty[mapId] = true
  end
  return true
end

-- Every unique block id painted on the edited map as placement-tool cells
-- (native ids map to the map's tileset, grafted ids resolve to their source
-- tileset + source block so the tool can re-import them).  Used as the
-- "current map" section of the Tiles inventory tab.
function Session:paintedBlocks()
  local native = self.tileset and #self.tileset.blocks or 0
  local seen, out = {}, {}
  for _, bid in ipairs(self.def.blocks or {}) do
    if bid and not seen[bid] then
      seen[bid] = true
      if bid < native then
        out[#out + 1] = { kind = "block", id = bid, tileset = self.tileset.id }
      else
        local _, entry = Graft.graftFor(self.def, native, bid)
        if entry then
          out[#out + 1] = { kind = "block", id = entry.srcBlock,
            srcTileset = entry.srcTileset }
        end
      end
    end
  end
  return out
end

-- Returns the card edge side that a world cell (in the edited map's local
-- cell frame) lies strictly beyond, or nil when it's inside the body.
function Session:cellEdgeSide(cellX, cellY)
  local w = self.def.width * 2
  local h = self.def.height * 2
  if cellX >= 0 and cellX < w and cellY >= 0 and cellY < h then return nil end
  if cellY < 0 then return "north" end
  if cellY >= h then return "south" end
  if cellX < 0 then return "west" end
  return "east"
end

-- True when the cell falls inside the body of any laid-out neighbor map.
-- A freshly created edge map becomes a neighbor, so this keeps a continuing
-- drag from re-triggering map creation for cells that now have a body.
function Session:cellInsideNeighbor(cellX, cellY)
  local px = cellX * Common.CELL_PX
  local py = cellY * Common.CELL_PX
  for _, nb in ipairs(self.neighbors or {}) do
    local nw = nb.def.width * Common.BLOCK_PX
    local nh = nb.def.height * Common.BLOCK_PX
    if px >= nb.ox and px < nb.ox + nw and py >= nb.oy and py < nb.oy + nh then
      return true
    end
  end
  return false
end

return Session
