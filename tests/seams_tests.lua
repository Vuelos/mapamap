-- Engine-seam tests: the parts where mapamap's edited data meets the
-- engine's own builders.
--   * Trainers.party honors per-row dvs overrides (the cart's fixed 9/8/8/8
--     is replaced), so the party editor's gender/shiny pins reach real mons.
--   * BattleLink.buildGen2Party turns custom-party spec rows into built MON
--     instances when the gen-2 frontend asks the trainer.party hook.
--   * The sleeping-blocker talk handler: POKe FLUTE gate, catchable wild
--     battle, and the defeat ledger that keeps it gone.

package.path = "../../../?.lua;" .. package.path

if not _G.love then _G.love = require("tests.love_stub") end

local Data = require("src.core.Data")
if not (Data.maps and Data.maps.PALLET_TOWN) then Data:load() end

local Common = require("mods.mapamap.common")
local TrainerParty = require("mods.mapamap.domain.trainer_party")
local BattleLink = require("mods.mapamap.controllers.battle_link")

-- ---------------------------------------------------------------------------
-- Loaded-module swap helpers (restored by the caller).

local function swap(name, fake)
  local orig = package.loaded[name]
  package.loaded[name] = fake
  return function()
    if orig ~= nil then package.loaded[name] = orig
    else package.loaded[name] = nil end
  end
end

function test_trainersPartyHonorsRowDvsAndItem()
  local okT, Trainers = pcall(require, "src.world.gen2.Trainers")
  if not okT then return print("skip: src.world.gen2.Trainers unavailable") end
  local okM, Mon = pcall(require, "src.battle.gen2.Mon")
  if not okM or not (Mon and Mon.new) then
    return print("skip: src.battle.gen2.Mon unavailable")
  end
  -- A shiny female Rattata: the exact DV block the editor's slotDvs writes.
  local slot = {
    species = "RATTATA", level = 10, item = "POTION",
    moves = { "TACKLE" }, shiny = true, gender = "female",
  }
  local dvs = assert(TrainerParty.slotDvs(slot),
    "the pins compile to a DV block")
  assert(dvs.defense == 10 and dvs.speed == 10 and dvs.special == 10,
    "shiny pins the three fixed DVs at 10")
  assert(dvs.attack == 2,
    "shiny+female picks the lowest shiny-legal attack DV")
  local entry = { roster = { {
    species = "RATTATA", level = 10, item = "POTION", moves = { "TACKLE" },
    dvs = dvs,
  } } }
  local party = Trainers.party(Data, entry)
  assert(party and #party == 1, "one mon builds")
  local mon = party[1]
  assert(mon.item == "POTION", "the held item lands on the mon")
  assert(mon.dvs and mon.dvs.attack == dvs.attack
    and mon.dvs.defense == 10, "the row's DV block reaches the mon")
  assert(mon.gender == "female",
    "the synthesized DVs read back as the pinned gender")
end

function test_battle_link_buildGen2PartyBuildsMonInstances()
  local Gen = require("mods.mapamap.engine.gen")
  local origIsGen2 = Gen.isGen2
  Gen.isGen2 = function() return true end

  -- Stub the builder: capture opts, return a plain record.
  local built = {}
  local restoreMon = swap("src.battle.gen2.Mon", {
    new = function(_, species, level, opts)
      built[#built + 1] = { species = species, level = level,
        item = opts and opts.item, dvs = opts and opts.dvs,
        moves = opts and opts.moves }
      return { species = species }
    end,
  })

  local specs = {
    { species = "RATTATA", level = 12, item = "POTION" },
    { species = "SQUIRTLE", level = 8,
      moves = { "TACKLE" },
      dvs = { attack = 2, defense = 10, speed = 10, special = 10 } },
  }

  -- init with a recording mod so buildGen2Party can resolve data.
  local listeners, wrappers = {}, {}
  local m = {
    game = { data = Data },
    events = { on = function(_, n, fn) listeners[n] = fn end },
    hooks = { wrap = function(_, n, fn) wrappers[n] = fn end },
  }
  BattleLink.init(m)
  local party = BattleLink.buildGen2Party(specs)

  assert(party and #party == 2, "both rows build into instances")
  assert(built[1].species == "RATTATA" and built[1].level == 12
    and built[1].item == "POTION", "row fields pass through to Mon.new")
  assert(built[2].dvs and built[2].dvs.attack == 2,
    "per-row dvs blocks pass through")
  assert(type(built[2].moves) == "table"
    and built[2].moves[1].id == "TACKLE"
    and built[2].moves[1].pp ~= nil,
    "move ids compile into {id, pp, maxPp} rows like the extractor's")

  -- And the hook wrapper hands that built party to the battle: engage a
  -- placement whose customParty matches, then fire the hook.
  local obj = { trainerClass = "OPP_BROCK", trainerParty = 1,
    customParty = specs }
  listeners["world.trainer_engaged"]({ npc = { def = obj } })
  local got = wrappers["trainer.party"](function(_, _, p) return p end,
    "OPP_BROCK", 1, {})
  assert(got and #got == 2 and got[1].species == "RATTATA",
    "trainer.party hook returns the built instances")

  Gen.isGen2 = origIsGen2
  restoreMon()
  BattleLink._resetForTest()
end

-- The blocker talk handler: no FLUTE -> snore textbox only; FLUTE -> a
-- catchable wild battle whose win/catch marks the defeat ledger.
function test_blockerTalkHandler_fluteGateAndLedger()
  local Session = require("mods.mapamap.domain.edit_session")
  local WorldAdapter = require("mods.mapamap.engine.world_adapter")

  local mod = {
    log = { warn = function() end, info = function() end,
            error = function() end },
    save = { get = function() return nil end, set = function() end },
    ui = { Font = { draw = function() end } },
  }
  local s = assert(Session.new(mod, { data = Data }, "PALLET_TOWN"))
  s.def.objects = {}
  local obj = assert(s:placeObjectSpec(4, 4, { objectType = "blocker",
    pokemon = "SNORLAX", level = 30 }), "blocker fixture")
  local marker = obj.text
  assert(marker and marker:find("\1BLK:", 1, true), "marker key present")

  -- Capture what registerTalkTexts attaches.
  local attached = {}
  local restoreMS = swap("src.script.MapScripts", {
    attachBase = function(_, mapId, scripts)
      attached[mapId] = scripts
    end,
  })
  -- Stub the engine surfaces the two branches touch: the snore TEXTBOX and
  -- the wild battle constructor (marked so assertions can tell them apart).
  local snoreTexts = {}
  local restoreTB = swap("src.render.TextBox", {
    new = function(_, text, _done)
      local t = { isTextBox = true, text = text }
      snoreTexts[#snoreTexts + 1] = t
      return t
    end,
  })
  local battles = {}
  local restoreBS = swap("src.battle.BattleState", {
    newWild = function(_, species, level)
      local b = { isWildBattle = true, species = species, level = level }
      battles[#battles + 1] = b
      return b
    end,
  })

  WorldAdapter.registerTalkTexts(s)
  local scripts = attached["PALLET_TOWN"]
  assert(scripts and scripts.talk and scripts.talk[marker],
    "the blocker's marker registers a talk handler")

  -- Game stub: stack recorder + save ledger; session refreshObjects runs
  -- against a stub overworld so the defeat path cannot blow up headless.
  local pushed = {}
  local game = {
    data = Data,
    save = {},
    stack = { states = {}, push = function(self, st)
      pushed[#pushed + 1] = st
    end },
  }
  s.game = game
  local owStub = { map = { id = s.mapId }, npcs = {}, npcPool = {},
    pooledNPC = function(_, pool, _m, def)
      return { def = def, id = s.mapId .. "_obj_" .. tostring(def.index) }
    end }

  local doneCalls = 0
  local npc = { def = obj, id = s.mapId .. "_obj_" .. tostring(obj.index) }

  -- 1) Without the flute: a snore TEXTBOX pushes, nothing else.
  scripts.talk[marker](game, nil, npc, function() doneCalls = doneCalls + 1 end)
  assert(#pushed == 1 and pushed[1].isTextBox,
    "no flute: a text box is all that happens")
  assert(game.save.defeatedTrainers == nil
    or not game.save.defeatedTrainers[npc.id],
    "snoring does not mark the blocker defeated")
  pushed = {}

  -- 2) With the flute: a wild SNORLAX battle pushes instead of a box.
  game.save.inventory = { POKE_FLUTE = 1 }
  scripts.talk[marker](game, nil, npc, function() doneCalls = doneCalls + 1 end)
  assert(#pushed == 1 and pushed[1].isWildBattle,
    "flute in bag starts the wild battle")
  assert(pushed[1].species == "SNORLAX" and pushed[1].level == 30,
    "the battle uses the blocker's species/level")

  -- 3) Winning marks the ledger and drops it from the live rebuild.
  game.overworld = owStub
  pushed[1].onFinish("win")
  assert(game.save.defeatedTrainers[npc.id] == true,
    "a win marks the defeat ledger")
  assert(doneCalls >= 1, "the talk flow completed after each handler run")

  restoreMS()
end

return {
  name = "MAPAMAP_SEAMS",
  tests = {
    "test_trainersPartyHonorsRowDvsAndItem",
    "test_battle_link_buildGen2PartyBuildsMonInstances",
    "test_blockerTalkHandler_fluteGateAndLedger",
  },
}
