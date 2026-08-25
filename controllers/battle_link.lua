-- BattleLink: wires per-placement custom teams into the engine's battle
-- start.  The overworld emits world.trainer_engaged { npc = ... } right
-- before engageTrainer starts the battle (sight and talk paths both funnel
-- through it), and both battle frontends consult the "trainer.party" hook
-- with (class, partyIndex, party) afterwards (src/battle/BattleState.lua,
-- src/battle/gen2/Battle.lua).  This module sits between the two: it records
-- the engaged object def and, when that placement carries its own
-- obj.customParty roster, hands a copy of it to the battle instead of the
-- shared class#party table.
--
-- init() is called once from main.lua's run(); without a mod context
-- (headless tests, early boot) everything stays inert.

local Common = require("mods.mapamap.common")

local BattleLink = {}

-- The def of the NPC currently being engaged, or nil.  Consumed exactly once
-- by the trainer.party hook so a stale engagement can never leak into a later
-- unrelated battle.
BattleLink.pendingDef = nil

function BattleLink.init(mod)
  if not (mod and mod.events and mod.hooks) then return false end

  mod.events:on("world.trainer_engaged", function(ev)
    local def = ev and ev.npc and ev.npc.def
    if def and def.customParty and #def.customParty > 0 then
      BattleLink.pendingDef = def
    else
      BattleLink.pendingDef = nil
    end
  end)

  mod.hooks:wrap("trainer.party", function(nextFn, oppClass, partyIndex, party)
    local d = BattleLink.pendingDef
    BattleLink.pendingDef = nil
    if d and d.trainerClass == oppClass
        and d.customParty and #d.customParty > 0 then
      -- A copy: neither battle frontend may mutate the def's own roster.
      return Common.deepCopy(d.customParty)
    end
    return nextFn(oppClass, partyIndex, party)
  end)

  return true
end

-- Test seam: drop the captured engagement.
function BattleLink._resetForTest()
  BattleLink.pendingDef = nil
end

return BattleLink
