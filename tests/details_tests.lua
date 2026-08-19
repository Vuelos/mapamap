-- Details panel: renaming a laid-out map (edited map or a loaded neighbor)
-- through Session:setMapName and through the Details panel itself.

local Session = require("mods.mapamap.session")
local Details = require("mods.mapamap.components.details")

local Data = require("src.core.Data")
if not (Data.maps and Data.maps.PALLET_TOWN) then Data:load() end

local mod = {
  log = { warn = function() end, info = function() end, error = function() end },
  save = { get = function() return nil end, set = function() end },
  ui = { Font = { draw = function() end } },
}
local game = { data = Data, overworld = nil }

local M = {}
M.name = "MAPAMAP_DETAILS"
M.tests = {
  "test_setMapNameEditsAndPersists",
  "test_detailsBuildMapShowsNameField",
  "test_detailsCommitRenamesMap",
}

function test_setMapNameEditsAndPersists()
  local s = assert(Session.new(mod, game, "PALLET_TOWN"))
  s:rebuildNeighbors()
  assert(s:setMapName(s.mapId, "My Renamed Map"), "rename should succeed")
  assert(s.def.name == "My Renamed Map", "edited map name updated")
  assert(s.mapChanged, "map marked changed")
  local nb = s.neighbors[1]
  if nb then
    assert(s:setMapName(nb.id, "Neighbor Name"), "neighbor rename succeeds")
    assert(s.data.maps[nb.id].name == "Neighbor Name", "neighbor name updated")
    assert(s.neighborDirty and s.neighborDirty[nb.id], "neighbor marked dirty")
  end
end

function test_detailsBuildMapShowsNameField()
  local s = assert(Session.new(mod, game, "PALLET_TOWN"))
  s.def.name = "Label Me"
  local fields = Details.build(s, { map = s.def, mapId = s.mapId })
  local nameField
  for _, f in ipairs(fields) do
    if f.key == "name" then nameField = f end
  end
  assert(nameField, "map details should have a Name field")
  assert(nameField.type == "text", "Name field should be editable text")
  assert(nameField.value == "Label Me", "Name field shows current name")
end

function test_detailsCommitRenamesMap()
  local s = assert(Session.new(mod, game, "PALLET_TOWN"))
  local ui = {}
  Details.open(ui, s, { map = s.def, mapId = s.mapId })
  assert(ui.details and ui.details.map, "details opened with map target")
  local idx
  for i, f in ipairs(ui.details.fields) do
    if f.key == "name" then idx = i end
  end
  assert(idx, "name field present")
  local ok = Details.commit(s, ui.details, idx, "Committed Name")
  assert(ok, "commit should succeed")
  assert(s.def.name == "Committed Name", "map renamed through Details")
end

return M
