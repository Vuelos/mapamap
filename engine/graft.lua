-- Cross-tileset block import: "grafting".
--
-- A map may paint blocks from ANY tileset.  Those blocks can't stay as ids
-- into the map's own tileset (they are numeric indices into the SOURCE
-- tileset), so importing one:
--   1. reserves a map-local block id (native count + graft index) and records
--      the import as `def.graftBlocks` -- an array parallel to the map's
--      block-index space, persisted inside the map patch itself;
--   2. MATERIALIZES the imported graphic into the EDITING tileset's atlas:
--      the tileset record is stamped with a grown ImageData (vanilla atlas +
--      the appended source 8x8 rows) that the base-engine renderer reads
--      natively (TileRenderer.tilesetImageData / ts.graftImage), and with the
--      appended slots' collision membership + RED++ palette hints.
--
-- Rendering needs no engine monkey-patching: grafted block ids resolve through
-- the base Map.blockTiles resolver (native -> tileset.blocks, grafted ->
-- def.graftBlocks[i].tiles) and draw from the grown atlas.  Under RED++ the
-- engine's whole-atlas bake recolors appended rows through their SOURCE
-- tileset's palette groups (applyRowPalettes), keeping full-color mode
-- faithful; in the SGB/DMG modes the zone shader recolors everything through
-- the DESTINATION map's palette exactly like any native tile.
--
-- Materialization is derived from the map defs themselves (each graft entry
-- stores the absolute atlas slot ids its 16 tiles use), so it survives a
-- reload with no auxiliary save: given the same defs the same grown atlas is
-- rebuilt.  New imports in a session bump the next free slot above every slot
-- already claimed by a grafted block, and materialize is idempotent.

local Graft = {}

-- number of source tiles a grafted block graphic contains (4x4 cells)
local SOURCES_PER_BLOCK = 16

local Assets = require("src.render.Assets")

-- The tileset's VANILLA atlas as pixelable ImageData.  A path is decoded
-- through Assets (pcalled so headless runs without the pixels just get nil);
-- an injected ImageData table (tests) passes through untouched.
local function vanillaImageData(data, tilesetId)
  local ts = data and data.tilesets and data.tilesets[tilesetId]
  if not ts then return nil end
  local img = ts.image
  if img == nil then return nil end
  if type(img) == "string" then
    local ok, out = pcall(function() return Assets.imageData(img) end)
    if not ok or not out then return nil end
    return out
  end
  return img
end

-- number of native 8px tile slots in an atlas ImageData
local function tileCountOf(img)
  if not img then return 0 end
  local w, h
  if img.getDimensions then
    w, h = img:getDimensions()
  else
    w, h = img.w, img.h
  end
  return (w / 8) * (h / 8)
end

-- Scans every map def that uses `tilesetId`, collecting the graft claims:
--   srcForSlot -> slot -> { ts = srcTileset, tile = srcTile }
--   nextSlot   -- the first atlas slot not yet claimed by any graft
-- Deterministic dedup: a source graphic (srcTileset:srcTile) owns one slot;
-- later defs that reuse the same graphic re-claim the canonical slot rather
-- than allocating a fresh duplicate.
-- Returns { base, srcForSlot, nextSlot } or nil when the tileset is unknown.
local function scan(data, tilesetId)
  local target = data and data.tilesets and data.tilesets[tilesetId]
  if not target then return nil end
  local base = tileCountOf(vanillaImageData(data, tilesetId))
  local srcForSlot = {}
  local nextSlot = base
  -- canonical slot per (srcTileset, srcTile), derived from the defs this
  -- run: first def that claims a graphic fixes its slot for everyone else
  -- (the persisted `tiles` make this order-independent)
  local canonical = {}
  for _, def in pairs(data.maps or {}) do
    if def.tileset == tilesetId then
      for _, g in ipairs(def.graftBlocks or {}) do
        local srcId = g and g.srcTileset
        local srcDef = srcId and data.tilesets[srcId]
        local srcBlk = srcDef and srcDef.blocks and srcDef.blocks[g.srcBlock + 1]
        if srcBlk then
          for c = 1, SOURCES_PER_BLOCK do
            local slot = g.tiles and g.tiles[c]
            if slot ~= nil and type(slot) == "number" then
              local srcTile = srcBlk[c]
              local key = srcId .. "|" .. tostring(srcTile)
              if canonical[key] == nil then canonical[key] = slot end
              if srcForSlot[canonical[key]] == nil then
                srcForSlot[canonical[key]] = { ts = srcId, tile = srcTile }
              end
              if canonical[key] + 1 > nextSlot then
                nextSlot = canonical[key] + 1
              end
            end
          end
        end
      end
    end
  end
  return { base = base, srcForSlot = srcForSlot, nextSlot = math.max(base, nextSlot) }
end

-- Derives the full slot mapping for a tileset from the live defs (headless
-- safe, no love).  Returns the scanned table or nil.
function Graft.mappingForTileset(data, tilesetId)
  return scan(data, tilesetId)
end

-- The next free atlas slot for a tileset (native count once no grafts).
function Graft.nextSlot(data, tilesetId)
  local m = scan(data, tilesetId)
  return m and m.nextSlot or 0
end

-- The number of native (un-grafted) tile slots of the tileset -- the
-- boundary below which a slot is a real tileset tile.
function Graft.baseCount(data, tilesetId)
  return tileCountOf(vanillaImageData(data, tilesetId))
end

-- ---- materialization (the step the renderer actually consumes) ----------

-- Collision membership of an appended slot is inherited from its source tile:
-- a grafted water tile at appended slot N surfacifies on every map that uses
-- the destination tileset exactly like the source water it was copied from
-- (Map.new / defIsWaterCell read these lists).  Idempotent: slots are stable
-- per (srcTileset, srcTile), so re-materializing appends nothing new.
local MEMBER_LISTS = { "walkable", "doorTiles", "warpTiles", "waterTiles",
                       "shoreTiles", "counterTiles" }
local function sourceMembership(srcTs)
  local sets = {}
  for _, key in ipairs(MEMBER_LISTS) do
    for _, t in ipairs(srcTs[key] or {}) do sets[t] = true end
  end
  for t, _ in pairs(srcTs.warpPadTiles or {}) do sets[t] = true end
  return sets
end

function Graft.applyMembership(data, target, m)
  for slot, s in pairs(m.srcForSlot) do
    if slot >= m.base then
      local srcTs = data and data.tilesets and data.tilesets[s.ts]
      if srcTs then
        local sets = sourceMembership(srcTs)
        if sets[s.tile] then
          for _, key in ipairs(MEMBER_LISTS) do
            local list = target[key]
            if list then
              local has = false
              for _, t in ipairs(list) do if t == slot then has = true; break end end
              if not has then list[#list + 1] = slot end
            end
          end
          if srcTs.warpPadTiles and srcTs.warpPadTiles[s.tile] then
            target.warpPadTiles = target.warpPadTiles or {}
            target.warpPadTiles[slot] = srcTs.warpPadTiles[s.tile]
          end
        end
      end
    end
  end
end

-- GBC / DMG slot hints for the Gen 2 bake: appended atlas slot -> the source
-- tile's BG palette slot (tileset.tilePalettes[srcTile + 1], defaulting to 1
-- like the engine's own sheet fallback).  The GBC map bake recolors per BG
-- palette slot (World:bakeMapImage), and a grafted row has no entry in the
-- destination's 96-entry tilePalettes -- without this it would take the slot-1
-- fallback instead of the source tile's actual slot.
function Graft.applyBgSlots(data, target, m)
  target.graftBgSlots = nil
  for slot, s in pairs(m.srcForSlot) do
    if slot >= m.base then
      local srcTs = data and data.tilesets and data.tilesets[s.ts]
      if srcTs then
        local ps = srcTs.tilePalettes and srcTs.tilePalettes[s.tile + 1]
        target.graftBgSlots = target.graftBgSlots or {}
        target.graftBgSlots[slot] = ps or 1
      end
    end
  end
end

-- RED++ row palette hints: slot -> { group, srcTs } resolved from the SOURCE
-- tileset's pack groups (mapId nil so the DESTINATION map's per-map tile
-- exceptions never leak onto a foreign tile; TILESET_GROUP_EXCEPTIONS on the
-- source still apply).  The 8-entry palette array itself is resolved by the
-- engine bake at draw time so cave lighting (darkKey) tracks exactly.  A
-- source with no pack data leaves its rows unmarked, and the bake falls back
-- to the destination map's palette for those rows (still colored, never a
-- gray box once the pack's used at all).
function Graft.applyRowPalettes(data, target, m)
  local PaletteFX = require("src.render.PaletteFX")
  target.graftRowPalettes = nil
  for slot, s in pairs(m.srcForSlot) do
    if slot >= m.base then
      local group = PaletteFX.worldGroupAt(s.ts, nil, s.tile)
      if group ~= nil then
        target.graftRowPalettes = target.graftRowPalettes or {}
        target.graftRowPalettes[slot] = { group = group, srcTs = s.ts }
      end
    end
  end
end

-- Grows the tileset's atlas image in memory to include every grafted tile
-- and stamps it on the tileset record for the base renderer:
--   ts.graftImageData -- grown ImageData (source of every atlas-derived bake)
--   ts.graftImage     -- grown love.graphics.Image (real draw texture)
--   ts.graftBase      -- native tile count (the native/grafted boundary)
--   ts.graftRowPalettes / collision lists (see above)
-- Idempotent: re-runs against the same defs stamp the identical atlas.  When
-- the tileset has no grafts (or the pixels are unreachable headless), the
-- stamps are cleared so the renderer falls back to the vanilla atlas.
-- Returns true when the tileset now carries grafted rows.
function Graft.materialize(data, tilesetId)
  local target = data and data.tilesets and data.tilesets[tilesetId]
  if not target then return false end
  local m = scan(data, tilesetId)
  if not m or m.base <= 0 then return false end
  local hasGrafts = next(m.srcForSlot) ~= nil
  if hasGrafts and love and love.image and love.image.newImageData then
    local src = vanillaImageData(data, tilesetId)
    if src then
      local iw, ih = src:getDimensions()
      local perRow = math.max(1, iw / 8)
      local needRows = math.floor(m.nextSlot / perRow)
      if m.nextSlot % perRow ~= 0 then needRows = needRows + 1 end
      local newH = math.max(ih, needRows * 8)
      local gd = love.image.newImageData(iw, newH)
      if gd.paste then gd:paste(src, 0, 0, 0, 0, iw, ih) end
      for slot, s in pairs(m.srcForSlot) do
        local sData = vanillaImageData(data, s.ts)
        if sData and sData.getPixel then
          local sw, sh = sData:getDimensions()
          local sPer = math.max(1, sw / 8)
          local sCount = (sw / 8) * (sh / 8)
          -- The source tile id must sit inside the source tileset's atlas;
          -- a corrupt or mismatched graft can reference a slot past the end of
          -- the atlas.  Reading it would make the ImageData getPixel call go
          -- out of bounds (LÖVE raises, which aborts the whole materialize
          -- and breaks every tileset using this atlas).  Skip such slots so a
          -- single bad graft can never take down the renderer.
          if s.tile < 0 or s.tile >= sCount then
            target._graftSkipped = (target._graftSkipped or 0) + 1
          else
            local sx = (s.tile % sPer) * 8
            local sy = math.floor(s.tile / sPer) * 8
            local dx = (slot % perRow) * 8
            local dy = math.floor(slot / perRow) * 8
            for y = 0, 7 do
              for x = 0, 7 do
                local r, g, b, a = sData:getPixel(sx + x, sy + y)
                if gd.setPixel then gd:setPixel(dx + x, dy + y, r, g, b, a) end
              end
            end
          end
        end
      end
      target.graftImageData = gd
      if love.graphics and love.graphics.newImage then
        target.graftImage = love.graphics.newImage(gd)
      end
      target.graftBase = m.base
    else
      target.graftImageData = nil
      target.graftImage = nil
    end
  else
    target.graftImageData = nil
    target.graftImage = nil
  end
  -- pure-data stamps (always, so a headless/tests run still gets correct
  -- collision + palette hints even when pixels are unreachable)
  Graft.applyMembership(data, target, m)
  Graft.applyRowPalettes(data, target, m)
  Graft.applyBgSlots(data, target, m)
  -- a stamped atlas change must bust the per-map bake (a stale baked palette
  -- would be drawn against the new rows)
  local ok, TileRenderer = pcall(require, "src.render.TileRenderer")
  if ok and TileRenderer and TileRenderer.invalidateGbcAtlas then
    TileRenderer.invalidateGbcAtlas()
  end
  return hasGrafts
end

-- Materializes every tileset holding at least one grafted tile (replayed on
-- save.load, so any patched map renders through its grown atlas before the
-- loader rebuilds).  Returns the number of tilesets that now carry grafts.
function Graft.materializeAll(data)
  local grown = 0
  for id in pairs(data and data.tilesets or {}) do
    if Graft.materialize(data, id) then grown = grown + 1 end
  end
  return grown
end

-- Notifies the renderer that this tileset's grafts changed so the next
-- materialize rebuilds against the current defs; also drops the per-map GBC
-- atlas cache.
function Graft.invalidateTileset(data, tilesetId)
  local ts = data and data.tilesets and data.tilesets[tilesetId]
  if ts then
    ts.graftImageData = nil
    ts.graftImage = nil
    ts.graftRowPalettes = nil
    ts.graftBase = nil
  end
  local ok, TileRenderer = pcall(require, "src.render.TileRenderer")
  if ok and TileRenderer and TileRenderer.invalidateGbcAtlas then
    TileRenderer.invalidateGbcAtlas()
  end
end

-- Clears every stamped grown atlas (used at session create after patches
-- apply, so the next materialize re-reads the updated defs).
function Graft.invalidateAll(data)
  for id in pairs(data and data.tilesets or {}) do
    Graft.invalidateTileset(data, id)
  end
end

-- Reserves a grafted block in `def`'s block space for a foreign source block
-- (srcTileset:srcBlock) and records its tile mapping in def.graftBlocks.
-- Block id convention (mirrors the renderer's lookup):
--   native blocks occupy ids 0 .. #target.blocks - 1
--   graft i (1-based) owns block id #target.blocks + i
-- Reuses a prior graft of the same source block (stable id), and dedups
-- source graphics against slots already claimed by ANY map on this tileset.
-- Materializes the tileset so the grown atlas covers the new rows.
-- Returns the map-local block id to store in def.blocks, nil on failure.
function Graft.importBlock(data, tilesetId, def, srcTileset, srcBlock)
  local srcDef = data and data.tilesets and data.tilesets[srcTileset]
  local srcBlk = srcDef and srcDef.blocks and srcDef.blocks[srcBlock + 1]
  if not srcBlk then return nil end
  local target = data and data.tilesets and data.tilesets[tilesetId]
  if not target or not target.blocks then return nil end
  local native = #target.blocks
  def.graftBlocks = def.graftBlocks or {}
  -- reuse an existing entry for the same source block
  for i, e in ipairs(def.graftBlocks) do
    if e and e.srcTileset == srcTileset and e.srcBlock == srcBlock then
      return native + i
    end
  end
  -- canonical slot map for dedup, then allocate the unused graphics
  local m = scan(data, tilesetId)
  local srcForSlot = m and m.srcForSlot or {}
  local nextFree = m and m.nextSlot or 0
  local tiles = {}
  for c = 1, SOURCES_PER_BLOCK do
    local srcTile = srcBlk[c]
    local slot
    for want, s in pairs(srcForSlot) do
      if s.ts == srcTileset and s.tile == srcTile then slot = want; break end
    end
    if not slot then
      slot = nextFree
      nextFree = nextFree + 1
      srcForSlot[slot] = { ts = srcTileset, tile = srcTile }
    end
    tiles[c] = slot
  end
  table.insert(def.graftBlocks,
    { srcTileset = srcTileset, srcBlock = srcBlock, tiles = tiles })
  Graft.materialize(data, tilesetId)
  return native + #def.graftBlocks
end

-- The map-local block id a (srcTileset, srcBlock) maps to inside `def`, or
-- nil when `def` has no graft for it.  native = # of the local tileset's
-- blocks (the id base grafts land above).
function Graft.blockIdFor(def, native, srcTileset, srcBlock)
  if not def then return nil end
  for i, e in ipairs(def.graftBlocks or {}) do
    if e.srcTileset == srcTileset and e.srcBlock == srcBlock then
      return native + i
    end
  end
  return nil
end

-- The graft entry (with its 16 absolute atlas tile ids) that owns `blockId`
-- in the local block-id space, or nil when the block id is native or out of
-- range.  Returns the 1-based index into def.graftBlocks and the entry.
function Graft.graftFor(def, native, blockId)
  local i = blockId - native
  if i < 1 then return nil end
  local entry = def.graftBlocks and def.graftBlocks[i]
  if not entry then return nil end
  return i, entry
end

return Graft