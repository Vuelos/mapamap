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
local Details = require("mods.mapamap.components.details")
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
  -- NOTE: two statements ON PURPOSE -- inside a combined `local calls, world
  -- = {}, {...}` declaration the closure would capture the GLOBAL `calls`
  -- (locals only come into scope after their statement), and every stub
  -- invocation would die on a nil index under the engine's pcall.
  local calls = {}
  local world = {
    map = { id = s.mapId },
    rebuildPeople = function(self)
      calls[#calls + 1] = self
    end,
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

-- A session with one laid-out EAST neighbor flush against the edited map's
-- east edge, plus the neighborMaps entry undo routing needs.
local function sessionWithEastNeighbor()
  local s = freshSession()
  local ox = s.def.width * Common.BLOCK_PX
  local east = { width = 2, height = 3, tileset = s.def.tileset,
    blocks = {}, objects = {}, warps = {}, signs = {} }
  for i = 1, 2 * 3 do east.blocks[i] = 0 end
  s.data.maps.EAST_NB = east
  s.neighbors = { { id = "EAST_NB", def = east, ox = ox, oy = 0 } }
  s.neighborMaps = { EAST_NB = { def = east } }
  return s, east
end

-- World cell one cell into the east neighbor's grid (local (1, 1)).
local function eastCell(s)
  return s.def.width * 2 + 1, 1
end

-- targetAt resolves world cells to their owner: the edited map itself for
-- in-body cells, the NEIGHBOR with LOCAL cells across the seam, nil on void.
local function test_targetAtResolvesOwnerMaps()
  local s, east = sessionWithEastNeighbor()
  local own = s:targetAt(2, 2)
  assert(own and not own.neighbor and own.def == s.def
    and own.cellX == 2 and own.cellY == 2,
    "in-body cells resolve to the edited map")
  local wx, wy = eastCell(s)
  local nb = s:targetAt(wx, wy)
  assert(nb and nb.neighbor and nb.def == east and nb.mapId == "EAST_NB"
    and nb.cellX == 1 and nb.cellY == 1,
    "seam-crossing cells resolve to the neighbor with local coords")
  assert(s:targetAt(500, 500) == nil, "void cells have no owner")
end

-- withTargetDef swaps def/mapId/cursor for the duration of fn only.
local function test_withTargetDefSwapsAndRestores()
  local s, east = sessionWithEastNeighbor()
  local origDef, origMapId, oCx, oCy = s.def, s.mapId, s.cursorBx, s.cursorBy
  local seen
  s:withTargetDef({ def = east, mapId = "EAST_NB", cellX = 1, cellY = 2,
    neighbor = true }, function(cx, cy)
    seen = { def = s.def, mapId = s.mapId, cx = cx, cy = cy }
    s.cursorBx, s.cursorBy = 40, 41   -- a placement mutating the cursor
    return "ret"
  end)
  assert(seen.def == east and seen.mapId == "EAST_NB"
    and seen.cx == 1 and seen.cy == 2, "fn runs under the swapped context")
  assert(s.def == origDef and s.mapId == origMapId
    and s.cursorBx == oCx and s.cursorBy == oCy,
    "the context is restored afterwards")
  -- Current-map targets pass straight through.
  local via = s:withTargetDef({ def = s.def, mapId = s.mapId, cellX = 4,
    cellY = 5, neighbor = false }, function(cx, cy) return cx + cy end)
  assert(via == 9, "current-map targets call fn with their cells")
end

-- Placing an entity over the seam lands it on the NEIGHBOR's def with local
-- coords, flags the map dirty and leaves the edited map untouched.
local function test_paintPlacesEntitiesOnNeighborMaps()
  local s, east = sessionWithEastNeighbor()
  local Paint = require("mods.mapamap.domain.paint")
  local ui = { hotbar = {}, selected = 1,
    inventory = { items = {}, tab = 2, scroll = 1 } }
  ui.hotbar[1] = { kind = "entity", entityType = "object",
    create = { objectType = "npc", sprite = next(Data.sprites) } }
  -- The real transform is unavailable headless; drive paintAt through its
  -- cursor path by stubbing Coords.transform/toWorldCell.
  local Coords = require("mods.mapamap.engine.coords")
  local realTransform, realToWorld =
    Coords.transform, Coords.toWorldCell
  Coords.transform = function() return { kind = "flat" } end
  Coords.toWorldCell = function(_, mx, my) return mx, my end
  local wx, wy = eastCell(s)
  local ok = Paint.paintAt(ui, { lastCellX = -1, lastCellY = -1 }, s, wx, wy)
  Coords.transform, Coords.toWorldCell = realTransform, realToWorld

  assert(ok, "the placement succeeds across the seam")
  assert(#east.objects == 1 and #s.def.objects == 0,
    "the entity landed on the neighbor's def, not the edited map")
  local placed = east.objects[1]
  assert(placed.cellX == nil and placed.x == 1 and placed.y == 1,
    "stored in the neighbor's LOCAL walk-grid coords")
  assert(s.neighborDirty.EAST_NB == true,
    "the neighbor is flagged for diff persistence")
  -- Erasing there removes it from the neighbor again.
  Coords.transform = function() return { kind = "flat" } end
  Coords.toWorldCell = function(_, mx, my) return mx, my end
  Paint.eraseAt(ui, { lastCellX = -1, lastCellY = -1 }, s, wx, wy)
  Coords.transform, Coords.toWorldCell = realTransform, realToWorld
  assert(#east.objects == 0, "the neighbor erase removed the entity")
end

-- Dragging an entity across the seam re-homes it: lifted from the owner's
-- list, re-indexed on the destination, both defs captured for undo.
local function test_relocateEntityWorldCrossesSeams()
  local s, east = sessionWithEastNeighbor()
  local obj = assert(s:placeObjectSpec(2, 2,
    { objectType = "npc", sprite = next(Data.sprites) }))
  assert(s.undo:canUndo(), "placement captured an undo step")

  local wx, wy = eastCell(s)
  assert(s:relocateEntityWorld(obj, "object", wx, wy),
    "cross-seam relocation succeeds")
  assert(#s.def.objects == 0 and #east.objects == 1
    and east.objects[1] == obj, "the entity moved between defs")
  assert(obj.x == 1 and obj.y == 1,
    "re-localized into the destination's walk grid")
  assert(obj.index == 1, "fresh index on the destination map")
  assert(s.neighborDirty.EAST_NB == true,
    "the destination map is flagged dirty")

  -- Ctrl+Z restores the pair: first step reverts the destination insert,
  -- second step reverts the owner removal.  Undo restores deep copies, so
  -- match by position rather than table identity.
  s:restoreSnapshot("undo")
  s:restoreSnapshot("undo")
  local back = s.def.objects[1]
  assert(#east.objects == 0 and #s.def.objects == 1 and back ~= nil
    and back.x == 2 and back.y == 2,
    "undo puts the entity back on its original map")
end

-- Swaps the camera transform for flat (mx,my) -> world-cell pass-through and
-- returns the restore function.
local function stubCoords()
  local Coords = require("mods.mapamap.engine.coords")
  local rt, rw = Coords.transform, Coords.toWorldCell
  Coords.transform = function() return { kind = "flat" } end
  Coords.toWorldCell = function(_, mx, my) return mx, my end
  return function()
    Coords.transform, Coords.toWorldCell = rt, rw
  end
end

-- Painting a picked-up sign tool CLONES the message (same text) silently:
-- no Details popup, on the edited map and across the seam alike.
local function test_signPickPaintClonesMessageWithoutDetails()
  local s, east = sessionWithEastNeighbor()
  local unstub = stubCoords()
  local Paint = require("mods.mapamap.domain.paint")
  local ui = { hotbar = {}, selected = 1,
    inventory = { items = {}, tab = 2, scroll = 1 } }
  ui.hotbar[1] = { kind = "entity", entityType = "sign",
    sign = { text = "KEEP OFF", label = "X", index = 3 } }

  local ok = Paint.paintAt(ui, { lastCellX = -1, lastCellY = -1 }, s, 3, 3)
  assert(ok, "the sign copy places")
  assert(#s.def.signs == 1 and s.def.signs[1].text == "KEEP OFF",
    "the clone carries the original message")
  assert(ui.details == nil,
    "placing a sign copy must not open the Details panel")

  local wx, wy = eastCell(s)
  ok = Paint.paintAt(ui, { lastCellX = -1, lastCellY = -1 }, s, wx, wy)
  unstub()
  assert(ok and #east.signs == 1 and east.signs[1].text == "KEEP OFF",
    "seam-crossing clones keep the message too")
  assert(s.neighborDirty.EAST_NB == true,
    "the neighbor clone is flagged for persistence")
end

-- A right-click over ANY entity -- root object, sign, or a neighbor's
-- entity -- opens its Details panel immediately at PRESS (dragging entities
-- was removed; moving is the Details MOVE button).
local function test_rmbClickOpensDetailsOnAnyEntity()
  local s, east = sessionWithEastNeighbor()
  local Input = require("mods.mapamap.controllers.input")
  local unstub = stubCoords()
  local obj = assert(s:placeObjectSpec(2, 2,
    { objectType = "npc", sprite = next(Data.sprites) }))
  local sign = assert(s:placeSignSpec(4, 4, { text = "read me" }))
  -- Neighbor entity: eastCell resolves to local (1, 1).
  local nbObj = { x = 1, y = 1, index = 1,
    sprite = next(Data.sprites), object_type = "NPC" }
  east.objects[#east.objects + 1] = nbObj

  Input.reset()
  Input.moveTarget, Input.warpDestPick = nil, false

  -- Root-map object.
  assert(Input.mousepressed(s, {}, 2, 2, 2), "RMB consumed")
  assert(Input.details ~= nil and Input.details.entity == obj
    and Input.details.entityType == "object" and not Input.details.readOnly,
    "right-clicking a root object opens its Details")
  Details.close(Input)

  -- Root-map sign.
  assert(Input.mousepressed(s, {}, 4, 4, 2))
  assert(Input.details ~= nil and Input.details.entity == sign
    and Input.details.entityType == "sign",
    "right-clicking a sign opens its Details")
  Details.close(Input)

  -- Neighbor entity: read-only Details.
  local wx, wy = eastCell(s)
  assert(Input.mousepressed(s, {}, wx, wy, 2))
  assert(Input.details ~= nil and Input.details.entity == nbObj
    and Input.details.readOnly == true,
    "right-clicking a neighbor's entity opens read-only Details")
  Details.close(Input)

  unstub()
end

-- Entity dragging is gone entirely: a right-drag neither moves an entity nor
-- erases through it -- the press already opened Details and the world state
-- is untouched however far the pointer travels before release.
local function test_rmbDragDoesNotMoveEntities()
  local s, east = sessionWithEastNeighbor()
  local Input = require("mods.mapamap.controllers.input")
  local unstub = stubCoords()
  local obj = assert(s:placeObjectSpec(2, 2,
    { objectType = "npc", sprite = next(Data.sprites) }))
  Input.reset()
  Input.moveTarget, Input.warpDestPick = nil, false

  local wx, wy = eastCell(s)
  assert(Input.mousepressed(s, {}, 2, 2, 2))
  assert(Input.mousemoved(s, 40, 30))
  -- The release has nothing pending under the press-opens model (returns
  -- false); the state assertions below carry the guarantee.
  Input.mousereleased(s, wx, wy, 2)
  assert(#s.def.objects == 1 and s.def.objects[1] == obj,
    "a right-drag never moves an entity")
  assert(#east.objects == 0, "the neighbor stays untouched")
  assert(Input.details ~= nil and Input.details.entity == obj,
    "the Details panel opened at press and stays open")

  unstub()
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
  test_targetAtResolvesOwnerMaps,
  test_withTargetDefSwapsAndRestores,
  test_paintPlacesEntitiesOnNeighborMaps,
  test_relocateEntityWorldCrossesSeams,
  test_signPickPaintClonesMessageWithoutDetails,
  test_rmbClickOpensDetailsOnAnyEntity,
  test_rmbDragDoesNotMoveEntities,
})

suite.teardown = teardown
return suite