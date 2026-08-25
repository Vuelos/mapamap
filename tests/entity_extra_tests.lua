-- Entity-creator extras: STONE / HEADBUTT TREE / BLOCKER / BERRY TREE /
-- HIDDEN ITEM round-trips, the tree-block resolvers, the defeated-blocker
-- visibility filter, and the battler Sight field.
--
-- Written in the function-reference suite style with TestUtil helpers (see
-- tests/test_util.lua) -- no globals, shared mod/session boilerplate.

package.path = "../../../?.lua;" .. package.path

if not _G.love then _G.love = require("tests.love_stub") end

local Data = require("src.core.Data")
if not (Data.maps and Data.maps.PALLET_TOWN) then Data:load() end

local Session = require("mods.mapamap.domain.edit_session")
local Input = require("mods.mapamap.controllers.input")
local Paint = require("mods.mapamap.domain.paint")
local Objects = require("mods.mapamap.domain.objects")
local Common = require("mods.mapamap.common")
local EntityCreator = require("mods.mapamap.components.entity_creator")
local T = require("mods.mapamap.tests.test_util")
T.bind(Data, Session)

local mod = {
  log = { warn = function() end, info = function() end, error = function() end },
  save = { get = function() return nil end, set = function() end },
  ui = { Font = { draw = function() end } },
}
local game = { data = Data, overworld = nil }

local function freshSession()
  return T.session(mod, nil, game)
end

local function cutTreeResolver()
  local s = freshSession()
  Data.field = Data.field or {}
  local savedSwaps = Data.field.cutTreeSwaps
  Data.field.cutTreeSwaps = { { before = 2, after = 3 },
                              { before = 999, after = 1000 } }
  assert(Paint.cutTreeBlockFor(s) == 2,
    "resolver picks the first in-tileset tree block")
  Data.field.cutTreeSwaps = {}
  assert(Paint.cutTreeBlockFor(s) == nil, "treeless tileset resolves nil")
  Data.field.cutTreeSwaps = savedSwaps
end

local function headbuttBlockResolverUsesCollisionTile()
  local s = freshSession()
  local MapM = require("src.world.Map")
  local found
  for b = 1, Common.effectiveBlockCount(s.tileset) do
    local tiles = MapM.blockTiles(s.def, s.tileset, b)
    if tiles and ({ [0x15] = true, [0x1d] = true })[tiles[13] % 256] then
      found = b break
    end
  end
  if found then
    assert(Paint.headbuttBlockFor(s) == found,
      "resolver matches the collision-tile scan")
  else
    local ts = s.tileset
    local oldBlocks = ts.blocks
    ts.blocks = { { [13] = 0x15 } }
    if Common.effectiveBlockCount(ts) >= 1 then
      assert(Paint.headbuttBlockFor(s) ~= nil,
        "synthesized tree tile resolves")
    end
    ts.blocks = oldBlocks
  end
end

local function boulderPlacementIsPushable()
  local s = freshSession()
  local o = assert(s:placeObjectSpec(2, 2, { objectType = "boulder" }))
  assert(o.sprite == "SPRITE_BOULDER" and o.pushable
    and o.movement == "STAY", "boulder is a pushable stone")
end

local function hiddenItemPlacementSetsFlag()
  local s = freshSession()
  local o = assert(s:placeObjectSpec(3, 3,
    { objectType = "itemball", item = "POTION", hidden = true }))
  assert(o.hidden == true and o.item == "POTION",
    "hidden flag rides the placement")
end

-- A live refresh must respect the engine's spawn gates: hidden placements
-- and already-picked-up items stay off-screen (they used to pop back in on
-- every refresh until a map re-entry).
local function refreshObjectsAppliesVisibilityGates()
  local s = freshSession()
  game.save = { itemsTaken = {} }
  local normal = assert(s:placeObjectSpec(1, 1,
    { objectType = "itemball", item = "POTION" }))
  local hidden = assert(s:placeObjectSpec(2, 2,
    { objectType = "itemball", item = "POTION", hidden = true }))
  local taken = assert(s:placeObjectSpec(3, 3,
    { objectType = "itemball", item = "POTION" }))
  game.save.itemsTaken[s.mapId .. "_obj_" .. tostring(taken.index)] = true

  local owStub = { map = { id = s.mapId }, npcs = {}, npcPool = {},
    pooledNPC = function(_, pool, _m, def)
      return { def = def, id = s.mapId .. "_obj_" .. tostring(def.index) }
    end }
  local realOverworld = game.overworld
  game.overworld = owStub

  Objects.refreshObjects(s)
  assert(#owStub.npcs == 1 and owStub.npcs[1].def == normal,
    "only the visible item spawns")

  -- Adding ANOTHER item re-runs the refresh: gates still hold.
  s:placeObjectSpec(4, 4, { objectType = "itemball", item = "POTION" })
  Objects.refreshObjects(s)
  local ids = {}
  for _, n in ipairs(owStub.npcs) do ids[n.def.index] = true end
  assert(#owStub.npcs == 2 and not ids[hidden.index] and not ids[taken.index],
    "hidden and collected stay hidden across refreshes")

  game.overworld = realOverworld
  game.save = nil
end

local function blockerPlacementMarkerAndFilter()
  local s = freshSession()
  local o = assert(s:placeObjectSpec(4, 4, { objectType = "blocker",
    pokemon = "SNORLAX", level = 30 }), "blocker places")
  assert(o.sprite == "SPRITE_SNORLAX" and o.movement == "STAY",
    "blocker is a sleeping snorlax")
  assert(o.blocker and o.blocker.species == "SNORLAX"
    and o.blocker.level == 30, "blocker carries its battle spec")
  assert(type(o.text) == "string" and o.text:find("\1BLK:", 1, true),
    "marker text keys the battle handler")
  -- Defeat ledger hides it from the live rebuild; undefeated shows.
  local npcId = s.mapId .. "_obj_" .. tostring(o.index)
  game.save = { defeatedTrainers = {} }
  local owStub = { map = { id = s.mapId }, npcs = {}, npcPool = {},
    pooledNPC = function(_, pool, _m, def)
      return { def = def, id = npcId }
    end }
  local realOverworld = game.overworld
  game.overworld = owStub
  Objects.refreshObjects(s)
  assert(#owStub.npcs == 1, "undefeated blocker spawns")
  game.save.defeatedTrainers[npcId] = true
  Objects.refreshObjects(s)
  assert(#owStub.npcs == 0, "defeated blocker stays gone")
  game.overworld = realOverworld
  game.save = nil
end

local function berryTreePlacementCarriesItem()
  local s = freshSession()
  local o = assert(s:placeObjectSpec(5, 5, { objectType = "berrytree",
    berryItem = "POTION", berryCount = 2 }), "berry tree places")
  assert(o.berryItem == "POTION" and o.berryCount == 2,
    "the tree carries its daily berry")
  assert(o.sprite and o.movement == "STAY", "static tree sprite")
end

local function battlerSightFlowsThrough()
  local s = freshSession()
  local o = assert(s:placeObjectSpec(6, 6, { objectType = "trainer",
    trainerClass = "OPP_BROCK", trainerParty = 1, sight = 4,
    sprite = next(Data.sprites) }))
  assert(o.sight == 4, "placed battler keeps its sight range")
  assert(s:setObjectProperty(o, "sight", 0), "sight clears to talk-only")
  assert(o.sight == nil, "zero sight removes the field")
  assert(s:setObjectProperty(o, "sight", Objects.MAX_SIGHT + 5),
    "oversized sight accepted but clamped")
  assert(o.sight == Objects.MAX_SIGHT, "sight clamps at MAX_SIGHT")
end

local function creatorBuildsNewToolShapes()
  local s = freshSession()
  local ui = { hotbar = {}, selected = 1,
    inventory = { items = {}, tab = 2, scroll = 1 } }
  EntityCreator.open(ui, s, "boulder")
  assert(EntityCreator.commit(ui, s), "boulder commits with no input")
  assert(ui.hotbar[1].kind == "entity"
    and ui.hotbar[1].create.objectType == "boulder", "boulder tool armed")
  -- Cut trees are tiles: the entry must be gone.
  for _, t in ipairs(require(
    "mods.mapamap.components.entity_selector").TYPES) do
    assert(t.key ~= "tree", "no CUT TREE entry in the selector")
  end
  EntityCreator.open(ui, s, "headbutt")
  assert(EntityCreator.commit(ui, s), "headbutt commits")
  assert(ui.hotbar[1].kind == "headbutt", "headbutt paint tool armed")
  EntityCreator.open(ui, s, "blocker")
  for _, f in ipairs(ui.entityCreator.fields) do
    if f.key == "pokemon" then f.value = "SNORLAX" end
  end
  assert(EntityCreator.commit(ui, s), "blocker commits")
  assert(ui.hotbar[1].create.objectType == "blocker"
    and ui.hotbar[1].create.level == 30, "blocker tool armed at default lv")
  EntityCreator.open(ui, s, "berrytree")
  for _, f in ipairs(ui.entityCreator.fields) do
    if f.key == "berryCount" then f.value = "3" end
  end
  assert(EntityCreator.commit(ui, s), "berry tree commits")
  assert(ui.hotbar[1].create.objectType == "berrytree"
    and ui.hotbar[1].create.berryCount == 3, "berry tree tool armed")
  EntityCreator.open(ui, s, "hiddenitem")
  for _, f in ipairs(ui.entityCreator.fields) do
    if f.key == "item" then f.value = "POTION" end
  end
  assert(EntityCreator.commit(ui, s), "hidden item commits")
  assert(ui.hotbar[1].create.hidden == true
    and ui.hotbar[1].create.item == "POTION", "hidden item tool armed")
  EntityCreator.open(ui, s, "battler")
  for _, f in ipairs(ui.entityCreator.fields) do
    if f.key == "trainerClass" then f.value = "OPP_BROCK" end
    if f.key == "sight" then f.value = tostring(Objects.MAX_SIGHT + 9) end
    if f.key == "sprite" then f.value = next(Data.sprites) end
  end
  assert(EntityCreator.commit(ui, s), "battler commits")
  assert(ui.hotbar[1].create.sight == Objects.MAX_SIGHT,
    "battler sight clamps at MAX_SIGHT")
end

-- Arrow keys with the creator open must never raise through Input (a crash
-- here took the whole game down because the keyboard wrap is a direct
-- method replacement with no hook containment).
local function creatorArrowKeysSurvive()
  local s = freshSession()
  local ui = { hotbar = {}, selected = 1,
    inventory = { items = {}, tab = 2, scroll = 1 } }
  EntityCreator.open(ui, s, "npc")
  -- Route input through the GLOBAL controller state, exactly like the game.
  Input.hotbar, Input.selected = ui.hotbar, ui.selected
  Input.inventory = ui.inventory
  Input.entityCreator = ui.entityCreator
  for _, k in ipairs({ "up", "down", "left", "right" }) do
    assert(Input.keypressed(s, k), "arrow consumed while form open")
  end
  -- With a dropdown open on the class field.
  for i, f in ipairs(ui.entityCreator.fields) do
    if f.key == "trainerClass" then ui.entityCreator.index = i end
  end
  ui.entityCreator.dropdown = { scroll = 0, filter = "" }
  for _, k in ipairs({ "up", "down", "left", "right", "escape" }) do
    assert(pcall(Input.keypressed, s, k), "dropdown arrow survives")
  end
end

-- Restore every piece of global Input state this suite touches, so later
-- suites start from the same clean slate.
local function teardown()
  Input.entityCreator = nil
  Input.showEntitySelector = false
  Input.showPicker = false
  Input.showBrushEditor = false
  Input.details = nil
  Input.encEditor = nil
  Input.partyEditor = nil
  Input.dialogEditor = nil
  Input.showInventory = true
end

-- Gen 2 hands the whole people rebuild to the engine: World:rebuildPeople
-- owns the object masks, time-of-day rolls, neighbor ghosts and guest list,
-- so a placement must delegate to it instead of hand-assembling ow.npcs
-- (which masks/ghosts never see and the next zoom pass would wipe anyway).
local function refreshObjectsDelegatesToGen2Rebuild()
  local s = freshSession()
  assert(s:placeObjectSpec(1, 1, { objectType = "itemball", item = "POTION" }),
    "the placement lands before the refresh")
  local Gen = require("mods.mapamap.engine.gen")
  local realIsGen2 = Gen.isGen2
  local calls, world = {}, {
    map = { id = s.mapId },
    rebuildPeople = function(self) calls[#calls + 1] = self end,
  }
  local realWorld, realOverworld = game.world, game.overworld
  Gen.isGen2 = function() return true end
  game.overworld = nil          -- Gen.overworld answers game.world here
  game.world = world

  local loadedGen = package.loaded["mods.mapamap.engine.gen"]
  assert(Gen == loadedGen, "the test patches the same Gen module mapamap uses")
  assert(Objects.refreshObjects(s) == true, "gen2 refresh reports handled")
  assert(#calls == 1 and calls[1] == world,
    "the people rebuild runs once on the live World")

  -- The facade shape too: overworld without rebuildPeople still reaches the
  -- World through game.world.
  calls = {}
  game.overworld = { map = world.map }   -- no pooledNPC / no rebuildPeople
  assert(Objects.refreshObjects(s) == true, "facade-shape refresh is handled")
  assert(#calls == 1 and calls[1] == world,
    "the facade falls through to game.world for the rebuild")

  Gen.isGen2 = realIsGen2
  game.world = realWorld
  game.overworld = realOverworld
end

local suite = T.suite("MAPAMAP_ENTITY_EXTRAS", {
  cutTreeResolver,
  headbuttBlockResolverUsesCollisionTile,
  boulderPlacementIsPushable,
  hiddenItemPlacementSetsFlag,
  refreshObjectsAppliesVisibilityGates,
  blockerPlacementMarkerAndFilter,
  berryTreePlacementCarriesItem,
  battlerSightFlowsThrough,
  creatorBuildsNewToolShapes,
  creatorArrowKeysSurvive,
  refreshObjectsDelegatesToGen2Rebuild,
})

suite.teardown = teardown
return suite