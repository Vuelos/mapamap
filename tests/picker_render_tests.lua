-- Picker rendering tests against the real data set: the picker must thumbnail a
-- non-current tileset from THAT tileset's own atlas (correct tiles AND its own
-- palette / GBC bake), not the live map's tileset.  This locks in the fix for
-- "tileset picker shows the current map tileset for all tilesets".
--
-- Run from the repo root with:
--   luajit mods/mapamap/tests/test_all.lua

package.path = "../../../?.lua;" .. package.path

if not _G.love then _G.love = require("tests.love_stub") end

local Data = require("src.core.Data")
if not (Data.maps and Data.maps.PALLET_TOWN) then Data:load() end
local data = Data

local Session = require("mods.mapamap.domain.edit_session")
local Picker = require("mods.mapamap.components.picker")

local mod = {
  log = { warn = function() end, info = function() end, error = function() end },
  save = { get = function() return nil end, set = function() end },
  ui = { Font = { draw = function() end } },
}
local game = { data = data, overworld = nil }

-- PALLET_TOWN uses the OVERWORLD tileset (128 blocks); MART is a different
-- tileset (37 blocks) on a different atlas image (pokecenter.png).
local CURRENT = "OVERWORLD"
local FOREIGN = "MART"
local curBlocks = assert(data.tilesets[CURRENT].blocks)
local fBlocks = assert(data.tilesets[FOREIGN].blocks)
assert(#curBlocks ~= #fBlocks,
  "test fixture needs CURRENT and FOREIGN to have different block counts")

function test_itemListBrowsesForeignTilesetRealData()
  local s = assert(Session.new(mod, game, "PALLET_TOWN"))
  -- Default (unset) selection browses the live map's tileset.
  local cur = Picker.itemList(s, nil)
  assert(#cur == #curBlocks, "default should list the current tileset blocks")
  -- Browsing MART (a different tileset) lists MART's blocks, not OVERWORLD's.
  local foreign = Picker.itemList(s, FOREIGN)
  assert(#foreign == #fBlocks,
    "browsing MART should list its own blocks, got " .. #foreign)
  assert(#foreign ~= #curBlocks,
    "browsed tileset must not leak the current tileset's block count")
  assert(Picker.tilesetDef(s, FOREIGN) == data.tilesets[FOREIGN],
    "tilesetDef should resolve the browsed tileset")
end

function test_thumbnailBundleUsesForeignTilesetAtlas()
  local s = assert(Session.new(mod, game, "PALLET_TOWN"))
  local curRenderer = s.map.renderer
  local def = Picker.tilesetDef(s, FOREIGN)
  assert(def == data.tilesets[FOREIGN], "foreign tileset def resolved")
  local bundle = s:thumbnailBundle(def)
  assert(bundle, "thumbnailBundle should build for a foreign tileset")
  assert(bundle.blocks == fBlocks,
    "bundle must carry the foreign tileset's blocks, not the current map's")
  assert(bundle.image, "bundle must have an atlas image")
  assert(bundle.image ~= curRenderer.image,
    "foreign thumbnails must use the foreign tileset's atlas, not the current")
  assert(type(bundle.quads) == "table" and next(bundle.quads),
    "bundle quads must be built for the foreign atlas")
end

return {
  name = "MAPAMAP_PICKER_RENDER",
  tests = {
    "test_itemListBrowsesForeignTilesetRealData",
    "test_thumbnailBundleUsesForeignTilesetAtlas",
  },
}
