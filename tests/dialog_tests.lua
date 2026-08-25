-- Dialog editor tests: the pure buffer model (insert/delete/newline/page
-- break/caps/upper-all/cursor moves), the game-accurate preview pagination,
-- write-back through onSave, cancel semantics, and both entry points --
-- Details text fields on placed entities and the Entity Creator's dialog
-- fields (draft parked and restored with the composed text).

package.path = "../../../?.lua;" .. package.path

if not _G.love then _G.love = require("tests.love_stub") end

local Data = require("src.core.Data")
if not (Data.maps and Data.maps.PALLET_TOWN) then Data:load() end
local data = Data

local Session = require("mods.mapamap.domain.edit_session")
local Input = require("mods.mapamap.controllers.input")
local Details = require("mods.mapamap.components.details")
local EntityCreator = require("mods.mapamap.components.entity_creator")
local DialogEditor = require("mods.mapamap.components.dialog_editor")

local function makeMod()
  return {
    log = { warn = function() end, info = function() end,
            error = function() end },
    save = { get = function() return nil end, set = function() end },
    ui = { Font = { draw = function() end } },
  }
end

local game = { data = data, overworld = nil }

-- A fresh editor state bound to nothing (pure buffer work).
local function blank(text)
  local ui = {}
  DialogEditor.open(ui, makeMod() and Session.new(makeMod(), game,
    "PALLET_TOWN"), { title = "T", text = text or "" })
  return ui, ui.dialogEditor
end

function test_bufferInsertAndNewline()
  local _, d = blank()
  for ch in ("hello"):gmatch(".") do DialogEditor.insertChar(d, ch) end
  assert(DialogEditor.getText(d) == "hello", "plain typing joins")
  DialogEditor.insertMarker(d, "\n")
  for ch in ("world"):gmatch(".") do DialogEditor.insertChar(d, ch) end
  assert(DialogEditor.getText(d) == "hello\nworld",
    "the newline marker is the real \\n the engine prints")
  assert(d.curLine == 2 and d.curCol == 6, "caret rides the second line")
end

function test_backspaceJoinsLinesAndClampsAtStart()
  local _, d = blank("ab\ncd")
  d.curLine, d.curCol = 2, 1
  DialogEditor.backspace(d)
  assert(DialogEditor.getText(d) == "abcd", "backspace at a seam joins lines")
  assert(d.curLine == 1 and d.curCol == 3, "caret lands at the seam")
  -- Jump to the end, then walk backwards off the front of the buffer.
  DialogEditor.toLineEnd(d)
  assert(d.curCol == 5, "line-end sits past the last character")
  for _ = 1, 4 do DialogEditor.backspace(d) end
  assert(DialogEditor.getText(d) == "", "characters delete backwards")
  DialogEditor.backspace(d)
  assert(DialogEditor.getText(d) == "", "backspace clamps on empty buffer")
end

function test_pageBreakMarkerStaysInline()
  local _, d = blank("PAGE ONE")
  DialogEditor.insertMarker(d, "\f")
  for ch in ("PAGE TWO"):gmatch(".") do DialogEditor.insertChar(d, ch) end
  local text = DialogEditor.getText(d)
  assert(text:find("\f", 1, true), "shift-enter stores a page-break marker")
  local pages = DialogEditor.previewPages(text)
  assert(#pages == 2, "the paginator splits at the page break")
end

function test_capsForcesLettersOnly()
  local _, d = blank()
  DialogEditor.toggleCaps(d)
  for _, ch in ipairs({ "h", "i", "!", "1", "x" }) do
    DialogEditor.insertChar(d, ch)
  end
  assert(DialogEditor.getText(d) == "HI!1X",
    "CAPS upper-cases letters, never digits or punctuation")
end

function test_upperAllConvertsWholeBuffer()
  local _, d = blank("Mixed Case text\nsecond Line")
  DialogEditor.upperAll(d)
  assert(DialogEditor.getText(d) == "MIXED CASE TEXT\nSECOND LINE",
    "ALL-CAPS converts every line, newlines intact")
end

function test_cursorArrowsTraverseLines()
  local _, d = blank("abc\ndefgh")
  d.curLine, d.curCol = 1, 4
  DialogEditor.moveH(d, 1)      -- past end of line 1 -> head of line 2
  assert(d.curLine == 2 and d.curCol == 1, "right wraps to the next line")
  DialogEditor.moveH(d, -1)     -- back to tail of line 1
  assert(d.curLine == 1 and d.curCol == 4, "left wraps back up")
  DialogEditor.moveV(d, 1)
  assert(d.curLine == 2 and d.curCol == 4, "down keeps the column")
  DialogEditor.moveV(d, 5)
  assert(d.curLine == #DialogEditor.lines("abc\ndefgh"),
    "down clamps at the last line")
  DialogEditor.moveV(d, -9)
  assert(d.curLine == 1, "up clamps at the first line")
end

function test_previewMatchesEnginePagination()
  -- 30 chars: soft-wrapped into two rows by the 18-glyph budget.
  local long = string.rep("A", 30)
  local pages = DialogEditor.previewPages(long)
  assert(#pages == 1 and #pages[1] >= 2,
    "a too-long line soft-wraps inside one page")
  -- Engine module available in-process? Then it must be THE same call.
  local okT, TextBox = pcall(require, "src.render.TextBox")
  if okT and TextBox and TextBox.paginate then
    local direct = TextBox.paginate(long, DialogEditor.MAX_COLS)
    assert(#pages[1] == #direct[1],
      "preview delegates to the engine's paginator when present")
  end
end

function test_finishSavesThroughOnSaveOnlyWhenConfirmed()
  local saved, saveCount = nil, 0
  local ui = {}
  DialogEditor.open(ui, Session.new(makeMod(), game, "PALLET_TOWN"), {
    title = "DIALOG",
    text = "",
    onSave = function(t) saved, saveCount = t, saveCount + 1 end,
  })
  local d = ui.dialogEditor
  for ch in ("Hi"):gmatch(".") do DialogEditor.insertChar(d, ch) end
  DialogEditor.key(ui, nil, "escape")          -- cancel path
  assert(saved == nil and saveCount == 0, "Esc cancels without writing")
  -- Re-open and confirm with Tab.
  DialogEditor.open(ui, Session.new(makeMod(), game, "PALLET_TOWN"), {
    title = "DIALOG", text = "Yo",
    onSave = function(t) saved, saveCount = t, saveCount + 1 end,
  })
  DialogEditor.key(ui, nil, "tab")
  assert(saved == "Yo" and saveCount == 1, "Tab confirms and writes once")
  assert(ui.dialogEditor == nil, "finish closes the panel")
end

function test_detailsDialogFieldOpensComposerAndWritesBack()
  local s = assert(Session.new(makeMod(), game, "PALLET_TOWN"))
  s.def.objects = {}
  local sign = s:placeSignSpec(1, 1, { text = "...", label = "Board" })
  sign.text = nil -- compose from scratch (the caret starts at buffer end)
  local ui = {}
  Details.open(ui, s, { entity = sign, entityType = "sign" })
  -- Activate the Text field.
  for i, f in ipairs(ui.details.fields) do
    if f.key == "text" then ui.details.index = i break end
  end
  Details.activate(ui, s, ui.details)
  assert(ui.details == nil and ui.dialogEditor ~= nil,
    "Enter on Text opens the composer")
  -- Type a two-line message and DONE via mouse hit on the done button.
  local d = ui.dialogEditor
  for ch in ("STOP"):gmatch(".") do DialogEditor.insertChar(d, ch) end
  DialogEditor.insertMarker(d, "\n")
  for ch in ("GO"):gmatch(".") do DialogEditor.insertChar(d, ch) end
  DialogEditor.finish(ui, true)
  assert(sign.text == "STOP\nGO",
    "DONE writes the composed message onto the entity")
  assert(s.mapChanged, "dialog edits mark the map changed")
end

function test_creatorDialogFieldRoundTripsDraft()
  local mod = makeMod()
  local s = assert(Session.new(mod, game, "PALLET_TOWN"))
  local ui = {}
  EntityCreator.open(ui, s, "npc")
  local form = ui.entityCreator
  for _, f in ipairs(form.fields) do
    if f.key == "label" then f.value = "Old Man" end
    if f.key == "sprite" then f.value = next(data.sprites) end
  end
  -- Enter on the Dialog field opens the composer with the draft parked.
  for i, f in ipairs(form.fields) do
    if f.key == "text" then form.index = i break end
  end
  EntityCreator.key(ui, s, "return")
  assert(ui.entityCreator == nil and ui.dialogEditor ~= nil,
    "Dialog field opens the composer")
  local d = ui.dialogEditor
  for ch in ("BEWARE"):gmatch(".") do DialogEditor.insertChar(d, ch) end
  DialogEditor.finish(ui, true)
  -- The creation form is restored with the composed text AND other values.
  assert(ui.entityCreator ~= nil, "closing restores the creation form")
  for _, f in ipairs(ui.entityCreator.fields) do
    if f.key == "text" then
      assert(f.value == "BEWARE", "composed text lands in the Dialog field")
    elseif f.key == "label" then
      assert(f.value == "Old Man", "other typed values survive the round-trip")
    elseif f.key == "sprite" then
      assert(f.value ~= nil, "the sprite slot survives the round-trip")
    end
  end
end

function test_spaceKeyInsertsSpace()
  local ui, d = blank()
  -- LOVE names the space bar "space", not " ".
  DialogEditor.key(ui, nil, "space")
  DialogEditor.key(ui, nil, "a")
  assert(DialogEditor.getText(d) == " a", "the space key inserts a space")
end

function test_rectSmoke()
  -- Regression: rect() once read an uppercase S while the local was
  -- lowercase, crashing every open with "arithmetic on nil".
  local x, y, w, h = DialogEditor.rect(640, 576)
  assert(w and h and w > 100 and h > 100, "rect computes a real box")
  assert(x >= 0 and y >= 0, "rect stays on screen")
end

return {
  name = "MAPAMAP_DIALOG_EDITOR",
  tests = {
    "test_rectSmoke",
    "test_bufferInsertAndNewline",
    "test_backspaceJoinsLinesAndClampsAtStart",
    "test_pageBreakMarkerStaysInline",
    "test_capsForcesLettersOnly",
    "test_upperAllConvertsWholeBuffer",
    "test_cursorArrowsTraverseLines",
    "test_previewMatchesEnginePagination",
    "test_spaceKeyInsertsSpace",
    "test_finishSavesThroughOnSaveOnlyWhenConfirmed",
    "test_detailsDialogFieldOpensComposerAndWritesBack",
    "test_creatorDialogFieldRoundTripsDraft",
  },
}
