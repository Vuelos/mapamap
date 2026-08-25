-- Dialog Editor: compose NPC/sign messages in a multi-line editor with an
-- in-game-style live preview.
--
-- The buffer is EXACTLY the string the engine prints: newlines are the real
-- "\n" second-line marker, Shift+Enter writes the "\f" page-break marker,
-- and the preview runs the same paginator the game's TextBox uses
-- (src/render/TextBox.lua paginate: 18-column soft wrap, \v scroll,
-- \f pages), so what you see is what the player will read.
--
-- Uppercase support: typed letters respect Shift (the mod receives raw
-- lowercase key names), a CAPS toggle forces every typed letter to upper
-- case, and ALL-CAPS converts the whole buffer (gen-1 authenticity).
--
-- Opened from Details (Dialog/Text fields on placed entities) and from the
-- Entity Creator's Dialog/Text fields; a creator-opened editor parks the
-- form draft and restores it with the composed text on DONE.

local Common = require("mods.mapamap.common")
local Panel = require("mods.mapamap.components.panel")
local Text = require("mods.mapamap.components.text")

local DialogEditor = {}

DialogEditor.MAX_COLS = 18   -- vanilla textbox inner width, in glyphs
DialogEditor.CH_PX = 12      -- editor glyph cell width at font scale 2

local PAD = Panel.PAD
local ROW_H = Panel.ROW_H

-- The editing model lives in domain/text_buffer.lua (pure, headless-testable);
-- this component is its view + engine-preview + save/cancel wiring.
local Buffer = require("mods.mapamap.domain.text_buffer")

function DialogEditor.lines(text) return Buffer.lines(text) end
function DialogEditor.join(lines) return Buffer.join(lines) end

local function line(d)
  return d.lines[d.curLine] or ""
end

local function isLetter(ch)
  return #ch == 1 and ch:match("%a") ~= nil
end

-- Re-joins the (already mutated) line list into text and clamps the caret.
local function touch(d)
  d.text = Buffer.join(d.lines)
  d.curLine = math.max(1, math.min(d.curLine or 1, #d.lines))
  local l = d.lines[d.curLine] or ""
  d.curCol = math.max(1, math.min(d.curCol or 1, #l + 1))
end

function DialogEditor.setText(d, text) return Buffer.setText(d, text) end
function DialogEditor.getText(d) return Buffer.getText(d) end
function DialogEditor.insertChar(d, ch) return Buffer.insertChar(d, ch) end
function DialogEditor.insertMarker(d, m) return Buffer.insertMarker(d, m) end
function DialogEditor.backspace(d) return Buffer.backspace(d) end
function DialogEditor.deleteChar(d) return Buffer.deleteChar(d) end
function DialogEditor.moveH(d, dx) return Buffer.moveH(d, dx) end
function DialogEditor.moveV(d, dy) return Buffer.moveV(d, dy) end
function DialogEditor.toLineStart(d) return Buffer.toLineStart(d) end
function DialogEditor.toLineEnd(d) return Buffer.toLineEnd(d) end
function DialogEditor.toggleCaps(d) return Buffer.toggleCaps(d) end
function DialogEditor.upperAll(d) return Buffer.upperAll(d) end

-- ---------------------------------------------------------------------------
-- Preview: the exact pages the game's TextBox will show.

-- Falls back to a naive wrap when the engine modules are unavailable
-- (headless tests): split on \n, hard-cut every MAX_COLS glyphs, \f pages.
local function naivePages(text)
  local pages, page = {}, {}
  for line in (tostring(text or "") .. "\f"):gmatch("(.-)\f") do
    for raw in (line .. "\n"):gmatch("(.-)\n") do
      while #raw > DialogEditor.MAX_COLS do
        page[#page + 1] = raw:sub(1, DialogEditor.MAX_COLS)
        raw = raw:sub(DialogEditor.MAX_COLS + 1)
      end
      page[#page + 1] = raw
    end
    if #page > 0 then pages[#pages + 1] = page; page = {} end
  end
  if #pages == 0 then pages[1] = { "" } end
  return pages
end

-- Pages of visible lines: { { line, ... }, ... } honoring \f page breaks,
-- \v/\n line starts and the 18-glyph soft wrap.
function DialogEditor.previewPages(text)
  local okT, TextBox = pcall(require, "src.render.TextBox")
  if okT and TextBox and type(TextBox.paginate) == "function" then
    local okP, pages = pcall(TextBox.paginate, text, DialogEditor.MAX_COLS)
    if okP and type(pages) == "table" and #pages > 0 then
      return pages
    end
  end
  return naivePages(text)
end

-- ---------------------------------------------------------------------------
-- Geometry

-- Integer scale for the native-resolution (160x48 px) game-textbox preview.
local function previewScale(w)
  return math.max(1, math.min(3, math.floor((w - PAD * 2 - 16) / 160)))
end

function DialogEditor.rect(vw, vh)
  local Hotbar = require("mods.mapamap.components.hotbar")
  local w = math.min(vw - 32, 700)
  local S = previewScale(w)
  local h = PAD + Panel.TITLE_H + Panel.TITLE_GAP   -- title band
          + 14                                      -- status line
          + 4 * (ROW_H + 4)                         -- four editable rows
          + 8 + 56 * S + 8                          -- native-size preview
          + ROW_H + 10                              -- button row
          + PAD
  local x = math.floor((vw - w) / 2)
  local y = vh - Hotbar.SLOT - Hotbar.PAD - Hotbar.GAP - h - 8
  if y < 8 then y = 8 end
  return x, y, w, h
end

function DialogEditor.over(vw, vh, mx, my)
  return Panel.over(DialogEditor.rect, vw, vh, mx, my)
end

-- The action chips along the bottom: DONE CANCEL | CAPS ALL-CAPS.
local function buttonRects(vw, vh)
  local x, y, w, h = DialogEditor.rect(vw, vh)
  local by = y + h - PAD - ROW_H
  local bw = 88
  return {
    done = { x + PAD, by, bw, ROW_H },
    cancel = { x + PAD + bw + 8, by, bw, ROW_H },
    caps = { x + w - PAD * 2 - bw * 2 - 8, by, bw, ROW_H },
    upper = { x + w - PAD - bw, by, bw, ROW_H },
  }
end

local function hitBtn(vw, vh, mx, my)
  local btns = buttonRects(vw, vh)
  for name, r in pairs(btns) do
    if mx >= r[1] and mx < r[1] + r[3] and my >= r[2] and my < r[2] + r[4] then
      return name
    end
  end
  return nil
end

local EDIT_ROWS = 4

-- The editable rows sit under the status line; scroll-window follows the
-- caret.  Returns top, visibleRows, firstVisibleLine, rowHeight.
local function editView(vw, vh, d)
  local _, y = DialogEditor.rect(vw, vh)
  local top = y + PAD + Panel.TITLE_H + Panel.TITLE_GAP + 14
  local rowH = ROW_H + 4
  local first = math.max(1, math.min(d.curLine - EDIT_ROWS + 1,
    #d.lines - EDIT_ROWS + 1))
  if d.curLine < first then first = d.curLine end
  return top, EDIT_ROWS, first, rowH
end

-- ---------------------------------------------------------------------------
-- Open / finish

-- opts: { title, text, onSave, returnCreator }
function DialogEditor.open(ui, session, opts)
  opts = opts or {}
  ui.showInventory = true
  ui.details = nil
  ui.entityCreator = nil
  ui.encEditor = nil
  ui.partyEditor = nil
  ui.showPicker = false
  ui.dialogEditor = {
    session = session,
    title = opts.title or "DIALOG",
    onSave = opts.onSave,
    returnCreator = opts.returnCreator,
    text = tostring(opts.text or ""),
    curLine = 1,
    curCol = 1,
    caps = false,
    error = nil,
  }
  DialogEditor.setText(ui.dialogEditor, opts.text)
  -- start the caret at the END of the message
  local d = ui.dialogEditor
  d.curLine = #d.lines
  d.curCol = #(d.lines[#d.lines] or "") + 1
  return ui.dialogEditor
end

-- Confirms (save=true writes through onSave) or cancels; either way closes,
-- restoring a parked Entity Creator form with the final text patched into
-- its field.
function DialogEditor.finish(ui, save)
  local d = ui.dialogEditor
  if not d then return end
  local text = DialogEditor.getText(d)
  if save and d.onSave then d.onSave(text) end
  ui.dialogEditor = nil
  local rc = d.returnCreator
  if rc then
    local EntityCreator =
      require("mods.mapamap.components.entity_creator")
    local restored = EntityCreator.restoreDraft(ui, d.session, rc.draft)
    if restored and rc.fieldKey then
      for _, f in ipairs(restored.fields) do
        if f.key == rc.fieldKey then f.value = text end
      end
    end
  end
end

-- ---------------------------------------------------------------------------
-- Keyboard / mouse

local function shiftDown()
  local kb = love.keyboard
  return kb and kb.isDown and (kb.isDown("lshift") or kb.isDown("rshift"))
end

function DialogEditor.key(ui, session, key)
  local d = ui.dialogEditor
  if not d then return false end
  if key == "escape" then
    DialogEditor.finish(ui, false)
    return true
  elseif key == "tab" then
    DialogEditor.finish(ui, true)
    return true
  elseif key == "return" or key == "kpenter" then
    -- Enter = second-line marker; Shift+Enter = page break (\f).
    if shiftDown() then
      DialogEditor.insertMarker(d, "\f")
    else
      DialogEditor.insertMarker(d, "\n")
    end
    return true
  elseif key == "backspace" then
    DialogEditor.backspace(d)
    return true
  elseif key == "delete" then
    DialogEditor.deleteChar(d)
    return true
  elseif key == "left" then
    DialogEditor.moveH(d, -1)
    return true
  elseif key == "right" then
    DialogEditor.moveH(d, 1)
    return true
  elseif key == "up" then
    DialogEditor.moveV(d, -1)
    return true
  elseif key == "down" then
    DialogEditor.moveV(d, 1)
    return true
  elseif key == "home" then
    DialogEditor.toLineStart(d)
    return true
  elseif key == "end" then
    DialogEditor.toLineEnd(d)
    return true
  elseif #key == 1 and key >= " " then
    local ch = key
    if isLetter(ch) and shiftDown() then ch = ch:upper() end
    DialogEditor.insertChar(d, ch)
    return true
  elseif key == "space" then
    DialogEditor.insertChar(d, " ")
    return true
  end
  return true
end

function DialogEditor.mousepressed(ui, session, mx, my, button)
  local d = ui.dialogEditor
  if not d then return false end
  local vw, vh = love.graphics.getDimensions()
  if not Panel.over(DialogEditor.rect, vw, vh, mx, my) then
    -- Outside clicks cancel, mirroring the other modals.
    DialogEditor.finish(ui, false)
    return true
  end
  if button ~= 1 then return true end
  local hit = hitBtn(vw, vh, mx, my)
  if hit == "done" then
    DialogEditor.finish(ui, true)
  elseif hit == "cancel" then
    DialogEditor.finish(ui, false)
  elseif hit == "caps" then
    DialogEditor.toggleCaps(d)
  elseif hit == "upper" then
    DialogEditor.upperAll(d)
  else
    -- Click in the edit rows: place the caret on the clicked line/column.
    local top, visible, first, rowH = editView(vw, vh, d)
    local x = select(1, DialogEditor.rect(vw, vh))
    if my >= top then
      local row = math.floor((my - top) / rowH)
      local li = first + row
      if li >= 1 and li <= #d.lines then
        d.curLine = li
        local col = math.floor((mx - x - PAD) / DialogEditor.CH_PX) + 1
        d.curCol = math.max(1, math.min(col, #d.lines[li] + 1))
      end
    end
  end
  return true
end

-- ---------------------------------------------------------------------------
-- Draw

local function drawButtons(vw, vh, d, font, mx, my)
  local rects = buttonRects(vw, vh)
  local defs = {
    { "done", "DONE", { 0.16, 0.35, 0.18, 0.95 }, { 0.3, 1, 0.4, 0.95 } },
    { "cancel", "CANCEL", { 0.3, 0.16, 0.16, 0.95 }, { 1, 0.4, 0.35, 0.95 } },
    { "caps", d.caps and "CAPS ON" or "CAPS OFF",
      d.caps and { 0.5, 0.42, 0.1, 0.95 } or { 0.2, 0.2, 0.24, 0.95 },
      d.caps and { 1, 0.9, 0.3, 0.95 } or { 0.55, 0.55, 0.6, 0.7 } },
    { "upper", "ALL-CAPS", { 0.2, 0.2, 0.24, 0.95 }, { 0.55, 0.55, 0.6, 0.7 } },
  }
  for _, def in ipairs(defs) do
    local name, label, bg, fg = def[1], def[2], def[3], def[4]
    local r = rects[name]
    local hovered = mx >= r[1] and mx < r[1] + r[3] and my >= r[2]
      and my < r[2] + r[4]
    love.graphics.setColor(bg[1], bg[2], bg[3], bg[4])
    love.graphics.rectangle("fill", r[1], r[2], r[3], r[4])
    love.graphics.setColor(fg[1], fg[2], fg[3],
      hovered and math.min(fg[4] + 0.05, 1) or fg[4])
    love.graphics.rectangle("line", r[1], r[2], r[3], r[4])
    Text.label(font, label, r[1] + 4, r[2] + 3, 2,
      { bg = Panel.CHIP_TITLE, padX = 2, padY = 1 })
  end
  Panel.resetColor()
end

function DialogEditor.draw(session, state, vw, vh, font)
  local d = state
  local x, y, w, h = DialogEditor.rect(vw, vh)
  Panel.drawBg(x, y, w, h, 0.94)
  Panel.drawTitle(font, d.title, x, y)

  local mx, my = love.mouse.getPosition()

  -- Status line: char count, caps state, marker legend.
  local chars = #DialogEditor.getText(d)
  local status = ("%d CH%s  ENTER NEW LINE  SHIFT+ENTER PAGE BREAK"):format(
    chars, d.caps and "  CAPS" or "")
  Text.label(font, Panel.fitText(font, status, w - PAD * 2, 1),
    x + PAD, y + PAD + Panel.TITLE_H + Panel.TITLE_GAP, 1,
    { bg = Panel.CHIP_ROW, padX = 2, padY = 1 })

  -- Editable rows (raw buffer; [PB] marks an inline page break).
  local top, visible, first, rowH = editView(vw, vh, d)
  for row = 0, visible - 1 do
    local li = first + row
    if li > #d.lines then break end
    local ry = top + row * rowH
    local raw = d.lines[li]
    local shown = (raw:gsub("\f", "[PB]"))
    if li == d.curLine then
      local head = shown:sub(1, d.curCol - 1)
      shown = head .. "_" .. shown:sub(#head + 1)
    end
    Text.label(font, Panel.fitText(font, shown, w - PAD * 2 - 30, 2),
      x + PAD + 26, ry, 2,
      { bg = li == d.curLine and Panel.CHIP_EDIT or Panel.CHIP_VALUE,
        padX = 2, padY = 1 })
    Text.label(font, tostring(li), x + PAD, ry + 3, 1,
      { bg = Panel.CHIP_ROW, padX = 2, padY = 0 })
  end

  -- In-game style preview: the REAL textbox look -- white paper, black
  -- frame tiles and glyphs -- drawn at native resolution and integer-scaled.
  local btnTop = select(2, buttonRects(vw, vh))
  local S = previewScale(w)
  local pvTop = top + visible * rowH + 6
  local px, pw = x + math.floor((w - 160 * S) / 2), 160 * S
  love.graphics.setColor(0, 0, 0, 0.55)
  love.graphics.rectangle("fill", px + 3, pvTop + 3, pw, 56 * S)

  local text = DialogEditor.getText(d)
  local pages = DialogEditor.previewPages(text)
  -- The page under the caret; each line costs itself plus one marker char.
  local caret = 0
  for i = 1, d.curLine - 1 do caret = caret + #d.lines[i] + 1 end
  caret = caret + d.curCol - 1
  local acc, pageIdx = 0, #pages
  for pi, page in ipairs(pages) do
    local cost = 0
    for _, l in ipairs(page) do cost = cost + #l + 1 end
    if caret < acc + cost then pageIdx = pi break end
    acc = acc + cost
  end

  love.graphics.push()
  love.graphics.translate(px, pvTop)
  love.graphics.scale(S, S)
  local drewNative = pcall(function()
    local Font = require("src.render.Font")
    Font.drawBox(0, 0, 20, 7, nil)
    love.graphics.setColor(0, 0, 0, 1)
    -- The game settles a page showing its LAST two lines at rows 16/32.
    local page = pages[pageIdx] or {}
    local n = math.min(#page, 3)
    local y0 = n >= 3 and 10 or (16 + (2 - n) * 16)
    for i = 1, n do
      local codes = Font.encode(page[#page - n + i])
      for k, code in ipairs(codes) do
        Font.drawCode(code, 8 + (k - 1) * 8, y0 + (i - 1) * 16)
      end
    end
  end)
  love.graphics.pop()
  if not drewNative then
    -- Headless / no-atlas fallback: paper rectangle + plain dark text.
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.rectangle("fill", px, pvTop, pw, 56 * S)
    love.graphics.setColor(0, 0, 0, 1)
    local page = pages[pageIdx] or {}
    for i = 1, math.min(#page, 3) do
      Text.label(font, page[i], px + 10, pvTop + 12 + (i - 1) * 18, 1, {})
    end
  end
  Text.label(font, ("PAGE %d/%d"):format(pageIdx, #pages),
    px + pw - 56, pvTop + 4, 1,
    { bg = { 1, 1, 1, 1 }, padX = 2, padY = 0 })

  drawButtons(vw, vh, d, font, mx, my)

  local hint = "Type  Enter:new line  Shift+Enter:page break  Bksp  Arrows  Tab/DONE:ok  Esc/CANCEL:cancel"
  Panel.drawHint(font, hint, x, y, w, h)
  Panel.resetColor()
end

return DialogEditor
