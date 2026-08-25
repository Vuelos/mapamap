-- Encounter editor panel: a modal editor for wild Pokemon encounter data
-- (grass/water/indoor rates and species/level slots).
--
-- Press N while the overlay is open to toggle it.  Tabs switch between
-- Grass / Water / Indoor groups (mouse click only).  Up/Down navigate rows,
-- Enter opens the species dropdown or commits level input, A adds a slot,
-- X removes the active slot, Escape or N closes.

local Inventory = require("mods.mapamap.components.inventory")
local Panel = require("mods.mapamap.components.panel")
local Text = require("mods.mapamap.components.text")

local EncEditor = {}

EncEditor.DROP_H = 20

local PAD = Panel.PAD
local ROW_H = Panel.ROW_H

local GROUPS = {"grass", "water", "indoor"}

local GROUP_CAP = {
  grass = "Grass", water = "Water", indoor = "Indoor",
  grass_morn = "Grass M", grass_day = "Grass D", grass_nite = "Grass N",
}

-- Column geometry constants.
local LV_W = 96
local LV_PAD = 4

-- Tab definitions for Panel.drawTabs / Panel.tabAt.
local function tabDefs(groups)
  local t = {}
  for _, gk in ipairs(groups) do
    t[#t + 1] = { label = GROUP_CAP[gk] or gk }
  end
  return t
end

function EncEditor.rect(vw, vh)
  return Inventory.sideRect(vw, vh)
end

function EncEditor.over(vw, vh, mx, my)
  return Panel.over(EncEditor.rect, vw, vh, mx, my)
end

function EncEditor.tabAt(vw, vh, mx, my, font, groups)
  local x, y = EncEditor.rect(vw, vh)
  return Panel.tabAt(tabDefs(groups), x, Panel.titleBottom(y), font, mx, my)
end

-- Row top Y (below tabs) for hit-testing and drawing.
local function rowTopY(vh)
  local _, py, _, ph = EncEditor.rect(vh > 0 and vh or 1, vh)
  return py + PAD + Panel.TITLE_H + Panel.TITLE_GAP + Panel.TAB_H + Panel.TAB_GAP + 6
end

function EncEditor.hit(vw, vh, mx, my)
  local n = Panel.hitRow(vw, vh, mx, my, EncEditor.rect, rowTopY(vh), ROW_H + 6)
  if n and n > 200 then return nil end
  return n
end

-- Column area rects for a given row index.
local function slotRowRect(vw, vh, slotRow)
  local x, y, w, h = EncEditor.rect(vw, vh)
  local ry = rowTopY(vh) + (slotRow - 1) * (ROW_H + 6)
  return x, ry, w, h
end

local function speciesAreaRect(vw, vh, slotRow)
  local x, ry, w = slotRowRect(vw, vh, slotRow)
  return x + 50, ry, w - 50 - LV_W - LV_PAD, ROW_H
end

local function rateAreaRect(vw, vh, rateRow)
  local x, ry, w = slotRowRect(vw, vh, rateRow)
  return x + w / 2, ry, w / 2 - PAD, ROW_H
end

local function levelAreaRect(vw, vh, slotRow)
  local x, ry, w = slotRowRect(vw, vh, slotRow)
  return x + w - LV_W, ry, LV_W, ROW_H
end

function EncEditor.rateHit(vw, vh, mx, my, rateRow)
  local rx, ry, rw, rh = rateAreaRect(vw, vh, rateRow)
  return mx >= rx and mx < rx + rw and my >= ry and my < ry + rh
end

function EncEditor.speciesHit(vw, vh, mx, my, slotRow)
  local sx, sy, sw, sh = speciesAreaRect(vw, vh, slotRow)
  return mx >= sx and mx < sx + sw and my >= sy and my < sy + sh
end

function EncEditor.levelHit(vw, vh, mx, my, slotRow)
  local lx, ly, lw, lh = levelAreaRect(vw, vh, slotRow)
  return mx >= lx and mx < lx + lw and my >= ly and my < ly + lh
end

function EncEditor.dropRect(vw, vh, slotRow, scrollOffset)
  local x, y, w, h = EncEditor.rect(vw, vh)
  local ry = rowTopY(vh) + (slotRow - 1) * (ROW_H + 6)
  local dropTop = ry + ROW_H + 6
  local dropBot = y + h - PAD - 10
  local maxDropH = dropBot - dropTop
  if maxDropH < EncEditor.DROP_H then return nil end
  local dx = x + PAD
  local dw = w - PAD * 2 - LV_W - LV_PAD
  return dx, dropTop, dw, maxDropH, scrollOffset or 0
end

-- The "+ Add row" button rect: a full-width bar pinned above the hint footer.
-- Clicking it appends a slot to the active group (creating the table first
-- when the group has no data yet).
function EncEditor.addBtnRect(vw, vh)
  local x, y, w, h = EncEditor.rect(vw, vh)
  return x + PAD, y + h - PAD - 14 - ROW_H, w - PAD * 2, ROW_H
end

-- True when (mx,my) is inside the "+ Add row" button.
function EncEditor.addBtnHit(vw, vh, mx, my)
  local bx, by, bw, bh = EncEditor.addBtnRect(vw, vh)
  return mx >= bx and mx < bx + bw and my >= by and my < by + bh
end

function EncEditor.dropEntryAt(vw, vh, mx, my, slotRow, scrollOffset)
  local dx, dy, dw, dh = EncEditor.dropRect(vw, vh, slotRow, scrollOffset)
  if not dx then return nil end
  if mx < dx or mx >= dx + dw or my < dy or my >= dy + dh then return nil end
  local row = math.floor((my - dy) / EncEditor.DROP_H) + 1
  local maxVisible = math.floor(dh / EncEditor.DROP_H)
  if row < 1 or row > maxVisible then return nil end
  return (scrollOffset or 0) + row
end

function EncEditor.scrollSpecies(ui, dy)
  local d = ui.encEditor
  if not d or not d.dropdown then return end
  local species = d.session:speciesList()
  if #species == 0 then return end
  local vw, vh = love.graphics.getDimensions()
  local dx, dy2, dw, dh = EncEditor.dropRect(vw, vh, d.index, d.dropdown.scroll)
  if not dx then return end
  local maxVisible = math.floor(dh / EncEditor.DROP_H)
  local maxScroll = math.max(0, #species - maxVisible)
  d.dropdown.scroll = math.max(0, math.min(d.dropdown.scroll + dy, maxScroll))
end

function EncEditor.build(session, tabGroup)
  local fields = {}
  local gk = tabGroup or "grass"
  local group = session:ensureEncounterGroup(gk)
  if group then
    fields[#fields + 1] = {
      kind = "rate", group = gk,
      label = ("%s rate"):format(GROUP_CAP[gk] or gk),
      value = tostring(group.rate or 0),
    }
    for i, slot in ipairs(group.slots or {}) do
      fields[#fields + 1] = {
        kind = "slot", group = gk, slot = i,
        label = ("%d: %s Lv%d"):format(i, slot.species or "?",
          slot.level or 1),
        species = slot.species, level = slot.level,
      }
    end
  end
  return fields
end

function EncEditor.title(state)
  local session = state and state.session
  local mapId = session and session.mapId or "?"
  return "ENCOUNTERS " .. mapId
end

function EncEditor.open(ui, session)
  session:ensureEncounters()
  ui.showInventory = true
  -- The session's group list is generation-aware (domain/encounters.lua):
  -- Gen 1 grass/water/indoor, Gen 2 grass_morn/grass_day/grass_nite/water.
  local groups = (session.groups and session:groups())
    or { "grass", "water", "indoor" }
  ui.encEditor = {
    session = session,
    groups = groups,
    tab = 1,
    fields = EncEditor.build(session, groups[1]),
    index = 1,
    dropdown = nil,
    levelEdit = nil,
    rateEdit = nil,
  }
end

function EncEditor.close(ui)
  ui.encEditor = nil
end

local function rebuild(ui)
  local d = ui.encEditor
  if not d then return end
  local groups = d.groups
  local gk = groups[d.tab or 1]
  local idx = math.min(d.index, #d.fields)
  d.fields = EncEditor.build(d.session, gk)
  d.index = math.max(1, math.min(idx, #d.fields))
  if d.rateEdit and (not d.fields[d.rateEdit.fieldIdx]
      or d.fields[d.rateEdit.fieldIdx].kind ~= "rate") then
    d.rateEdit = nil
  end
  if d.levelEdit and (not d.fields[d.levelEdit.fieldIdx]
      or d.fields[d.levelEdit.fieldIdx].kind ~= "slot") then
    d.levelEdit = nil
  end
end

-- Handle mouse clicks.  Returns true when consumed.
function EncEditor.mousepressed(ui, session, mx, my, button)
  local d = ui.encEditor
  if not d then return false end
  local vw, vh = love.graphics.getDimensions()
  if not Panel.over(EncEditor.rect, vw, vh, mx, my) then return false end
  if button ~= 1 then return false end

  -- Species dropdown is open: check for clicks on dropdown items.
  if d.dropdown then
    local species = d.session:speciesList()
    local dropIdx = EncEditor.dropEntryAt(vw, vh, mx, my, d.index,
      d.dropdown.scroll)
    if dropIdx and dropIdx <= #species then
      local f = d.fields and d.fields[d.index]
      if f and f.kind == "slot" then
        session:setEncounterSlotSpecies(f.group, f.slot, species[dropIdx])
      end
      d.dropdown = nil
      rebuild(ui)
      return true
    end
    d.dropdown = nil
  end

  -- Tab click.
  local font = session and session.font
  local tabIdx = EncEditor.tabAt(vw, vh, mx, my, font, d.groups)
  if tabIdx then
    if d.tab ~= tabIdx then
      d.tab = tabIdx
      d.index = 1
      d.levelEdit = nil
      d.rateEdit = nil
      d.dropdown = nil
      rebuild(ui)
    end
    return true
  end

  -- "+ Add row" button: append a slot to the active group (the domain call
  -- creates the table first when the group has no data yet).
  if EncEditor.addBtnHit(vw, vh, mx, my) then
    local gk = (d.groups and d.groups[d.tab or 1]) or "grass"
    session:addEncounterSlot(gk)
    rebuild(ui)
    return true
  end

  -- Row selection.
  local idx = EncEditor.hit(vw, vh, mx, my)
  if idx and d.fields and idx <= #d.fields then
    d.index = idx
    local f = d.fields[idx]
    if f.kind == "rate" then
      if EncEditor.rateHit(vw, vh, mx, my, idx) then
        d.rateEdit = { fieldIdx = idx, buf = "" }
        return true
      end
    elseif f.kind == "slot" then
      if EncEditor.speciesHit(vw, vh, mx, my, idx) then
        d.dropdown = { scroll = 0, filter = "" }
        return true
      end
      if EncEditor.levelHit(vw, vh, mx, my, idx) then
        d.levelEdit = { fieldIdx = idx, buf = "" }
        return true
      end
    end
  end
  return true
end

-- ---------------------------------------------------------------------------
-- Keyboard

function EncEditor.key(ui, session, key)
  local d = ui.encEditor
  if not d then return false end

  -- Species dropdown open.
  if d.dropdown then
    local species = d.session:speciesList()
    if key == "up" then
      d.dropdown.scroll = math.max(0, d.dropdown.scroll - 1)
      return true
    elseif key == "down" then
      local vw, vh = love.graphics.getDimensions()
      local dx, dy, dw, dh = EncEditor.dropRect(vw, vh, d.index,
        d.dropdown.scroll)
      local maxVisible = dh and math.floor(dh / EncEditor.DROP_H) or 8
      local maxScroll = math.max(0, #species - maxVisible)
      d.dropdown.scroll = math.min(d.dropdown.scroll + 1, maxScroll)
      return true
    elseif key == "return" or key == "kpenter" then
      local pick = d.dropdown.scroll + 1
      if pick >= 1 and pick <= #species then
        local f = d.fields and d.fields[d.index]
        if f and f.kind == "slot" then
          session:setEncounterSlotSpecies(f.group, f.slot, species[pick])
        end
      end
      d.dropdown = nil
      rebuild(ui)
      return true
    elseif key == "escape" then
      d.dropdown = nil
      return true
    elseif #key == 1 then
      d.dropdown.filter = (d.dropdown.filter or "") .. key:upper()
      local matches = {}
      for _, s in ipairs(species) do
        if s:find(d.dropdown.filter, 1, true) then
          matches[#matches + 1] = s
        end
      end
      if #matches == 1 then
        local f = d.fields and d.fields[d.index]
        if f and f.kind == "slot" then
          session:setEncounterSlotSpecies(f.group, f.slot, matches[1])
        end
        d.dropdown = nil
        rebuild(ui)
      end
      return true
    end
    return true
  end

  -- Rate edit mode.
  if d.rateEdit then
    if key >= "0" and key <= "9" then
      local pending = d.rateEdit.buf .. key
      if #pending <= 3 and tonumber(pending) then
        d.rateEdit.buf = pending
        local v = math.max(0, math.min(tonumber(pending) or 0, 100))
        local f = d.fields and d.fields[d.rateEdit.fieldIdx]
        if f and f.kind == "rate" then
          session:setEncounterRate(f.group, v)
        end
        rebuild(ui)
      end
      return true
    elseif key == "return" or key == "kpenter" then
      local f = d.fields and d.fields[d.rateEdit.fieldIdx]
      if f and f.kind == "rate" then
        local v = math.max(0, math.min(tonumber(d.rateEdit.buf) or 0, 100))
        session:setEncounterRate(f.group, v)
      end
      d.rateEdit = nil
      rebuild(ui)
      return true
    elseif key == "escape" then
      d.rateEdit = nil
      rebuild(ui)
      return true
    elseif key == "backspace" then
      d.rateEdit.buf = d.rateEdit.buf:sub(1, #d.rateEdit.buf - 1)
      if d.rateEdit.buf == "" then
        local f = d.fields and d.fields[d.rateEdit.fieldIdx]
        if f and f.kind == "rate" then
          session:setEncounterRate(f.group, 0)
        end
      else
        local v = math.max(0, math.min(tonumber(d.rateEdit.buf) or 0, 100))
        local f = d.fields and d.fields[d.rateEdit.fieldIdx]
        if f and f.kind == "rate" then
          session:setEncounterRate(f.group, v)
        end
      end
      rebuild(ui)
      return true
    end
    return true
  end

  -- Level edit mode.
  if d.levelEdit then
    if key >= "0" and key <= "9" then
      local pending = d.levelEdit.buf .. key
      if #pending <= 3 and tonumber(pending) then
        d.levelEdit.buf = pending
        local v = math.max(1, math.min(tonumber(pending) or 1, 100))
        local f = d.fields and d.fields[d.levelEdit.fieldIdx]
        if f and f.kind == "slot" then
          session:setEncounterSlotLevel(f.group, f.slot, v)
        end
        rebuild(ui)
      end
      return true
    elseif key == "return" or key == "kpenter" then
      local f = d.fields and d.fields[d.levelEdit.fieldIdx]
      if f and f.kind == "slot" then
        local v = math.max(1, math.min(tonumber(d.levelEdit.buf) or 1, 100))
        session:setEncounterSlotLevel(f.group, f.slot, v)
      end
      d.levelEdit = nil
      rebuild(ui)
      return true
    elseif key == "escape" then
      d.levelEdit = nil
      rebuild(ui)
      return true
    elseif key == "backspace" then
      d.levelEdit.buf = d.levelEdit.buf:sub(1, #d.levelEdit.buf - 1)
      if d.levelEdit.buf == "" then
        local f = d.fields and d.fields[d.levelEdit.fieldIdx]
        if f and f.kind == "slot" then
          session:setEncounterSlotLevel(f.group, f.slot, 1)
        end
      else
        local v = math.max(1, math.min(tonumber(d.levelEdit.buf) or 1, 100))
        local f = d.fields and d.fields[d.levelEdit.fieldIdx]
        if f and f.kind == "slot" then
          session:setEncounterSlotLevel(f.group, f.slot, v)
        end
      end
      rebuild(ui)
      return true
    end
    return true
  end

  -- Normal navigation.
  if key == "up" then
    d.index = math.max(1, d.index - 1)
    return true
  elseif key == "down" then
    d.index = math.min(#(d.fields or {}), d.index + 1)
    return true
  elseif key == "left" or key == "right" then
    local f = d.fields and d.fields[d.index]
    if not f then return true end
    if f.kind == "rate" then
      d.rateEdit = { fieldIdx = d.index, buf = "" }
    elseif f.kind == "slot" then
      d.levelEdit = { fieldIdx = d.index, buf = "" }
    end
    return true
  elseif key == "return" or key == "kpenter" then
    local f = d.fields and d.fields[d.index]
    if f and f.kind == "rate" then
      d.rateEdit = { fieldIdx = d.index, buf = "" }
    elseif f and f.kind == "slot" then
      d.dropdown = { scroll = 0, filter = "" }
    end
    return true
  elseif key == "a" then
    local f = d.fields and d.fields[d.index]
    local gk = f and f.group or d.groups[d.tab or 1]
    session:addEncounterSlot(gk)
    rebuild(ui)
    return true
  elseif key == "x" or key == "delete" then
    local f = d.fields and d.fields[d.index]
    if f and f.kind == "slot" then
      session:removeEncounterSlot(f.group, f.slot)
      rebuild(ui)
    end
    return true
  elseif key == "escape" then
    ui.encEditor = nil
    return true
  elseif key == "n" then
    ui.encEditor = nil
    return true
  end
  return true
end

-- ---------------------------------------------------------------------------
-- Draw

function EncEditor.draw(session, state, vw, vh, font)
  local x, y, w, h = EncEditor.rect(vw, vh)
  Panel.drawBg(x, y, w, h)
  Panel.drawTitle(font, EncEditor.title(state), x, y)

  local mx, my = love.mouse.getPosition()
  Panel.drawTabs(tabDefs(state.groups), x, Panel.titleBottom(y), font, state.tab, mx, my)
  Panel.resetColor()

  local ry0 = rowTopY(vh)
  for i, f in ipairs(state.fields or {}) do
    local ry = ry0 + (i - 1) * (ROW_H + 6)

    if f.kind == "rate" then
      local label = f.label .. ":"
      Text.label(font, Panel.fitText(font, label, w / 2 - 6, 2),
        x + PAD, ry, 2, { bg = Panel.CHIP_ROW, padX = 2, padY = 1 })
      local rx, ry2, rw, rh = rateAreaRect(vw, vh, i)
      local value = f.value
      if state.rateEdit and state.rateEdit.fieldIdx == i then
        value = state.rateEdit.buf .. "_"
        Text.label(font, value, rx + 4, ry2, 2,
          { bg = Panel.CHIP_EDIT, padX = 2, padY = 1 })
        Panel.drawSel(rx + 2, ry2 - 2, rw - 4, ROW_H + 2)
        Panel.resetColor()
      else
        Text.label(font, value, rx + 4, ry2, 2,
          { bg = Panel.CHIP_VALUE, padX = 2, padY = 1 })
      end
    else
      local slotLabel = ("%d:"):format(f.slot or 0)
      Text.label(font, slotLabel, x + PAD, ry, 2,
        { bg = Panel.CHIP_ROW, padX = 2, padY = 1 })

      local sx, sy, sw, sh = speciesAreaRect(vw, vh, i)
      local isDropOpen = state.dropdown and state.index == i
      local btnLabel = isDropOpen and ((state.dropdown.filter or "") .. "_")
        or (f.species or "?")
      Panel.renderDropdownButton(font, btnLabel, sx, sy, sw, ROW_H,
        mx, my, isDropOpen)

      local lx, ly, lw, lh = levelAreaRect(vw, vh, i)
      if state.levelEdit and state.levelEdit.fieldIdx == i then
        local lvText = "Lv" .. state.levelEdit.buf .. "_"
        Text.label(font, lvText, lx + 2, ly, 2,
          { bg = Panel.CHIP_EDIT, padX = 2, padY = 1 })
        Panel.drawSel(lx, ly - 2, lw, ROW_H + 2)
        Panel.resetColor()
      else
        local lvText = ("Lv%d"):format(f.level or 1)
        Text.label(font, lvText, lx + 2, ly, 2,
          { bg = Panel.CHIP_VALUE, padX = 2, padY = 1 })
      end
    end

    if state.index == i then
      local showHighlight = true
      if state.dropdown then
        local dx, dy, dw, dh = EncEditor.dropRect(vw, vh, i,
          state.dropdown.scroll)
        if dx then showHighlight = false end
      end
      if showHighlight then
        Panel.drawSel(x + 2, ry - 3, w - 4, ROW_H)
      end
    end
  end

  -- "+ Add row" button (click appends a slot to the active group).
  do
    local bx, by, bw, bh = EncEditor.addBtnRect(vw, vh)
    local hovered = mx >= bx and mx < bx + bw and my >= by and my < by + bh
    love.graphics.setColor(0.16, 0.16, 0.22, 0.95)
    love.graphics.rectangle("fill", bx, by, bw, bh)
    if hovered then
      love.graphics.setColor(1, 1, 1, 0.95)
    else
      love.graphics.setColor(0.5, 0.5, 0.55, 0.5)
    end
    love.graphics.rectangle("line", bx, by, bw, bh)
    Text.label(font, "ADD ROW", bx + 4, by + 3, 2,
      { bg = Panel.CHIP_TITLE, padX = 2, padY = 1 })
    Panel.resetColor()
  end

  -- Full-height species dropdown.
  if state.dropdown then
    local di = state.index
    local dx, dy, dw, dh = EncEditor.dropRect(vw, vh, di,
      state.dropdown.scroll)
    if dx and dw and dh then
      local species = state.session:speciesList()
      local maxVisible = math.floor(dh / EncEditor.DROP_H)
      local hoverEntry = EncEditor.dropEntryAt(vw, vh, mx, my, di,
        state.dropdown.scroll)
      local f = state.fields and state.fields[di]
      local selSpecies = f and f.species
      local entries = {}
      for k, s in ipairs(species) do
        entries[k] = { label = s }
      end
      local selIdx = nil
      if selSpecies then
        for k, s in ipairs(species) do
          if s == selSpecies then selIdx = k; break end
        end
      end
      Panel.renderDropdownList(font, dx, dy, dw, dh,
        entries, (state.dropdown.scroll or 0) + 1, maxVisible,
        selIdx, hoverEntry, EncEditor.DROP_H)
    end
  end

  local hint
  if state.dropdown then
    hint = "Up/Down: scroll  Enter: select  Esc: close  type: filter"
  elseif state.rateEdit then
    hint = "Type digits (0-100)  Enter: ok  Esc: cancel"
  elseif state.levelEdit then
    hint = "Type digits (1-100)  Enter: ok  Esc: cancel"
  else
    hint = "Left/Right: group  Up/Down: row  Enter: edit  X: del  + Add row: new slot  N/Esc: close"
  end
  Panel.drawHint(font, hint, x, y, w, h)
  Panel.resetColor()
end

return EncEditor
