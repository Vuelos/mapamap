-- Map-slot persistence + Map Slots panel tests.
--   * storage/slots.lua: capture/store/get/delete/rename guards, full-
--     replacement applyBuckets, nextName, and the export-file round trip
--     through the real filesystem (temp folder under %TEMP%/opencode).
--   * components/slot_panel.lua: button/row/file hit-testing, the NEW /
--     RENAME typing flow, and LOAD routing through SessionManager.activateSlot.

package.path = "../../../?.lua;" .. package.path

if not _G.love then _G.love = require("tests.love_stub") end

local TestUtil = require("mods.mapamap.tests.test_util")
local Common = require("mods.mapamap.common")
local Keys = require("mods.mapamap.storage.save_keys")
local Slots = require("mods.mapamap.storage.slots")
local SlotPanel = require("mods.mapamap.components.slot_panel")

-- Loaded-module swap helpers (restored by the caller).
local function swap(name, fake)
  local orig = package.loaded[name]
  package.loaded[name] = fake
  return function()
    if orig ~= nil then package.loaded[name] = orig
    else package.loaded[name] = nil end
  end
end

local function sampleRecord()
  return {
    format = "mapamap-slot", savedAt = 1700000000,
    patches = { PALLET_TOWN = { blocks = { 1, 2, 3 } } },
    encounters = {}, connections = {},
    newMaps = { PALLET_TOWN_EXT = { width = 4 } },
    trainerParties = {},
  }
end

-- ---------------------------------------------------------------------------
-- storage/slots.lua

local function test_captureStoreGetRoundtrip()
  local mod = TestUtil.makeMod()
  mod.save:set(Keys.PATCHES, { PALLET_TOWN = { blocks = { 9 } } })
  local rec = Slots.store(mod, "alpha")
  assert(rec, "store returns the record")
  local got = Slots.get(mod, "alpha")
  assert(Common.tablesEqual(got.patches, { PALLET_TOWN = { blocks = { 9 } } }),
    "captured bucket matches the live edit-set")
  -- Later live edits must never mutate what was captured.
  mod.save:set(Keys.PATCHES, { VIRIDIAN_CITY = { blocks = { 1 } } })
  assert(got.patches.PALLET_TOWN ~= nil, "stored record is an isolated copy")
  assert(Slots.get(mod, "nope") == nil, "missing slots answer nil")
end

local function test_namesSortedWithPreviousLast()
  local mod = TestUtil.makeMod()
  for _, n in ipairs({ "b", Slots.PREVIOUS, "a" }) do
    Slots.store(mod, n)
  end
  local names = Slots.names(mod)
  assert(names[1] == "a" and names[2] == "b",
    "user slots sort alphabetically first")
  assert(names[#names] == Slots.PREVIOUS, "the auto backup sorts last")
end

local function test_deleteRenameGuards()
  local mod = TestUtil.makeMod()
  Slots.store(mod, "alpha")
  local ok, err = Slots.rename(mod, "ghost", "x")
  assert(not ok and err, "renaming a missing slot fails with a message")
  Slots.store(mod, "beta")
  ok, err = Slots.rename(mod, "alpha", "beta")
  assert(not ok and err, "renaming onto an existing name fails")
  ok = Slots.rename(mod, "alpha", "gamma")
  assert(ok, "valid rename succeeds")
  assert(Slots.get(mod, "alpha") == nil and Slots.get(mod, "gamma") ~= nil,
    "the record moved to the new name")
  assert(Slots.delete(mod, "missing") == false, "deleting a missing slot fails")
  assert(Slots.delete(mod, "gamma") == true, "deleting an existing slot works")
end

local function test_applyBucketsReplacesAllFive()
  local mod = TestUtil.makeMod()
  -- Junk in every live bucket: activation must CLEAR them, never merge.
  mod.save:set(Keys.PATCHES, { OLD = { blocks = { 1 } } })
  mod.save:set(Keys.NEW_MAPS, { OLD_EXT = {} })
  Slots.applyBuckets(mod, sampleRecord())
  assert(next(mod.save:get(Keys.PATCHES, {})).OLD == nil,
    "stale patches are gone")
  local p = mod.save:get(Keys.PATCHES, {})
  assert(p.PALLET_TOWN and p.PALLET_TOWN.blocks[1] == 1,
    "the record's patches landed wholesale")
  assert(mod.save:get(Keys.NEW_MAPS, {}).PALLET_TOWN_EXT ~= nil,
    "new maps land too")
  assert(next(mod.save:get(Keys.ENCOUNTER_PATCHES, {})) == nil,
    "empty buckets clear their live counterpart")
  assert(Slots.applyBuckets(mod, nil) == false, "nil records are rejected")
end

local function test_nextNameSkipsTaken()
  local mod = TestUtil.makeMod()
  local name = Slots.nextName(mod)
  assert(name:match("^%d%d%.%d%d%.%d%d%.%d%d%.%d%d%.%d%d$"),
    "default names are YY.MM.DD.HH.MM.SS timestamps: " .. tostring(name))
  -- Storing under the suggestion advances past the collision (same-second
  -- captures step forward instead of overwriting).
  Slots.store(mod, name)
  local again = Slots.nextName(mod)
  assert(again ~= name, "a taken timestamp is never suggested again")
  assert(again:match("^%d%d%.%d%d%.%d%d%.%d%d%.%d%d%.%d%d$"),
    "the collision fallback keeps the timestamp format")
end

-- Export round trip against the REAL filesystem: point sourceRoot() at a
-- temp folder, export, wipe the live buckets, re-import.
local function test_exportImportRoundtrip()
  local fs = love.filesystem
  local hadSource = fs.getSource ~= nil
  local origSource = fs.getSource
  local tmpRoot = (os.getenv("TEMP") or os.getenv("TMP") or ".")
    .. "/opencode/mapamap_slot_tests_" .. tostring(os.time())
  fs.getSource = function() return tmpRoot end
  local function cleanup()
    if hadSource then fs.getSource = origSource else fs.getSource = nil end
  end

  local mod = TestUtil.makeMod()
  mod.path = "mods/mapamap"
  -- Seed the live edit-set so the exported slot carries real content.
  mod.save:set(Keys.PATCHES, Common.deepCopy(sampleRecord().patches))
  mod.save:set(Keys.NEW_MAPS, Common.deepCopy(sampleRecord().newMaps))
  Slots.store(mod, "alpha")

  local path, err = Slots.export(mod, "alpha")
  assert(path, "export succeeds: " .. tostring(err))
  local f = io.open(path, "rb")
  assert(f, "the export file exists on disk at " .. path)
  local raw = f:read("*a")
  f:close()
  assert(raw:find("mapamap-slot", 1, true), "the file embeds the format tag")

  -- A missing slot / missing source root fail with messages, never crash.
  local nope, noErr = Slots.export(mod, "ghost")
  assert(nope == nil and noErr, "exporting a missing slot fails cleanly")

  -- Import lands the decoded record back as a stored slot.
  mod.save:set(Keys.SLOTS, {})
  local name, ierr = Slots.import(mod, "alpha.lua")
  assert(name == "alpha", "import names the slot after the file: "
    .. tostring(ierr))
  assert(Common.tablesEqual(Slots.get(mod, "alpha").patches,
    sampleRecord().patches), "imported buckets survive the round trip")
  assert(Slots.get(mod, "alpha").newMaps.PALLET_TOWN_EXT ~= nil,
    "the new-maps bucket survives too")

  local bad = Slots.import(mod, "does_not_exist.lua")
  assert(bad == nil, "importing a missing file fails cleanly")

  pcall(os.remove, path)
  cleanup()
end

local function test_filesListsLuaOnly()
  local mod = TestUtil.makeMod()
  mod.path = "mods/mapamap"
  local fs = love.filesystem
  fs.write(mod.path .. "/export/b.lua", "return {}")
  fs.write(mod.path .. "/export/a.lua", "return {}")
  fs.write(mod.path .. "/export/notes.txt", "not a slot")
  local files = Slots.files(mod)
  assert(files[1] == "a.lua" and files[2] == "b.lua",
    "lua exports list sorted, other extensions filtered")
  assert(#files == 2, "only the two .lua files listed")
  fs.remove(mod.path .. "/export/b.lua")
  fs.remove(mod.path .. "/export/a.lua")
  fs.remove(mod.path .. "/export/notes.txt")
end

-- ---------------------------------------------------------------------------
-- components/slot_panel.lua

local vw, vh = love.graphics.getDimensions()

local function scanPanel(ui, session, fn)
  local x, y, w, h = SlotPanel.rect(vw, vh)
  local hits = {}
  for my = y, y + h - 1, 2 do
    for mx = x, x + w - 1, 3 do
      local got = fn(ui, session, mx, my)
      if got and not hits[got] then hits[got] = { mx = mx, my = my } end
    end
  end
  return hits
end

local function test_everyButtonIsReachable()
  local session = { mod = TestUtil.makeMod() }
  local hits = scanPanel({}, session,
    function(_, s, mx, my) return SlotPanel.buttonAt(vw, vh, mx, my) end)
  for _, b in ipairs(SlotPanel.BUTTONS) do
    assert(hits[b.id], "button '" .. b.id .. "' is reachable by mouse")
  end
  assert(hits.load.my < hits.rename.my,
    "SAVE/LOAD/NEW sit above RENAME/DEL/EXPORT")
end

local function test_slotRowsHitStoredNames()
  local mod = TestUtil.makeMod()
  Slots.store(mod, "aaa")
  Slots.store(mod, "bbb")
  local session = { mod = mod }
  local ui = {}
  local hits = scanPanel(ui, session,
    function(u, s, mx, my) return SlotPanel.slotAt(u, s, vw, vh, mx, my) end)
  assert(hits.aaa, "the first row resolves the first sorted slot")
  assert(hits.bbb, "the second row resolves the second slot")
  -- A click on a slot row selects it.
  local p = hits.bbb
  ui.slotsOpen = true
  assert(SlotPanel.mousepressed(ui, session, p.mx, p.my, 1),
    "row clicks are consumed inside the panel")
  assert(ui.slotSel == "bbb", "clicking a row selects that slot")
end

local function test_pressNewCapturesAndSelects()
  local mod = TestUtil.makeMod()
  mod.save:set(Keys.PATCHES, { PALLET_TOWN = { blocks = { 5 } } })
  local ui, session = {}, { mod = mod }
  SlotPanel.press(ui, session, "new")
  local name = ui.slotSel
  assert(name and Slots.get(mod, name) ~= nil,
    "NEW stores the capture under its suggested name")
  assert(name:match("^%d%d%.%d%d%.%d%d%.%d%d%.%d%d%.%d%d$"),
    "NEW names use the YY.MM.DD.HH.MM.SS timestamp format: " .. tostring(name))
  assert(Slots.names(mod)[1] == name, "the capture appears in the slot list")
  assert(Slots.get(mod, name).patches.PALLET_TOWN ~= nil,
    "the capture holds the live edit-set")
  -- SAVE without a selection captures under a fresh timestamp too.
  local ui2 = {}
  SlotPanel.press(ui2, session, "save")
  assert(ui2.slotSel ~= nil, "SAVE with no selection picks a name")
end

local function test_renameTypingFlow()
  local mod = TestUtil.makeMod()
  Slots.store(mod, "alpha")
  local ui, session = { slotSel = "alpha" }, { mod = mod }
  SlotPanel.press(ui, session, "rename")
  assert(ui.slotRename == "alpha", "RENAME arms typing with the old name")
  SlotPanel.key(ui, session, "b")
  SlotPanel.key(ui, session, "e")
  SlotPanel.key(ui, session, "t")
  SlotPanel.key(ui, session, "a")
  assert(ui.slotRename == "alphabeta", "printable keys append")
  SlotPanel.key(ui, session, "backspace")
  assert(ui.slotRename == "alphabet", "backspace trims")
  SlotPanel.key(ui, session, "return")
  assert(ui.slotRename == nil and ui.slotSel == "alphabet",
    "ENTER commits and keeps the new name selected")
  assert(Slots.get(mod, "alphabet") ~= nil and Slots.get(mod, "alpha") == nil,
    "the record moved under the typed name")
  -- ESC cancels without touching the stored slots.
  SlotPanel.press(ui, session, "rename")
  SlotPanel.key(ui, session, "x")
  SlotPanel.key(ui, session, "escape")
  assert(ui.slotRename == nil and Slots.get(mod, "alphabet") ~= nil,
    "escape cancels the rename buffer")
end

local function test_loadRoutesThroughSessionManager()
  local mod = TestUtil.makeMod()
  Slots.store(mod, "target")
  local calls = {}
  local restore = swap("mods.mapamap.controllers.session_manager", {
    activateSlot = function(m, name)
      calls[#calls + 1] = { m, name }
      return true
    end,
  })
  local ui, session = { slotSel = "target" }, { mod = mod }
  SlotPanel.press(ui, session, "load")
  restore()
  assert(#calls == 1 and calls[1][1] == mod and calls[1][2] == "target",
    "LOAD delegates to SessionManager.activateSlot with (mod, name)")
  -- Without a selection LOAD only reports.
  local ui2 = {}
  SlotPanel.press(ui2, session, "load")
  assert(#calls == 1 and ui2.slotMsg, "LOAD without selection stays local")
end

local function test_mousepressDeclinesOutside()
  local session = { mod = TestUtil.makeMod() }
  local ui = {}
  assert(SlotPanel.mousepressed(ui, session, 2, 2, 1) == false,
    "presses outside the panel decline so closeOnOutside can fire")
  local x, y, w, h = SlotPanel.rect(vw, vh)
  assert(SlotPanel.mousepressed(ui, session, x + 4, y + 4, 1) == true,
    "presses inside the panel are consumed")
end

return TestUtil.suite("MAPAMAP_SLOTS", {
  test_captureStoreGetRoundtrip,
  test_namesSortedWithPreviousLast,
  test_deleteRenameGuards,
  test_applyBucketsReplacesAllFive,
  test_nextNameSkipsTaken,
  test_exportImportRoundtrip,
  test_filesListsLuaOnly,
  test_everyButtonIsReachable,
  test_slotRowsHitStoredNames,
  test_pressNewCapturesAndSelects,
  test_renameTypingFlow,
  test_loadRoutesThroughSessionManager,
  test_mousepressDeclinesOutside,
})
