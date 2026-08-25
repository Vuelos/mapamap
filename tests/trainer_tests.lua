-- Trainer team editing tests: the shared class#party mutators (+ mod-save
-- recording and replay), per-placement customParty rosters, the auto-moveset
-- helper, the battle_link custom-team hook wiring, the Party Editor panel
-- flow, and the Details TEAM entry row.

package.path = "../../../?.lua;" .. package.path

if not _G.love then _G.love = require("tests.love_stub") end

local Data = require("src.core.Data")
if not (Data.maps and Data.maps.PALLET_TOWN) then Data:load() end
local data = Data

local Session = require("mods.mapamap.domain.edit_session")
local Input = require("mods.mapamap.controllers.input")
local TrainerParty = require("mods.mapamap.domain.trainer_party")
local BattleLink = require("mods.mapamap.controllers.battle_link")
local Keys = require("mods.mapamap.storage.save_keys")
local Details = require("mods.mapamap.components.details")
local PartyEditor = require("mods.mapamap.components.party_editor")
local DialogEditor = require("mods.mapamap.components.dialog_editor")
local Panel = require("mods.mapamap.components.panel")

-- Scratch trainer class so tests never mutate real ROM rosters.
local TEST_CLASS = "MAPAMAP_TEST_CLASS"

local VW, VH = 640, 576

local function makeMod()
  return {
    log = { warn = function() end, info = function() end,
            error = function() end },
    save = {
      _store = {},
      get = function(self, k, d)
        return self._store[k] ~= nil and self._store[k] or d
      end,
      set = function(self, k, v) self._store[k] = v end,
    },
    ui = { Font = { draw = function() end } },
  }
end

local game = { data = data, overworld = nil }

local function installTestClass(parties)
  data.trainers[TEST_CLASS] = {
    name = "TESTER", sprite = "SPRITE_BROCK", parties = parties }
end

local function removeTestClass()
  data.trainers[TEST_CLASS] = nil
end

-- Session + a placed battler bound to the scratch class; optionally with a
-- custom roster already on it.
local function fixture(custom)
  local mod = makeMod()
  local s = assert(Session.new(mod, game, "PALLET_TOWN"))
  -- Sessions share one map def; earlier suites leave entities on it.
  s.def.objects = {}
  s.def.warps = {}
  s.def.signs = {}
  -- The class must exist BEFORE placing: placeObjectSpec validates the
  -- battler's trainerClass against data.trainers.
  installTestClass({ { { species = "RATTATA", level = 3 },
                       { species = "SQUIRTLE", level = 8 } } })
  local obj = assert(s:placeObjectSpec(1, 1, { objectType = "trainer",
    trainerClass = TEST_CLASS, trainerParty = 1,
    sprite = next(data.sprites) }), "battler placement fixture")
  if custom then
    assert(s:setObjectCustomParty(obj,
      { { species = "RATTATA", level = 20 } }))
  end
  return mod, s, obj
end

function test_sharedPartyForReturnsLiveTable()
  local s = assert(Session.new(makeMod(), game, "PALLET_TOWN"))
  local party = { { species = "RATTATA", level = 3 } }
  installTestClass({ party })
  assert(s:partyFor(TEST_CLASS, 1) == party, "partyFor answers the live ref")
  assert(s:partyFor(TEST_CLASS, 9) == nil, "missing party index answers nil")
  assert(s:partyFor("OPP_NOPE", 1) == nil, "unknown class answers nil")
  removeTestClass()
end

function test_setTrainerPartyMemberValidatesAndRecords()
  local mod = makeMod()
  local s = assert(Session.new(mod, game, "PALLET_TOWN"))
  local party = { { species = "RATTATA", level = 3 } }
  installTestClass({ party })
  assert(s:setTrainerPartyMember(TEST_CLASS, 1, 1,
    { species = "SQUIRTLE", level = 7 }), "member edit succeeds")
  assert(party[1].species == "SQUIRTLE" and party[1].level == 7,
    "the live slot carries the patch")
  assert(s:setTrainerPartyMember(TEST_CLASS, 1, 1,
    { species = "MON_NOPE" }) == false, "unknown species rejected")
  s:setTrainerPartyMember(TEST_CLASS, 1, 1, { level = 999 })
  assert(party[1].level == 100, "level clamps at 100")
  assert(s:setTrainerPartyMember(TEST_CLASS, 1, 1,
    { moves = { "TACKLE" } }) == true, "moves override accepted")
  assert(party[1].moves and party[1].moves[1] == "TACKLE",
    "the slot keeps the override")
  assert(s:setTrainerPartyMember(TEST_CLASS, 1, 1,
    { moves = { "MOVE_NOPE" } }) == false, "unknown move rejected")
  s:setTrainerPartyMember(TEST_CLASS, 1, 1, { moves = false })
  assert(party[1].moves == nil, "false clears the moves override")
  -- Every write recorded the whole party into the mod-save bucket.
  local saved = mod.save:get(Keys.TRAINER_PARTIES)
  assert(saved and saved[TEST_CLASS] and saved[TEST_CLASS]["1"],
    "edits land in the trainer-parties bucket")
  assert(saved[TEST_CLASS]["1"][1].level == 100,
    "the bucket mirrors the live party")
  removeTestClass()
end

function test_addRemoveMoveSharedSlots()
  local s = assert(Session.new(makeMod(), game, "PALLET_TOWN"))
  installTestClass({ { { species = "RATTATA", level = 3 } } })
  assert(s:addTrainerPartySlot(TEST_CLASS, 1), "add grows the party")
  local party = s:partyFor(TEST_CLASS, 1)
  assert(#party == 2 and party[2].species and party[2].level == 5,
    "the appended slot starts as a level-5 mon")
  assert(s:moveTrainerPartySlot(TEST_CLASS, 1, 2, -1), "move up swaps slots")
  assert(party[1].level == 5 and party[2].level == 3,
    "slot order follows the move")
  assert(not s:moveTrainerPartySlot(TEST_CLASS, 1, 1, -1),
    "moving past the top is rejected")
  assert(s:removeTrainerPartySlot(TEST_CLASS, 1, 1), "remove shrinks")
  assert(#party == 1, "one member left")
  assert(not s:removeTrainerPartySlot(TEST_CLASS, 1, 1),
    "a party never drops below one member")
  for _ = 1, 6 do s:addTrainerPartySlot(TEST_CLASS, 1) end
  assert(#s:partyFor(TEST_CLASS, 1) == TrainerParty.MAX_SLOTS,
    "parties cap at six slots")
  assert(not s:addTrainerPartySlot(TEST_CLASS, 1),
    "adding past the cap is rejected")
  removeTestClass()
end

function test_customPartySetValidateClear()
  local s = assert(Session.new(makeMod(), game, "PALLET_TOWN"))
  -- Sessions share one map def; clear leftovers from earlier suites.
  s.def.objects = {}
  s.def.warps = {}
  s.def.signs = {}
  installTestClass({ { { species = "RATTATA", level = 3 } } })
  local o = s:placeObjectSpec(1, 1, { objectType = "trainer",
    trainerClass = TEST_CLASS, trainerParty = 1,
    sprite = next(data.sprites) })
  assert(o and o.isTrainer, "placed battler fixture")
  -- Plain NPCs refuse to carry a team.
  local npc = s:placeNewObject(2, 2)
  npc.trainerClass = nil
  assert(s:setObjectCustomParty(npc, { { species = "RATTATA", level = 5 } })
    == false, "plain NPCs carry no team")
  -- Unknown species rejected, nothing written.
  assert(s:setObjectCustomParty(o,
    { { species = "MON_NOPE", level = 5 } }) == false,
    "invalid roster rejected")
  assert(o.customParty == nil, "rejected roster leaves no override")
  -- Valid roster lands.
  assert(s:setObjectCustomParty(o, { { species = "RATTATA", level = 42 },
    { species = "SQUIRTLE", level = 10 } }), "valid roster accepted")
  assert(o.customParty and #o.customParty == 2
    and o.customParty[1].level == 42, "the placement carries its own team")
  assert(s.mapChanged, "custom team marks the map changed (def diff persists)")
  -- Slot edits merge + validate.
  assert(s:setObjectCustomPartyMember(o, 2, { level = 12 }),
    "custom member edit succeeds")
  assert(o.customParty[2].level == 12, "the custom slot updates")
  assert(s:setObjectCustomPartyMember(o, 1,
    { moves = { "TACKLE" } }), "custom moves override accepted")
  assert(o.customParty[1].moves[1] == "TACKLE", "override stored")
  -- Custom slot add/remove/move.
  assert(s:addObjectCustomPartySlot(o) and #o.customParty == 3,
    "custom add grows the roster")
  assert(s:moveObjectCustomPartySlot(o, 3, -1), "custom reorder works")
  assert(s:removeObjectCustomPartySlot(o, 3) and #o.customParty == 2,
    "custom remove shrinks the roster")
  -- Clearing reverts to shared.
  assert(s:setObjectCustomParty(o, nil), "clearing succeeds")
  assert(o.customParty == nil, "cleared placements fight the shared team")
  removeTestClass()
end

function test_autoMovesetDerivesLatestFour()
  local speciesId
  for id, d in pairs(data.pokemon) do
    if type(d) == "table" and d.learnset and #d.learnset > 0 then
      speciesId = id break
    end
  end
  assert(speciesId, "fixture expects at least one learnset")
  local moves = assert(TrainerParty.autoMoveset(data, speciesId, 100),
    "high level derives four moves")
  assert(#moves <= 4 and #moves >= 1, "auto movesets hold at most four moves")
  assert(TrainerParty.autoMoveset(data, speciesId, 1),
    "level 1 still derives starting moves")
  assert(TrainerParty.autoMoveset(data, "MON_NOPE", 5) == nil,
    "unknown species yields no auto moveset")
end

function test_replayIntoAppliesSavedParties()
  installTestClass({ { { species = "RATTATA", level = 3 } } })
  local n = TrainerParty.replayInto(data, {
    [TEST_CLASS] = { ["1"] = {
      { species = "SQUIRTLE", level = 55 },
      { species = "RATTATA", level = 6 } } },
  })
  assert(n == 1, "replay reports applied count")
  local party = data.trainers[TEST_CLASS].parties[1]
  assert(party[1].species == "SQUIRTLE" and party[1].level == 55,
    "replayed party replaces the roster")
  assert(TrainerParty.replayInto(data, nil) == 0,
    "nothing saved replays nothing")
  removeTestClass()
end

function test_battleLinkFeedsCustomPartyToHook()
  BattleLink._resetForTest()
  local listeners, wrappers = {}, {}
  local mod = {
    events = { on = function(_, name, fn) listeners[name] = fn end },
    hooks = { wrap = function(_, name, fn) wrappers[name] = fn end },
  }
  assert(BattleLink.init(mod), "init registers both buses")
  assert(listeners["world.trainer_engaged"] and wrappers["trainer.party"],
    "engaged listener and party hook installed")

  local obj = { trainerClass = TEST_CLASS, trainerParty = 1,
    customParty = { { species = "RATTATA", level = 9 } } }
  listeners["world.trainer_engaged"]({ npc = { def = obj } })
  local vanillaCalled = false
  local got = wrappers["trainer.party"](function()
    vanillaCalled = true return "shared"
  end, TEST_CLASS, 1, { { species = "RATTATA", level = 3 } })
  assert(not vanillaCalled, "vanilla skipped when a custom team exists")
  assert(type(got) == "table" and got[1].level == 9
    and got[1] ~= obj.customParty[1],
    "hook returns a detached copy of the custom roster")
  -- Pending consumed exactly once.
  vanillaCalled = false
  got = wrappers["trainer.party"](function()
    vanillaCalled = true return "shared"
  end, TEST_CLASS, 1, {})
  assert(vanillaCalled and got == "shared",
    "stale engagements never leak into later battles")
  -- Engaging a NON-custom battler passes straight through.
  listeners["world.trainer_engaged"](
    { npc = { def = { trainerClass = TEST_CLASS } } })
  vanillaCalled = false
  got = wrappers["trainer.party"](function()
    vanillaCalled = true return "shared"
  end, TEST_CLASS, 1, {})
  assert(vanillaCalled and got == "shared",
    "placements without a custom team keep the shared roster")
  BattleLink._resetForTest()
end

-- ---------------------------------------------------------------------------
-- Party Editor panel flow

function test_partyEditorOpenAndTabToggle()
  local _, s, obj = fixture(false)
  local ui = {}
  assert(PartyEditor.open(ui, s, { entity = obj }),
    "editor opens for a placed battler")
  local d = ui.partyEditor
  assert(d.mode == "shared" and #d.fields == 2,
    "starts on Shared showing the class roster")
  -- Click the Custom tab through the public hit-tester.
  local px, py = PartyEditor.rect(VW, VH)
  local defs = { { label = "Shared" }, { label = "Custom" } }
  local function clickTab(i)
    local tx, ty, tw, th =
      Panel.tabRect(defs, px, Panel.titleBottom(py), s.font, i)
    PartyEditor.mousepressed(ui, s, tx + tw / 2, ty + th / 2, 1)
  end
  clickTab(2)
  local d = ui.partyEditor
  assert(d.mode == "custom", "clicking Custom switches mode")
  assert(obj.customParty and #obj.customParty == 2
    and obj.customParty[1].level == 3,
    "switching copies the shared roster onto the placement")
  -- And back: clearing restores shared fighting.
  clickTab(1)
  assert(d.mode == "shared" and obj.customParty == nil,
    "switching back clears the placement's copy")
  removeTestClass()
end

function test_partyEditorEditsThroughDomain()
  local mod, s, obj = fixture(false)
  local ui = {}
  assert(PartyEditor.open(ui, s, { entity = obj }))
  local d = ui.partyEditor
  local party = s:partyFor(TEST_CLASS, 1)
  -- Level nudge on the active slot goes through the shared mutator + bucket.
  PartyEditor.key(ui, s, "right")
  assert(party[1].level == 4, "Right nudges the active slot's level")
  assert(mod.save:get(Keys.TRAINER_PARTIES)[TEST_CLASS]["1"][1].level == 4,
    "panel edits persist into the bucket")
  -- Dropdown: expansion first (Enter toggles the slot's sub panel), then a
  -- click on the species cell opens the dropdown; Enter picks the entry.
  PartyEditor.key(ui, s, "return")
  assert(d.expand == 1, "Enter expands the active slot")
  local rows = PartyEditor.layout(VW, VH, d)
  local headRow = rows[1]
  local Panel2 = require("mods.mapamap.components.panel")
  local px, py = PartyEditor.rect(VW, VH)
  local areas = nil
  -- recompute head areas through the same math the draw uses
  local LV_W, MV_W, GATE_W = 84, 56, 22
  local sx = px + 34
  local sw = VW and (PartyEditor.rect(VW, VH)) and 0 or 0
  -- click the species cell: x = px+34+halfwidth, y = headRow.y + half height
  local speciesX = px + 34 + 100
  local speciesY = headRow.y + 14
  PartyEditor.mousepressed(ui, s, speciesX, speciesY, 1)
  assert(d.dropdown and d.dropdown.list == "species",
    "species cell opens the dropdown")
  d.dropdown.scroll = 0
  PartyEditor.key(ui, s, "return")
  assert(party[1].species ~= nil and not d.dropdown,
    "dropdown Enter commits a species id")
  -- X removes the active slot; A adds one back.
  d.index = 2
  PartyEditor.key(ui, s, "x")
  assert(#party == 1, "X removes the active slot")
  PartyEditor.key(ui, s, "a")
  assert(#party == 2, "A appends a fresh slot")
  -- AUTO MOVES stores an explicit learnset override when one exists.
  local withLearnset
  for id, dd in pairs(data.pokemon) do
    if type(dd) == "table" and dd.learnset and #dd.learnset > 0 then
      withLearnset = id break
    end
  end
  if withLearnset then
    s:setTrainerPartyMember(TEST_CLASS, 1, 2,
      { species = withLearnset, level = 50 })
    PartyEditor.open(ui, s, { entity = obj })
    d = ui.partyEditor
    d.index = 2
    PartyEditor.key(ui, s, "m")
    assert(party[2].moves and #party[2].moves >= 1,
      "AUTO derives and stores the learnset moves")
  end
  -- Esc closes.
  PartyEditor.key(ui, s, "escape")
  assert(ui.partyEditor == nil, "Escape closes the panel")
  removeTestClass()
end

function test_partyEditorCustomModeRoundTrip()
  local mod, s, obj = fixture(true)
  local ui = {}
  assert(PartyEditor.open(ui, s, { entity = obj }))
  local d = ui.partyEditor
  assert(d.mode == "custom", "opens on Custom when the placement has a team")
  assert(#d.fields == 1 and d.fields[1].level == 20,
    "shows the placement's own roster")
  PartyEditor.key(ui, s, "right")
  assert(obj.customParty[1].level == 21, "custom edits land on the object")
  assert(mod.save:get(Keys.TRAINER_PARTIES) == nil,
    "custom edits never touch the shared bucket")
  removeTestClass()
end

function test_detailsTeamRowOnBattlersAndTools()
  local _, s, obj = fixture(false)
  local ui = {}
  Details.open(ui, s, { entity = obj, entityType = "object" })
  local found, foundIdx
  for i, f in ipairs(ui.details.fields) do
    if f.key == "team" then found, foundIdx = f, i end
  end
  assert(found and found.type == "action", "battler Details list a TEAM row")
  assert(found.value == "shared", "without an override the team reads shared")
  ui.details.index = foundIdx
  Details.activate(ui, s, ui.details)
  assert(ui.details == nil and ui.partyEditor ~= nil,
    "TEAM opens the party editor and closes Details")
  PartyEditor.close(ui)
  -- A battler TOOL in the inventory carries the row too.
  local tool = { kind = "entity", entityType = "object", create =
    { objectType = "trainer", trainerClass = TEST_CLASS, trainerParty = 1,
      sprite = next(data.sprites) } }
  Details.open(ui, s, { item = tool })
  found = nil
  for _, f in ipairs(ui.details.fields) do
    if f.key == "team" then found = f end
  end
  assert(found and found.value == tostring(TEST_CLASS) .. " #1",
    "battler tools list a TEAM row naming class#party")
  removeTestClass()
end

function test_creatorTeamRowOpensEditorAndRestoresForm()
  local mod = makeMod()
  local s = assert(Session.new(mod, game, "PALLET_TOWN"))
  installTestClass({ { { species = "RATTATA", level = 3 } } })
  local EntityCreator = require("mods.mapamap.components.entity_creator")
  local ui = {}
  EntityCreator.open(ui, s, "battler")
  local d = ui.entityCreator
  for _, f in ipairs(d.fields) do
    assert(f.key ~= "trainerParty", "the party # number field is gone")
  end
  -- Type into the form: class + name.
  for _, f in ipairs(d.fields) do
    if f.key == "trainerClass" then f.value = TEST_CLASS end
    if f.key == "label" then f.value = "Brock Clone" end
  end
  -- Enter on the TEAM action row opens the party editor (form parked).
  for i, f in ipairs(d.fields) do
    if f.key == "team" then d.index = i end
  end
  EntityCreator.key(ui, s, "return")
  assert(ui.entityCreator == nil and ui.partyEditor ~= nil,
    "TEAM opens the party editor")
  assert(ui.partyEditor.class == TEST_CLASS
    and ui.partyEditor.mode == "shared"
    and ui.partyEditor.returnCreator ~= nil,
    "bound to the chosen class's shared roster with the draft parked")
  -- Edit through the editor: level nudge lands in data + bucket.
  PartyEditor.key(ui, s, "right")
  assert(s:partyFor(TEST_CLASS, 1)[1].level == 4,
    "editor edits reach the shared party")
  assert(mod.save:get(Keys.TRAINER_PARTIES)[TEST_CLASS]["1"][1].level == 4,
    "and are recorded for replay")
  -- Closing restores the creation form WITH its typed values.
  PartyEditor.key(ui, s, "escape")
  assert(ui.partyEditor == nil and ui.entityCreator ~= nil,
    "closing brings the creation form back")
  local restored = ui.entityCreator
  assert(restored.entityType == "battler", "same entity type")
  for _, f in ipairs(restored.fields) do
    if f.key == "trainerClass" then
      assert(f.value == TEST_CLASS, "class value survived the round-trip")
    elseif f.key == "label" then
      assert(f.value == "Brock Clone", "name value survived the round-trip")
    end
  end
  removeTestClass()
end

function test_battlerTextsFlowFromCreatorToPlacement()
  local mod = makeMod()
  local s = assert(Session.new(mod, game, "PALLET_TOWN"))
  installTestClass({ { { species = "RATTATA", level = 3 } } })
  local EntityCreator = require("mods.mapamap.components.entity_creator")
  local ui = { hotbar = {}, selected = 1, inventory = { items = {}, tab = 2, scroll = 1 } }
  EntityCreator.open(ui, s, "battler")
  local d = ui.entityCreator
  -- The battler form carries the three dialog surfaces.
  local keys = {}
  for _, f in ipairs(d.fields) do keys[f.key] = f end
  assert(keys.pretext and keys.wintext and keys.prizeItem,
    "Before / After-win / Prize rows exist")
  assert(keys.trainerParty == nil, "party # stays gone")
  keys.trainerClass.value = TEST_CLASS
  keys.pretext.value = "You shall\nnot pass!"
  keys.wintext.value = "Impossible..."
  keys.prizeItem.value = "POTION"
  keys.sprite.value = next(data.sprites)
  -- CREATE arms the tool with the whole text set.
  assert(EntityCreator.commit(ui, s), "commit succeeds")
  local tool = ui.hotbar[ui.selected]
  assert(tool.create.text == "You shall\nnot pass!"
    and tool.create.winText == "Impossible..."
    and tool.create.prizeItem == "POTION",
    "the tool carries pre/win texts and the prize")
  -- Painting places an object carrying all of it.
  local obj = assert(s:placeObjectSpec(3, 3, tool.create),
    "placement succeeds")
  assert(obj.isTrainer and obj.text == "You shall\nnot pass!"
    and obj.winText == "Impossible..." and obj.prizeItem == "POTION"
    and obj.prizeCount == 1, "the placed battler keeps the full dialog set")
  -- Details edits validate: bad prize refused, clear works.
  assert(s:setObjectProperty(obj, "prizeItem", "ITEM_NOPE") == false,
    "unknown prize rejected")
  assert(s:setObjectProperty(obj, "prizeItem", "") == true,
    "clearing the prize succeeds")
  assert(obj.prizeItem == nil, "cleared placements pay nothing")
  assert(s:setObjectProperty(obj, "winText", "Nice battle!") ,
    "after-win text editable from Details")
  assert(obj.winText == "Nice battle!", "the after-win line updates")
  removeTestClass()
end

function test_detailsWinTextOpensComposer()
  local _, s, obj = fixture(false)
  local ui = {}
  Details.open(ui, s, { entity = obj, entityType = "object" })
  for i, f in ipairs(ui.details.fields) do
    if f.key == "winText" then ui.details.index = i break end
  end
  Details.activate(ui, s, ui.details)
  assert(ui.details == nil and ui.dialogEditor ~= nil
    and ui.dialogEditor.title == "AFTER-WIN TEXT",
    "After-win opens the composer titled accordingly")
  local d = ui.dialogEditor
  for ch in ("GG"):gmatch(".") do DialogEditor.insertChar(d, ch) end
  DialogEditor.finish(ui, true)
  assert(obj.winText == "GG", "composer writes obj.winText")
  removeTestClass()
end

return {
  name = "MAPAMAP_TRAINER_TEAM",
  teardown = function() removeTestClass() end,
  tests = {
    "test_sharedPartyForReturnsLiveTable",
    "test_setTrainerPartyMemberValidatesAndRecords",
    "test_addRemoveMoveSharedSlots",
    "test_customPartySetValidateClear",
    "test_autoMovesetDerivesLatestFour",
    "test_replayIntoAppliesSavedParties",
    "test_battleLinkFeedsCustomPartyToHook",
    "test_partyEditorOpenAndTabToggle",
    "test_partyEditorEditsThroughDomain",
    "test_partyEditorCustomModeRoundTrip",
    "test_detailsTeamRowOnBattlersAndTools",
    "test_creatorTeamRowOpensEditorAndRestoresForm",
    "test_battlerTextsFlowFromCreatorToPlacement",
    "test_detailsWinTextOpensComposer",
  },
}
