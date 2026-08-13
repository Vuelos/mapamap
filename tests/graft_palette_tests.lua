-- Graft palette tests: the materialized grown atlas and the base engine's
-- whole-atlas bake.  Cross-tileset imports are materialized straight into the
-- destination tileset's grown atlas (ts.graftImageData, stamped by
-- func/graft.lua); the renderer bakes it with exactly one rule:
--   * native rows take the DESTINATION map's palette groups (the vanilla bake);
--   * appended (grafted) rows take their SOURCE tileset's palette groups, so
--     RED++ keeps foreign art faithful instead of showing a gray box.
-- In the non-GBC modes there is no bake: the raw (grayscale) rows ride in the
-- atlas and the zone shader recolors the whole frame through the DESTINATION
-- map's palette like any native tile.
-- Tests:
--   1. redpp bakes appended rows through the source tileset's groups;
--   2. native rows bake through the destination palette;
--   3. non-GBC modes keep the appended rows raw (gray) and destination-tinted
--      at draw (asserted as "still in the atlas, un-baked");
--   4. a second import re-materializes and the bake rebakes to the grown dims
--      (never a stale-dimension hand-out);
--   5. materialize is idempotent (re-running stamps the same atlas).

package.path = "../../../?.lua;" .. package.path

if not _G.love then _G.love = require("tests.love_stub") end

local Map = require("src.world.Map")
local TileRenderer = require("src.render.TileRenderer")
local PaletteFX = require("src.render.PaletteFX")
local Assets = require("src.render.Assets")
local Graft = require("mods.mapamap.func.graft")

-- ------- pixel stubs (swap in during setup, restored after) --------------

local ImageData = {}
ImageData.__index = ImageData
function ImageData:getDimensions() return self.w, self.h end
function ImageData:getWidth() return self.w end
function ImageData:getHeight() return self.h end
function ImageData:getPixel(x, y)
  local p = self.pixels[y * self.w + x]
  if not p then return 0, 0, 0, 0 end
  return p[1], p[2], p[3], p[4]
end
function ImageData:setPixel(x, y, r, g, b, a)
  self.pixels[y * self.w + x] = { r, g, b, a }
end
function ImageData:mapPixel(fn)
  for y = 0, self.h - 1 do
    for x = 0, self.w - 1 do
      self:setPixel(x, y, fn(x, y, self:getPixel(x, y)))
    end
  end
end
function ImageData:paste(source, dx, dy, sx, sy, w, h)
  for y = 0, h - 1 do
    for x = 0, w - 1 do
      self:setPixel(dx + x, dy + y, source:getPixel(sx + x, sy + y))
    end
  end
end
function ImageData:encode() return "png-bytes" end

local Image = {}
Image.__index = Image
function Image:getDimensions() return self.w, self.h end
function Image:getWidth() return self.w end
function Image:getHeight() return self.h end
-- the reader reads the baked/recolored atlas back as ImageData
function Image:getData() return self.data end

-- fixture atlases keyed by generated image path (populated in setup); declared
-- before newImageData below so the closure captures the local, not a global
local ATLAS_BY_PATH = {}

local function newImageData(a, b)
  local self = setmetatable({ pixels = {} }, ImageData)
  if type(a) == "string" then
    local spec = ATLAS_BY_PATH[a]
    self.w, self.h = spec.w, spec.h
    local perRow = spec.perRow
    for t = 0, (self.w / 8) * (self.h / 8) - 1 do
      local shade = spec.shadeFor(t)
      local ox, oy = (t % perRow) * 8, math.floor(t / perRow) * 8
      for y = 0, 7 do
        for x = 0, 7 do
          self:setPixel(ox + x, oy + y, shade, shade, shade, 1)
        end
      end
    end
  else
    self.w, self.h = a, b
  end
  return self
end

local function wrapImage(imgData)
  return setmetatable({
    w = imgData:getWidth(), h = imgData:getHeight(), data = imgData,
    getData = function() return imgData end,
  }, Image)
end

-- ------- fixture tilesets / palette groups -------------------------------

-- gray shades per source tile, spread across recolorSample's 4 cutoffs
-- (r > .83 -> colors[1], > .5 -> colors[2], > .17 -> colors[3], else colors[4])
local SHADES = { 1.0, 0.75, 0.3, 0.05 }

-- TS_A group 0, TS_B group 1 (indexed by group + 1 in the 8-entry array)
local GROUP_A = { { 255, 0, 0 }, { 0, 255, 0 }, { 0, 0, 255 }, { 255, 255, 0 } }
local GROUP_B = { { 0, 255, 255 }, { 255, 0, 255 }, { 255, 255, 0 }, { 0, 0, 0 } }

local function groupColorsA()
  local out = {}
  for i = 1, 8 do out[i] = GROUP_A end
  return out
end

local function groupColorsB()
  local out = {}
  for i = 1, 8 do out[i] = GROUP_A end
  out[2] = GROUP_B
  return out
end

-- register a fixture atlas for a tileset's generated image path
local function registerAtlas(id, w, h, perRow)
  ATLAS_BY_PATH["assets/generated/tilesets/" .. id .. ".png"] = {
    w = w, h = h, perRow = perRow,
    shadeFor = function(t) return SHADES[t % 4 + 1] end,
  }
end

local function nativeTileset(id, count)
  local blocks = {}
  for i = 1, count do
    local t = {}
    for c = 1, 16 do t[c] = i - 1 end
    blocks[i] = t
  end
  return { id = id, image = "assets/generated/tilesets/" .. id .. ".png",
           tilesPerRow = 4, blocks = blocks, walkable = { 0 } }
end

local function srcTileset(id, perRow, count)
  local blocks = {}
  for b = 1, count do
    local t = {}
    for c = 1, 16 do t[c] = (b - 1) * 16 + c - 1 end
    blocks[b] = t
  end
  return { id = id, image = "assets/generated/tilesets/" .. id .. ".png",
           tilesPerRow = perRow, blocks = blocks, walkable = {} }
end

-- A fresh data table each test (importBlock mutates def.graftBlocks).
local function dataFixture()
  local def = {
    id = "MAP", tileset = "TS_A", width = 4, height = 4, borderBlock = 0,
    blocks = { 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
  }
  return {
    tilesets = {
      TS_A = nativeTileset("TS_A", 4),
      TS_B = srcTileset("TS_B", 8, 2),
      TS_X = srcTileset("TS_X", 8, 2),
    },
    maps = { MAP = def },
  }, def
end

-- ------- setup / teardown ------------------------------------------------

local savedImage, savedGraphics
local savedNewImage
local savedPF = {}

local function stubPaletteFX()
  savedPF.usesGbcPack = PaletteFX.usesGbcPack
  savedPF.hasWorldTileset = PaletteFX.hasWorldTileset
  savedPF.gbcPack = PaletteFX.gbcPack
  savedPF.worldGroupAt = PaletteFX.worldGroupAt
  savedPF.worldGroupColors = PaletteFX.worldGroupColors
  PaletteFX.usesGbcPack = function(mode) return true end
  PaletteFX.hasWorldTileset = function() return true end
  PaletteFX.gbcPack = function() return { world = {} } end
  PaletteFX.worldGroupAt = function(tileset, mapId, tile)
    return tileset == "TS_A" and 0 or 1
  end
  PaletteFX.worldGroupColors = function(data, tileset, mapId)
    return tileset == "TS_A" and groupColorsA() or groupColorsB()
  end
end

local function restorePaletteFX()
  PaletteFX.usesGbcPack = savedPF.usesGbcPack
  PaletteFX.hasWorldTileset = savedPF.hasWorldTileset
  PaletteFX.gbcPack = savedPF.gbcPack
  PaletteFX.worldGroupAt = savedPF.worldGroupAt
  PaletteFX.worldGroupColors = savedPF.worldGroupColors
end

local function suiteSetup()
  registerAtlas("TS_A", 32, 8, 4)
  registerAtlas("TS_B", 64, 32, 8)
  registerAtlas("TS_X", 64, 32, 8)
  -- pixel-capable image module + newImage that wraps ImageData tables
  savedImage, savedGraphics = love.image, love.graphics
  savedNewImage = savedGraphics.newImage
  love.image = { newImageData = newImageData }
  love.graphics = setmetatable({}, { __index = savedGraphics })
  love.graphics.newImage = function(what)
    if type(what) == "table" and what.pixels then return wrapImage(what) end
    if type(what) == "string" then
      local spec = ATLAS_BY_PATH[what]
      if spec then return wrapImage(newImageData(what)) end
    end
    return savedNewImage(what)
  end
  -- Assets.image caches per resolved path across suites; drop anything baked
  -- under an earlier love.graphics stub so path lookups hit this fixture
  Assets.flush()
  stubPaletteFX()
end

local function suiteTeardown()
  love.image = savedImage
  love.graphics = savedGraphics
  restorePaletteFX()
  TileRenderer.invalidateGbcAtlas()
end

-- ------- tests -----------------------------------------------------------

function test_redpp_bakesGraftedRowsThroughSourceTileset()
  local data, def = dataFixture()
  local gid = Graft.importBlock(data, "TS_A", def, "TS_B", 0)
  assert(gid == 5, "first graft id = native 4 + 1, got " .. tostring(gid))
  local map = Map.new(def, data.tilesets.TS_A)
  local r = TileRenderer.new(map, data)
  assert(r.image and r.gbcAtlas, "RED++ bake produced the atlas image")
  local out = r.image:getData()
  assert(out:getWidth() == 32 and out:getHeight() == 40, "grown atlas is 32x40, got "
         .. out:getWidth() .. "x" .. out:getHeight())
  local rg, gg, bg = out:getPixel(0, 8) -- slot 4 = TS_B tile 0 (shade 1.0)
  assert(rg == 0 and gg == 1 and bg == 1, "slot 4 baked through TS_B group1, got "
         .. rg .. "," .. gg .. "," .. bg)
  rg, gg, bg = out:getPixel(8, 8) -- slot 5 = TS_B tile 1 (shade .75)
  assert(rg == 1 and gg == 0 and bg == 1, "slot 5 baked through TS_B group1, got "
         .. rg .. "," .. gg .. "," .. bg)
  -- native slot 0 keeps the destination-map bake (GROUP_A, red)
  rg, gg, bg = out:getPixel(0, 0)
  assert(rg == 1 and gg == 0 and bg == 0, "native row bakes through destination, got "
         .. rg .. "," .. gg .. "," .. bg)
end

function test_nativeSlotsBakeThroughDestinationPalette()
  local data, def = dataFixture()
  Graft.importBlock(data, "TS_A", def, "TS_B", 0)
  local map = Map.new(def, data.tilesets.TS_A)
  local r = TileRenderer.new(map, data)
  local out = r.image:getData()
  -- every native slot (0..3) uses the DESTINATION map's group 0 (GROUP_A),
  -- shade-mapped by recolorSample's cutoffs (shade -> group color index)
  for t = 0, 3 do
    local color = GROUP_A[t % 4 + 1]
    local x, y = (t % 4) * 8, 0
    local r_, g_, b_ = out:getPixel(x, y)
    assert(r_ == color[1] / 255 and g_ == color[2] / 255 and b_ == color[3] / 255,
      "native slot " .. t .. " bakes through destination group, got "
      .. r_ .. "," .. g_ .. "," .. b_)
  end
end

function test_nonGbcModesKeepGraftedRowsRawInAtlas()
  local data, def = dataFixture()
  Graft.importBlock(data, "TS_A", def, "TS_B", 0)
  local savedUses = PaletteFX.usesGbcPack
  PaletteFX.usesGbcPack = function() return false end
  local map = Map.new(def, data.tilesets.TS_A)
  local r = TileRenderer.new(map, data)
  PaletteFX.usesGbcPack = savedUses
  assert(r.image, "renderer built")
  assert(not r.gbcAtlas, "no whole-atlas bake outside RED++")
  -- the grafted slot rides the RAW grown atlas at full dims (the zone shader
  -- recolors the frame through the DESTINATION map's palette at draw time)
  local out = r.image:getData()
  assert(out:getWidth() == 32 and out:getHeight() == 40, "grown rows still in the atlas")
  local r_, g_, b_ = out:getPixel(0, 8) -- slot 4 = shade 1.0 grayscale
  assert(r_ == 1 and g_ == 1 and b_ == 1, "appended row stays raw grayscale, got "
         .. r_ .. "," .. g_ .. "," .. b_)
end

function test_secondImportRebakesToGrownDims()
  local data, def = dataFixture()
  Graft.importBlock(data, "TS_A", def, "TS_B", 0) -- slots 4..19 -> 32x40
  local map = Map.new(def, data.tilesets.TS_A)
  local r1 = TileRenderer.new(map, data)
  local iw1, ih1 = r1.image:getDimensions()
  assert(iw1 == 32 and ih1 == 40, "first import grows to 32x40, got "
         .. iw1 .. "x" .. ih1)
  local rg, gg, bg = r1.image:getData():getPixel(0, 8)
  assert(rg == 0 and gg == 1 and bg == 1, "first import recolored, got "
         .. rg .. "," .. gg .. "," .. bg)

  -- a second graft grows the atlas to slots 4..35 (9 rows = 72px); the bake
  -- must NOT hand out a stale 32x40 image (materialize invalidates the cache)
  Graft.importBlock(data, "TS_A", def, "TS_B", 1) -- slots 20..35
  local r2 = TileRenderer.new(map, data)
  local iw2, ih2 = r2.image:getDimensions()
  assert(iw2 == 32 and ih2 == 72, "second import rebakes to 32x72, got "
         .. iw2 .. "x" .. ih2 .. " (stale bake cache?)")
  rg, gg, bg = r2.image:getData():getPixel(0, 40) -- slot 20 = TS_B tile 16 (shade 1.0)
  assert(rg == 0 and gg == 1 and bg == 1, "second graft recolored through TS_B, got "
         .. rg .. "," .. gg .. "," .. bg)
end

function test_materializeIsIdempotent()
  local data, def = dataFixture()
  Graft.importBlock(data, "TS_A", def, "TS_B", 0)
  local map = Map.new(def, data.tilesets.TS_A)
  TileRenderer.new(map, data)
  Graft.materialize(data, "TS_A")
  local ts = data.tilesets.TS_A
  assert(ts.graftImageData and (ts.graftImageData:getHeight() or 0) == 40,
    "re-materialize keeps the grown atlas dims")
  local r = TileRenderer.new(map, data)
  local out = r.image:getData()
  local rg, gg, bg = out:getPixel(0, 8)
  assert(rg == 0 and gg == 1 and bg == 1, "re-materialized bake is unchanged, got "
         .. rg .. "," .. gg .. "," .. bg)
end

function test_noGraftsLeavesTilesetVanilla()
  local data, def = dataFixture()
  Graft.materialize(data, "TS_A")
  local ts = data.tilesets.TS_A
  assert(ts.graftImageData == nil, "no grafts -> no grown atlas stamp")
  assert(ts.graftBase == nil, "no grafts -> no base stamp")
end

return {
  name = "MAPAMAP_GRAFT_PALETTE",
  setup = suiteSetup,
  teardown = suiteTeardown,
  tests = {
    "test_redpp_bakesGraftedRowsThroughSourceTileset",
    "test_nativeSlotsBakeThroughDestinationPalette",
    "test_nonGbcModesKeepGraftedRowsRawInAtlas",
    "test_secondImportRebakesToGrownDims",
    "test_materializeIsIdempotent",
    "test_noGraftsLeavesTilesetVanilla",
  },
}