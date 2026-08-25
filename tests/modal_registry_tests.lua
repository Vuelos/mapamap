-- Modal registry tests: the MOUSE_MODALS / KEY_MODALS dispatch tables in
-- input.lua -- uniform key routing, per-modal outside-click contracts
-- (encEditor closes via nil-fallback, party editor restores a parked
-- creator draft), the composer's cancel-without-save, and the overlay
-- clearing paths (pointer cancel / Tab).

package.path = "../../../?.lua;" .. package.path

if not _G.love then _G.love = require("tests.love_stub") end

local Data = require("src.core.Data")
if not (Data.maps and Data.maps.PALLET_TOWN) then Data:load() end

local Session = require("mods.mapamap.domain.edit_session")
local Input = require("mods.mapamap.controllers.input")
local EncEditor = require("mods.mapamap.components.encounter_editor")
local PartyEditor = require("mods.mapamap.components.party_editor")
local DialogEditor = require("mods.mapamap.components.dialog_editor")
local EntityCreator = require("mods.mapamap.components.entity_creator")

local mod = {
  log = { warn = function() end, info = function() end, error = function() end },
  save = { get = function() return nil end, set = function() end },
  ui = { Font = { draw = function() end } },
}
local game = { data = data or Data, overworld = nil }

-- Bottom-left corner of the screen: outside every panel, over the world.
local OUT_X, OUT_Y = 5, 571

local function clearGlobals()
  Input.details = nil
  Input.encEditor = nil
  Input.partyEditor = nil
  Input.dialogEditor = nil
  Input.entityCreator = nil
  Input.showEntitySelector = false
  Input.showPicker = false
  Input.showBrushEditor = false
  Input.dragItem = nil
end

function test_keyRouting_creatorConsumesArrows()
  clearGlobals()
  local s = assert(Session.new(mod, game, "PALLET_TOWN"))
  local ui = { hotbar = {}, selected = 1,
    inventory = { items = {}, tab = 2, scroll = 1 } }
  EntityCreator.open(ui, s, "npc")
  Input.entityCreator = ui.entityCreator
  for _, k in ipairs({ "up", "down", "left", "right" }) do
    assert(Input.keypressed(s, k),
      "arrows are consumed by the open creator form")
  end
end

function test_encEditorOutsideClickClosesPanel()
  clearGlobals()
  local s = assert(Session.new(mod, game, "PALLET_TOWN"))
  local ui = {}
  EncEditor.open(ui, s)
  Input.encEditor = ui.encEditor
  local consumed = Input.mousepressed(s, game, OUT_X, OUT_Y, 1)
  assert(consumed, "the outside click is still consumed")
  assert(Input.encEditor == nil,
    "closeOnOutside without component.close nils the state")
end

function test_partyEditorOutsideClickRestoresParkedForm()
  clearGlobals()
  local s = assert(Session.new(mod, game, "PALLET_TOWN"))
  -- Park a creation form, exactly like the creator's TEAM row does.
  local form = EntityCreator.open({ hotbar = {}, selected = 1 }, s, "npc")
  for _, f in ipairs(form.fields) do
    if f.key == "label" then f.value = "Parked Guy" end
  end
  local ui = { hotbar = {}, selected = 1,
    inventory = { items = {}, tab = 2, scroll = 1 } }
  assert(PartyEditor.openShared(ui, s, "OPP_BROCK", 1))
  ui.partyEditor.returnCreator = { draft = {
    entityType = "npc", fields = form.fields } }
  Input.entityCreator = form
  Input.partyEditor = ui.partyEditor

  local consumed = Input.mousepressed(s, game, OUT_X, OUT_Y, 1)
  assert(consumed, "outside click consumed")
  assert(ui.partyEditor == nil, "the editor closed")
  assert(Input.entityCreator ~= nil, "the parked form came back")
  local label
  for _, f in ipairs(Input.entityCreator.fields) do
    if f.key == "label" then label = f.value end
  end
  assert(label == "Parked Guy", "typed values survive the round-trip")
  clearGlobals()
end

function test_dialogOutsideClickCancelsWithoutSaving()
  clearGlobals()
  local s = assert(Session.new(mod, game, "PALLET_TOWN"))
  local saved, saveCount = nil, 0
  local ui = {}
  DialogEditor.open(ui, s, {
    title = "DIALOG", text = "Hi",
    onSave = function(t) saved, saveCount = t, saveCount + 1 end,
  })
  Input.dialogEditor = ui.dialogEditor
  assert(Input.mousepressed(s, game, OUT_X, OUT_Y, 1), "consumed")
  assert(ui.dialogEditor == nil, "the composer closed")
  assert(saved == nil and saveCount == 0,
    "an outside click cancels without writing")
end

function test_cancelledClearsEveryOverlayAndDrag()
  clearGlobals()
  Input.partyEditor = { session = {} }
  Input.dialogEditor = { text = "" }
  Input.entityCreator = { fields = {} }
  Input.dragItem = { kind = "block" }
  Input.cancelled()
  assert(Input.partyEditor == nil and Input.dialogEditor == nil
    and Input.entityCreator == nil and Input.dragItem == nil,
    "a cancelled pointer retires every panel and drag")
end

function test_toggleInventoryClosesOverlays()
  clearGlobals()
  Input.showInventory = true
  Input.partyEditor = { session = {} }
  assert(Input.keypressed(assert(Session.new(mod, game, "PALLET_TOWN")),
    "tab"), "TAB is consumed")
  assert(Input.showInventory == false, "TAB hides the inventory")
  assert(Input.partyEditor == nil, "TAB puts the overlays away")
end

return {
  name = "MAPAMAP_MODAL_REGISTRY",
  tests = {
    "test_keyRouting_creatorConsumesArrows",
    "test_encEditorOutsideClickClosesPanel",
    "test_partyEditorOutsideClickRestoresParkedForm",
    "test_dialogOutsideClickCancelsWithoutSaving",
    "test_cancelledClearsEveryOverlayAndDrag",
    "test_toggleInventoryClosesOverlays",
  },
}
