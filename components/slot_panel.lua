-- Map Slots panel: save-slot management for the whole mapamap edit-set.
--
-- One side-panel surface (same box as the tileset picker / entity selector)
-- that lists every stored map-slot (storage/slots.lua records), a button
-- strip -- SAVE / LOAD / NEW / RENAME / DEL / EXPORT -- and the export
-- folder listing (mods/mapamap/export/*.lua); clicking a file imports it as
-- a new slot.
--
-- SAVE captures the live edit-set under the selected name; LOAD swaps it in
-- through SessionManager.activateSlot (which stashes an auto "previous"
-- backup first and replays the activated buckets into the running world).
-- RENAME types inline: printable keys append, Backspace trims, Enter
-- commits, Escape cancels.
--
-- All panel state lives on the Input controller table (slotsOpen, slotSel,
-- slotRename, slotScroll, slotFileScroll, slotMsg); this module owns the
-- geometry, drawing and action routing only.

local Panel = require("mods.mapamap.components.panel")
local Text = require("mods.mapamap.components.text")
local Inventory = require("mods.mapamap.components.inventory")
local Slots = require("mods.mapamap.storage.slots")

local SlotPanel = {}

-- The action strip: three buttons per row, two rows.
SlotPanel.BUTTONS = {
  { id = "save",   label = "SAVE",   desc = "capture current edits into the selected slot" },
  { id = "load",   label = "LOAD",   desc = "swap the stored edit-set in (auto-backup to 'previous')" },
  { id = "new",    label = "NEW",    desc = "capture into a fresh YY.MM.DD.HH.MM.SS name" },
  { id = "rename", label = "RENAME", desc = "type a new name, ENTER commits, ESC cancels" },
  { id = "delete", label = "DEL",    desc = "remove the selected slot" },
  { id = "export", label = "EXPORT", desc = "write the slot to export/<name>.lua" },
}

SlotPanel.SLOT_ROW_H = 20
SlotPanel.FILE_ROW_H = 20
SlotPanel.BTN_COLS = 3
SlotPanel.BTN_H = 22
SlotPanel.BTN_GAP = 4
SlotPanel.SEC_H = 14
SlotPanel.SLOT_ROWS = 6      -- max visible slot rows (wheel scrolls more)

function SlotPanel.rect(vw, vh)
  return Inventory.sideRect(vw, vh)
end

function SlotPanel.over(vw, vh, mx, my)
  return Panel.over(SlotPanel.rect, vw, vh, mx, my)
end

-- Vertical band plan for the panel's sections, derived from one rect.
local function layout(vw, vh)
  local x, y, w, h = Inventory.sideRect(vw, vh)
  local top = Panel.titleBottom(y)
  local slotsY = top + SlotPanel.SEC_H + 2
  local btnY = slotsY + SlotPanel.SLOT_ROWS * SlotPanel.SLOT_ROW_H + 4
  local btnRows = math.ceil(#SlotPanel.BUTTONS / SlotPanel.BTN_COLS)
  local filesY = btnY + btnRows * (SlotPanel.BTN_H + SlotPanel.BTN_GAP)
                 + SlotPanel.SEC_H + 4
  local bottom = y + h - Panel.PAD - 16   -- keep the hint bar clear
  local fileRows = math.max(0, math.floor((bottom - filesY) / SlotPanel.FILE_ROW_H))
  return {
    x = x, y = y, w = w, h = h,
    slotsY = slotsY, btnY = btnY, filesY = filesY,
    fileRows = fileRows,
    btnRows = btnRows,
  }
end

local function clampScroll(scroll, count, visible)
  return math.max(1, math.min(scroll or 1, math.max(1, (count or 0) - visible + 1)))
end

local function innerW(w)
  return w - Panel.PAD * 2
end

local function btnRect(L, i)
  local col = (i - 1) % SlotPanel.BTN_COLS
  local row = math.floor((i - 1) / SlotPanel.BTN_COLS)
  local bw = (innerW(L.w) - SlotPanel.BTN_GAP * (SlotPanel.BTN_COLS - 1)) / SlotPanel.BTN_COLS
  return L.x + Panel.PAD + col * (bw + SlotPanel.BTN_GAP),
         L.btnY + row * (SlotPanel.BTN_H + SlotPanel.BTN_GAP),
         bw, SlotPanel.BTN_H
end

local function slotRowRect(L, i)
  return L.x + Panel.PAD - 2, L.slotsY + (i - 1) * SlotPanel.SLOT_ROW_H,
         innerW(L.w) + 4, SlotPanel.SLOT_ROW_H
end

local function fileRowRect(L, i)
  return L.x + Panel.PAD - 2, L.filesY + (i - 1) * SlotPanel.FILE_ROW_H,
         innerW(L.w) + 4, SlotPanel.FILE_ROW_H
end

-- The button id under a screen point, or nil.
function SlotPanel.buttonAt(vw, vh, mx, my)
  local L = layout(vw, vh)
  for i = 1, #SlotPanel.BUTTONS do
    local bx, by, bw, bh = btnRect(L, i)
    if mx >= bx and mx < bx + bw and my >= by and my < by + bh then
      return SlotPanel.BUTTONS[i].id
    end
  end
  return nil
end

-- The slot NAME under a screen point (respecting the wheel scroll), or nil.
function SlotPanel.slotAt(ui, session, vw, vh, mx, my)
  local L = layout(vw, vh)
  local names = session.mod and Slots.names(session.mod) or {}
  local scroll = clampScroll(ui.slotScroll, #names, SlotPanel.SLOT_ROWS)
  for i = 1, SlotPanel.SLOT_ROWS do
    local rx, ry, rw, rh = slotRowRect(L, i)
    if mx >= rx and mx < rx + rw and my >= ry and my < ry + rh then
      return names[scroll + i - 1]
    end
  end
  return nil
end

-- The export FILE under a screen point (respecting the wheel scroll), or nil.
function SlotPanel.fileAt(ui, session, vw, vh, mx, my)
  local L = layout(vw, vh)
  if L.fileRows <= 0 then return nil end
  local files = session.mod and Slots.files(session.mod) or {}
  local scroll = clampScroll(ui.slotFileScroll, #files, L.fileRows)
  for i = 1, L.fileRows do
    local rx, ry, rw, rh = fileRowRect(L, i)
    if mx >= rx and mx < rx + rw and my >= ry and my < ry + rh then
      return files[scroll + i - 1]
    end
  end
  return nil
end

local function msg(ui, text)
  ui.slotMsg = tostring(text)
end

-- Runs one action-strip command.  Kept next to the hit-test so the click
-- route and the keyboard route (Enter -> load) share one implementation.
function SlotPanel.press(ui, session, id)
  local mod = session.mod
  if not mod then msg(ui, "no mod context") return end
  if id == "save" or id == "new" then
    local name = ui.slotSel
    if id == "new" or not name then name = Slots.nextName(mod) end
    Slots.store(mod, name)
    ui.slotSel = name
    msg(ui, "saved current edits as '" .. name .. "'")
  elseif id == "load" then
    if not ui.slotSel then msg(ui, "select a slot to load") return end
    -- Resolved lazily so tests can stub the session manager before firing.
    local SM = require("mods.mapamap.controllers.session_manager")
    -- Captured BEFORE activating: activation may reopen the session, and a
    -- reopen resets the controller state (slotSel included), so the field
    -- is gone by the time activateSlot returns.
    local name = ui.slotSel
    local ok, err = SM.activateSlot(mod, name)
    msg(ui, ok and ("loaded '" .. tostring(name) .. "'") or tostring(err))
  elseif id == "rename" then
    if not ui.slotSel then msg(ui, "select a slot to rename") return end
    ui.slotRename = ui.slotSel
    msg(ui, "type the new name - ENTER saves, ESC cancels")
  elseif id == "delete" then
    if not ui.slotSel then msg(ui, "select a slot to delete") return end
    Slots.delete(mod, ui.slotSel)
    msg(ui, "deleted '" .. ui.slotSel .. "'")
    ui.slotSel = nil
  elseif id == "export" then
    if not ui.slotSel then msg(ui, "select a slot to export") return end
    local path, err = Slots.export(mod, ui.slotSel)
    msg(ui, path and ("exported " .. path) or tostring(err))
  end
end

local function commitRename(ui, session)
  local mod = session.mod
  local name = ui.slotRename and ui.slotRename:gsub("^%s+", ""):gsub("%s+$", "")
  ui.slotRename = nil
  if not (mod and ui.slotSel) then return end
  local ok, err = Slots.rename(mod, ui.slotSel, name)
  if ok then
    ui.slotSel = name
    msg(ui, "renamed to '" .. name .. "'")
  else
    msg(ui, tostring(err))
  end
end

local function importFile(ui, session, fileName)
  local mod = session.mod
  if not mod then return end
  local name, err = Slots.import(mod, fileName)
  if name then
    ui.slotSel = name
    ui.slotFileScroll = 1
    msg(ui, "imported '" .. fileName .. "' as slot '" .. name .. "'")
  else
    msg(ui, tostring(err))
  end
end

-- Uniform MOUSE_MODALS contract: consume everything inside the panel;
-- declining outside presses closes it (closeOnOutside in input.lua).
function SlotPanel.mousepressed(ui, session, mx, my, button)
  local vw, vh = love.graphics.getDimensions()
  if not SlotPanel.over(vw, vh, mx, my) then return false end
  if button ~= 1 then return true end
  -- Any click leaves rename typing (the typed buffer stays until Enter).
  if ui.slotRename then
    commitRename(ui, session)
    return true
  end
  local id = SlotPanel.buttonAt(vw, vh, mx, my)
  if id then
    SlotPanel.press(ui, session, id)
    return true
  end
  local name = SlotPanel.slotAt(ui, session, vw, vh, mx, my)
  if name then
    ui.slotSel = name
    ui.slotMsg = nil
    return true
  end
  local file = SlotPanel.fileAt(ui, session, vw, vh, mx, my)
  if file then
    importFile(ui, session, file)
    return true
  end
  return true
end

-- Uniform KEY_MODALS contract: while the panel is open every key is
-- consumed.  Rename typing gets the printable keys; otherwise Up/Down walk
-- the slot list, Enter loads, V/Esc/Y close the surface.
function SlotPanel.key(ui, session, key)
  if ui.slotRename then
    if key == "escape" then
      ui.slotRename = nil
      msg(ui, "rename cancelled")
    elseif key == "return" or key == "kpenter" then
      commitRename(ui, session)
    elseif key == "backspace" then
      ui.slotRename = ui.slotRename:sub(1, -2)
    elseif #key == 1 and key:match("^[%w%s%-_]") then
      ui.slotRename = ui.slotRename .. key
    end
    return true
  end
  if key == "escape" or key == "v" or key == "y" then
    ui.slotsOpen = false
    return true
  end
  local mod = session.mod
  if key == "up" or key == "down" then
    local names = mod and Slots.names(mod) or {}
    if #names > 0 then
      local cur = 1
      for i, n in ipairs(names) do if n == ui.slotSel then cur = i break end end
      cur = cur + (key == "down" and 1 or -1)
      if cur < 1 then cur = #names end
      if cur > #names then cur = 1 end
      ui.slotSel = names[cur]
      ui.slotMsg = nil
    end
    return true
  end
  if key == "return" or key == "kpenter" then
    SlotPanel.press(ui, session, "load")
    return true
  end
  return true
end

-- Wheel over the panel: scroll whichever section the pointer is over.
function SlotPanel.scroll(ui, session, dy)
  local vw, vh = love.graphics.getDimensions()
  local mx, my = love.mouse.getPosition()
  local L = layout(vw, vh)
  if my < L.btnY then
    local n = #(session.mod and Slots.names(session.mod) or {})
    ui.slotScroll = clampScroll((ui.slotScroll or 1) + dy, n, SlotPanel.SLOT_ROWS)
  else
    local n = #(session.mod and Slots.files(session.mod) or {})
    ui.slotFileScroll = clampScroll((ui.slotFileScroll or 1) + dy, n, L.fileRows)
  end
  return true
end

-- ---------------------------------------------------------------------------
-- Draw

local function drawSectionLabel(font, text, x, y)
  Text.label(font, text, x, y, 1, { bg = Panel.CHIP_ROW, padX = 2, padY = 1 })
end

local function drawButton(font, b, bx, by, bw, bh, hovered)
  love.graphics.setColor(Panel.COLOR_CELL_BG[1], Panel.COLOR_CELL_BG[2],
    Panel.COLOR_CELL_BG[3], Panel.COLOR_CELL_BG[4])
  love.graphics.rectangle("fill", bx, by, bw, bh)
  local lw = Panel.labelWidth(font, b.label)
  Text.label(font, b.label, bx + (bw - lw) / 2, by + (bh - 16) / 2, 2, {})
  if hovered then
    Panel.drawHover(bx, by, bw, bh)
  else
    love.graphics.setColor(0.5, 0.5, 0.55, 0.4)
    love.graphics.rectangle("line", bx, by, bw, bh)
  end
end

local function timeLabel(rec)
  if not (rec and rec.savedAt) then return "" end
  local ok, s = pcall(os.date, "%m/%d %H:%M", rec.savedAt)
  return ok and s or ""
end

function SlotPanel.draw(ui, session, vw, vh, font)
  local L = layout(vw, vh)
  Panel.drawBg(L.x, L.y, L.w, L.h)
  Panel.drawTitle(font, "MAP SLOTS", L.x, L.y)

  local mx, my = love.mouse.getPosition()
  local mod = session.mod
  local names = mod and Slots.names(mod) or {}

  -- Slots section -----------------------------------------------------------
  drawSectionLabel(font, "SLOTS", L.x + Panel.PAD, Panel.titleBottom(L.y))
  local scroll = clampScroll(ui.slotScroll, #names, SlotPanel.SLOT_ROWS)
  ui.slotScroll = scroll
  local hoverSlot = SlotPanel.slotAt(ui, session, vw, vh, mx, my)
  for i = 1, SlotPanel.SLOT_ROWS do
    local name = names[scroll + i - 1]
    if not name then break end
    local rx, ry, rw, rh = slotRowRect(L, i)
    local selected = name == ui.slotSel
    -- The rename buffer replaces the row's label while typing.
    local label = (selected and ui.slotRename) and (ui.slotRename .. "_") or name
    if selected then
      Panel.drawSel(rx, ry, rw, rh)
    elseif hoverSlot == name then
      Panel.drawHover(rx, ry, rw, rh)
    end
    local tw = Panel.labelWidth(font, label)
    while tw > rw - 70 and #label > 1 do
      label = label:sub(1, -2)
      tw = Panel.labelWidth(font, label)
    end
    Text.label(font, label, rx + 4, ry + 3, 2, { bg = Panel.CHIP_VALUE })
    local stamp = timeLabel(Slots.get(mod, name))
    if stamp ~= "" and not ui.slotRename then
      local sw = Panel.labelWidth(font, stamp)
      Text.label(font, stamp, rx + rw - sw - 6, ry + 5, 1,
        { bg = Panel.CHIP_HINT, padX = 2, padY = 0 })
    end
  end

  -- Action strip ------------------------------------------------------------
  for i, b in ipairs(SlotPanel.BUTTONS) do
    local bx, by, bw, bh = btnRect(L, i)
    local hovered = mx >= bx and mx < bx + bw and my >= by and my < by + bh
    drawButton(font, b, bx, by, bw, bh, hovered)
  end

  -- Export-files section ----------------------------------------------------
  local filesY = L.filesY
  drawSectionLabel(font, "EXPORT FILES", L.x + Panel.PAD, filesY)
  filesY = filesY + SlotPanel.SEC_H
  local files = mod and Slots.files(mod) or {}
  local fscroll = clampScroll(ui.slotFileScroll, #files, L.fileRows)
  ui.slotFileScroll = fscroll
  if #files == 0 then
    Text.label(font, "(no exports yet)", L.x + Panel.PAD + 4, filesY + 3, 1,
      { bg = Panel.CHIP_HINT, padX = 2, padY = 1 })
  end
  for i = 1, math.min(L.fileRows, #files - fscroll + 1) do
    local fileName = files[fscroll + i - 1]
    if not fileName then break end
    local rx, ry, rw, rh = fileRowRect(L, i)
    -- Highlight the row matching the selected slot's own export.
    local mine = ui.slotSel and fileName == ui.slotSel .. ".lua"
    if mine then
      Panel.drawSel(rx, ry, rw, rh)
    elseif mx >= rx and mx < rx + rw and my >= ry and my < ry + rh then
      Panel.drawHover(rx, ry, rw, rh)
    end
    local label = fileName
    local tw = Panel.labelWidth(font, label)
    while tw > rw - 12 and #label > 1 do
      label = label:sub(1, -2)
      tw = Panel.labelWidth(font, label)
    end
    Text.label(font, label, rx + 4, ry + 3, 2, { bg = Panel.CHIP_VALUE })
  end

  -- Hint bar ----------------------------------------------------------------
  local hint = ui.slotMsg
  if not hint then
    for i, b in ipairs(SlotPanel.BUTTONS) do
      local bx, by, bw, bh = btnRect(L, i)
      if mx >= bx and mx < bx + bw and my >= by and my < by + bh then
        hint = b.desc
        break
      end
    end
  end
  Panel.drawHint(font, hint
    or "SAVE captures edits - LOAD swaps a slot in - click an export file to import",
    L.x, L.y, L.w, L.h)
  Panel.resetColor()
end

return SlotPanel
