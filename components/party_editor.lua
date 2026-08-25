-- Party Editor panel: edits the enemy team behind a battler -- either the
-- SHARED class#party roster in data.trainers or a placement's own
-- obj.customParty team.
--
-- Opened from Details (the TEAM action row) or straight from the Entity
-- Creator's TEAM row.  Tabs switch Shared/Custom when a placed object is
-- bound (switching copies the shared roster onto the object; switching back
-- clears it).
--
-- Fully mouse-editable: clicking a slot row EXPANDS it into a sub panel --
-- held item, gender and shininess pins (gen 2 battles consume them; hidden
-- elsewhere), and four explicit move overrides -- each with its own
-- dropdown/cycler.  The level cell carries -/+ steppers, so nothing requires
-- the keyboard.  Keyboard equivalents stay: Up/Down slots, Enter species,
-- Left/Right level, A add, X remove, M auto-moveset, Esc close.

local Common = require("mods.mapamap.common")
local Gen = require("mods.mapamap.engine.gen")
local Inventory = require("mods.mapamap.components.inventory")
local Panel = require("mods.mapamap.components.panel")
local Text = require("mods.mapamap.components.text")
local Dropdown = require("mods.mapamap.components.dropdown")

local PartyEditor = {}

PartyEditor.DROP_H = Dropdown.H

local PAD = Panel.PAD
local ROW_H = Panel.ROW_H
local SUB_H = ROW_H + 2
local LV_W = 56            -- level cell: click to type 0-100
local MV_W = 56            -- moves chip on the head row

-- ---------------------------------------------------------------------------
-- Geometry

function PartyEditor.rect(vw, vh)
  return Inventory.sideRect(vw, vh)
end

function PartyEditor.over(vw, vh, mx, my)
  return Panel.over(PartyEditor.rect, vw, vh, mx, my)
end

local function hasCustom(d)
  return d and d.obj ~= nil
end

local function tabDefs(d)
  if hasCustom(d) then
    return { { label = "Shared" }, { label = "Custom" } }
  end
  return { { label = "Shared" } }
end

function PartyEditor.tabAt(vw, vh, mx, my, font, d)
  local x, y = PartyEditor.rect(vw, vh)
  return Panel.tabAt(tabDefs(d), x, Panel.titleBottom(y), font, mx, my)
end

local function gen2()
  return Gen.isGen2 and Gen.isGen2() or false
end

-- Sub rows of an expanded slot, in order.  Gen-1 hides held item / gender /
-- shininess because its battles do not consume them.
local function subRowsFor()
  local rows = {}
  if gen2() then
    rows[#rows + 1] = "item"
    rows[#rows + 1] = "gender"
    rows[#rows + 1] = "shiny"
  end
  rows[#rows + 1] = "mv1"
  rows[#rows + 1] = "mv2"
  rows[#rows + 1] = "mv3"
  rows[#rows + 1] = "mv4"
  return rows
end

-- Flat layout of every row: { kind="head"|"sub", slot=i, name?, y, h }.
function PartyEditor.layout(vw, vh, d)
  local x, y, w = PartyEditor.rect(vw, vh)
  local top = y + PAD + Panel.TITLE_H + Panel.TITLE_GAP + 16
  local rows = {}
  local cy = top
  for i in ipairs(d.fields or {}) do
    rows[#rows + 1] = { kind = "head", slot = i, y = cy, h = ROW_H + 6 }
    cy = cy + ROW_H + 6
    if d.expand == i then
      for _, name in ipairs(subRowsFor()) do
        rows[#rows + 1] = { kind = "sub", slot = i, name = name,
          y = cy, h = SUB_H }
        cy = cy + SUB_H
      end
    end
  end
  return rows, x, y, w
end

local function headAreas(x, w, r)
  return {
    species = { x + 34, r.y, w - 34 - LV_W - MV_W - 8, ROW_H },
    level   = { x + w - LV_W - MV_W - 6, r.y, LV_W, ROW_H },
    moves   = { x + w - MV_W, r.y, MV_W, ROW_H },
  }
end

local function hitRect(r, mx, my)
  return mx >= r[1] and mx < r[1] + r[3] and my >= r[2] and my < r[2] + r[4]
end

-- The flat-layout row under (mx,my), or nil.
local function rowAt(rows, mx, my)
  for _, r in ipairs(rows) do
    if my >= r.y and my < r.y + r.h then return r end
  end
  return nil
end

-- Bottom action buttons: [+ ADD] [AUTO MOVES] [CLEAR MOVES].
local function bottomButtons(vw, vh)
  local x, y, w, h = PartyEditor.rect(vw, vh)
  local by = y + h - PAD - ROW_H
  local bw = math.floor((w - PAD * 2 - 16) / 3)
  return {
    add = { x + PAD, by, bw, ROW_H },
    auto = { x + PAD + bw + 8, by, bw, ROW_H },
    clearm = { x + PAD + (bw + 8) * 2, by, bw, ROW_H },
  }, by
end

-- Placeholder resolved below (bottomButtons needs the panel height).
function PartyEditor.addBtnRect(vw, vh)
  local b = bottomButtons(vw, vh)
  return b.add[1], b.add[2], b.add[3], b.add[4]
end

-- Dropdown anchored under an absolute Y.  Returns x, y, w, maxH (or nil
-- when the band under the anchor is too small to show even one entry).
function PartyEditor.dropRect(vw, vh, anchorY, scrollOffset)
  local x, _, w = PartyEditor.rect(vw, vh)
  local dropTop = anchorY + ROW_H + 6
  local _, btnTop = bottomButtons(vw, vh)
  local maxDropH = btnTop - 4 - dropTop
  if maxDropH < PartyEditor.DROP_H then return nil end
  return x + PAD + 20, dropTop, w - PAD * 2 - 40, maxDropH
end

function PartyEditor.dropEntryAt(vw, vh, mx, my, anchorY, scrollOffset)
  local dx, dy, dw, dh = PartyEditor.dropRect(vw, vh, anchorY)
  if not dx then return nil end
  -- Unbounded count: callers nil-check list[pick] themselves.
  return Dropdown.entryAt(mx, my, dx, dy, dw, dh, scrollOffset or 0,
    math.huge)
end

-- ---------------------------------------------------------------------------
-- Lists

local listFor = nil  -- resolved lazily below (entity creator owns catalogs)

function PartyEditor.speciesIds(session)
  local Picker = require("mods.mapamap.components.picker")
  local out = {}
  for _, e in ipairs(Picker.speciesList(session)) do out[#out + 1] = e.id end
  return out
end

-- ---------------------------------------------------------------------------
-- Row building / open-close

local function buildFields(party)
  local fields = {}
  for i, slot in ipairs(party or {}) do
    fields[#fields + 1] = {
      kind = "slot", slot = i,
      species = slot.species, level = slot.level,
      moves = slot.moves,
      moveCount = slot.moves and #slot.moves or nil,
      item = slot.item, gender = slot.gender, shiny = slot.shiny,
    }
  end
  return fields
end

function PartyEditor.title(d)
  local who = d and d.class or "?"
  if d and d.mode == "custom" then
    return "TEAM " .. who .. " #" .. tostring(d.partyIndex or 1) .. " CUSTOM"
  end
  return "TEAM " .. who .. " #" .. tostring(d.partyIndex or 1)
end

local function effectiveTable(session, d)
  if d.mode == "custom" then
    return d.obj and d.obj.customParty or nil
  end
  return session:partyFor(d.class, d.partyIndex)
end

local function rebuild(ui)
  local d = ui.partyEditor
  if not d then return end
  local keep = math.min(d.index or 1, #(d.fields or {}))
  d.fields = buildFields(effectiveTable(d.session, d))
  d.index = math.max(1, math.min(keep, #d.fields))
  d.dropdown = nil
  d.levelEdit = nil
  if d.expand and d.expand > #d.fields then d.expand = nil end
end

function PartyEditor.openShared(ui, session, class, partyIndex, obj)
  if not (class and session.data.trainers
          and session.data.trainers[class]) then
    return false
  end
  ui.showInventory = true
  ui.details = nil
  ui.entityCreator = nil
  ui.encEditor = nil
  ui.showPicker = false
  if obj and not obj.isTrainer then obj = nil end
  ui.partyEditor = {
    session = session,
    class = class,
    partyIndex = partyIndex or 1,
    obj = obj,
    mode = (obj and obj.customParty and #obj.customParty > 0)
      and "custom" or "shared",
    fields = {},
    index = 1,
    expand = nil,
    dropdown = nil,
    levelEdit = nil,
    error = nil,
  }
  rebuild(ui)
  return true
end

function PartyEditor.open(ui, session, src)
  local class, partyIndex, obj
  if src and src.entity and src.entity.isTrainer then
    obj = src.entity
    class = obj.trainerClass
    partyIndex = obj.trainerParty or 1
  elseif src and src.item and src.item.kind == "entity"
      and src.item.create and src.item.create.objectType == "trainer" then
    class = src.item.create.trainerClass
    partyIndex = src.item.create.trainerParty or 1
  end
  if not class then return false end
  return PartyEditor.openShared(ui, session, class, partyIndex, obj)
end

function PartyEditor.close(ui)
  local d = ui.partyEditor
  ui.partyEditor = nil
  if d and d.returnCreator then
    local EntityCreator =
      require("mods.mapamap.components.entity_creator")
    EntityCreator.restoreDraft(ui, d.session, d.returnCreator.draft)
  end
end

-- ---------------------------------------------------------------------------
-- Mutations through the domain, mode-aware

local function mutate(ui, fn)
  local d = ui.partyEditor
  local ok = fn(d.session)
  if not ok and d.session._lastTeamError then
    d.error = d.session._lastTeamError
    d.session._lastTeamError = nil
  else
    d.error = nil
  end
  rebuild(ui)
  return ok
end

local function setMember(ui, slotIdx, patch)
  local d = ui.partyEditor
  if d.mode == "custom" then
    return mutate(ui,
      function(s) return s:setObjectCustomPartyMember(d.obj, slotIdx, patch) end)
  end
  return mutate(ui,
    function(s)
      return s:setTrainerPartyMember(d.class, d.partyIndex, slotIdx, patch)
    end)
end

local function addSlot(ui)
  local d = ui.partyEditor
  if d.mode == "custom" then
    return mutate(ui, function(s) return s:addObjectCustomPartySlot(d.obj) end)
  end
  return mutate(ui,
    function(s) return s:addTrainerPartySlot(d.class, d.partyIndex) end)
end

local function removeSlot(ui, slotIdx)
  local d = ui.partyEditor
  if d.mode == "custom" then
    return mutate(ui,
      function(s) return s:removeObjectCustomPartySlot(d.obj, slotIdx) end)
  end
  return mutate(ui,
    function(s)
      return s:removeTrainerPartySlot(d.class, d.partyIndex, slotIdx)
    end)
end

local function moveSlot(ui, slotIdx, delta)
  local d = ui.partyEditor
  if d.mode == "custom" then
    return mutate(ui,
      function(s) return s:moveObjectCustomPartySlot(d.obj, slotIdx, delta) end)
  end
  return mutate(ui,
    function(s)
      return s:moveTrainerPartySlot(d.class, d.partyIndex, slotIdx, delta)
    end)
end

-- Derives the latest-4 learnset moves for the ACTIVE slot (AUTO button).
local function autoMoves(ui)
  local d = ui.partyEditor
  local f = d.fields and d.fields[d.index]
  if not (f and f.kind == "slot") then return false end
  local TP = require("mods.mapamap.domain.trainer_party")
  local moves = TP.autoMoveset(d.session.data, f.species, f.level)
  if not moves then
    d.error = "no learnset for " .. tostring(f.species)
    rebuild(ui)
    return false
  end
  return setMember(ui, f.slot, { moves = moves })
end

-- Clears an explicit move override back to the ROM-defined set.
local function clearMoves(ui)
  local d = ui.partyEditor
  local f = d.fields and d.fields[d.index]
  if not (f and f.kind == "slot") then return false end
  return setMember(ui, f.slot, { moves = false })
end

-- Switches between the shared roster and the placement's own copy.
local function switchMode(ui, mode)
  local d = ui.partyEditor
  if mode == d.mode then return true end
  if mode == "custom" then
    local shared = d.session:partyFor(d.class, d.partyIndex)
    if not shared then return false end
    if not d.session:setObjectCustomParty(d.obj, shared) then
      d.error = "cannot customize"
      return false
    end
  elseif mode == "shared" then
    if not d.session:setObjectCustomParty(d.obj, nil) then
      d.error = "cannot revert to shared"
      return false
    end
  end
  d.error = nil
  d.mode = mode
  rebuild(ui)
  return true
end

listFor = function(session, key)
  local EntityCreator =
    require("mods.mapamap.components.entity_creator")
  return EntityCreator.listFor(session, key)
end

-- The four moves a slot will fight with: explicit override first, learnset
-- fallback second.
local function effectiveMoves(session, f)
  local TP = require("mods.mapamap.domain.trainer_party")
  local base = TP.autoMoveset(session.data, f.species, f.level) or {}
  local out = {}
  for i = 1, 4 do
    out[i] = (f.moves and f.moves[i]) or base[i] or ""
  end
  return out
end

-- Applies a dropdown pick to whichever target opened it.
local function applyPick(ui, session, pick)
  local d = ui.partyEditor
  local dd = d.dropdown
  if not dd then return end
  local list
  if dd.list == "species" then
    list = PartyEditor.speciesIds(session)
  else
    list = listFor(session, dd.list)
  end
  local id = list and list[pick]
  if not id then return end
  if dd.list == "species" then
    setMember(ui, dd.slot, { species = id })
  elseif dd.list == "items_none" then
    setMember(ui, dd.slot, { item = (id ~= "NONE") and id or false })
  elseif dd.list == "moves" then
    local f = d.fields[dd.slot]
    local mv = effectiveMoves(session, f)
    mv[dd.mvIdx] = id
    -- drop duplicate picks of the same id in other slots
    for k = 1, 4 do
      if k ~= dd.mvIdx and mv[k] == id then mv[k] = "" end
    end
    local cleaned = {}
    for _, v in ipairs(mv) do
      if v ~= "" then cleaned[#cleaned + 1] = v end
    end
    setMember(ui, dd.slot, { moves = (#cleaned > 0) and cleaned or false })
  end
end

-- ---------------------------------------------------------------------------
-- Mouse

function PartyEditor.mousepressed(ui, session, mx, my, button)
  local d = ui.partyEditor
  if not d then return false end
  local vw, vh = love.graphics.getDimensions()
  if not Panel.over(PartyEditor.rect, vw, vh, mx, my) then
    PartyEditor.close(ui)
    return true
  end
  if button ~= 1 then return true end

  -- Open dropdown: entry click applies; any other click closes.
  if d.dropdown then
    local anchorY = d.dropdown.anchorY
    local pick = PartyEditor.dropEntryAt(vw, vh, mx, my, anchorY,
      d.dropdown.scroll)
    if pick then applyPick(ui, session, pick) end
    d.dropdown = nil
    rebuild(ui)
    return true
  end

  -- Tabs (Shared/Custom).
  local font = session and session.font
  local tabIdx = PartyEditor.tabAt(vw, vh, mx, my, font, d)
  if tabIdx then
    if hasCustom(d) then
      switchMode(ui, tabIdx == 2 and "custom" or "shared")
    end
    return true
  end

  -- Bottom buttons.
  local btns = bottomButtons(vw, vh)
  if hitRect(btns.add, mx, my) then addSlot(ui) return true end
  if hitRect(btns.auto, mx, my) then autoMoves(ui) return true end
  if hitRect(btns.clearm, mx, my) then clearMoves(ui) return true end

  -- Rows.
  local rows, x, _y, w = PartyEditor.layout(vw, vh, d)
  local r = rowAt(rows, mx, my)
  if not r then return true end
  d.index = math.max(1, math.min(r.slot or d.index, #(d.fields or {})))
  local f = d.fields[r.slot]

  if r.kind == "head" then
    local areas = headAreas(x, w, r)
    if hitRect(areas.species, mx, my) then
      d.dropdown = { list = "species", scroll = 0, filter = "",
        slot = r.slot, anchorY = r.y }
    elseif hitRect(areas.level, mx, my) then
      -- Click the Lv cell to type the level (0-100); Enter commits.
      d.levelEdit = { buf = "", slot = r.slot }
    else
      -- Plain row click toggles the sub panel.
      d.expand = (d.expand == r.slot) and nil or r.slot
    end
    return true
  end

  -- Sub-panel controls.
  if r.name == "item" then
    d.dropdown = { list = "items_none", scroll = 0, filter = "",
      slot = r.slot, anchorY = r.y }
  elseif r.name == "gender" then
    local order = { "auto", "male", "female" }
    local cur = f.gender or "auto"
    local idx = 1
    for k, g in ipairs(order) do if g == cur then idx = k break end end
    setMember(ui, r.slot,
      { gender = order[(idx % #order) + 1] == "auto" and false
        or order[(idx % #order) + 1] })
  elseif r.name == "shiny" then
    setMember(ui, r.slot, { shiny = not f.shiny })
  elseif r.name:sub(1, 2) == "mv" then
    d.dropdown = { list = "moves", scroll = 0, filter = "",
      slot = r.slot, mvIdx = tonumber(r.name:sub(3)), anchorY = r.y }
  end
  rebuild(ui)
  return true
end

-- Wheel over the panel scrolls the open dropdown list.
function PartyEditor.scroll(ui, dy)
  local d = ui.partyEditor
  if not d or not d.dropdown then return end
  local vw, vh = love.graphics.getDimensions()
  local _, _, _, dh = PartyEditor.dropRect(vw, vh, d.dropdown.anchorY)
  if not dh then return end
  local key = d.dropdown.list
  local n = (key == "species") and #PartyEditor.speciesIds(d.session)
    or #listFor(d.session, key)
  d.dropdown.scroll = Dropdown.scrollBy(n, d.dropdown.scroll, dy, dh)
end

-- ---------------------------------------------------------------------------
-- Keyboard

function PartyEditor.key(ui, session, key)
  local d = ui.partyEditor
  if not d then return false end

  if d.dropdown then
    local list
    if d.dropdown.list == "species" then
      list = PartyEditor.speciesIds(session)
    else
      list = listFor(session, d.dropdown.list)
    end
    local vw, vh = love.graphics.getDimensions()
    local _, _, _, dh = PartyEditor.dropRect(vw, vh, d.dropdown.anchorY)
    if key == "up" then
      d.dropdown.scroll = Dropdown.clampScroll(#list,
        (d.dropdown.scroll or 0) - 1, Dropdown.visibleCount(dh))
    elseif key == "down" then
      d.dropdown.scroll = Dropdown.scrollBy(#list, d.dropdown.scroll, 1, dh)
    elseif key == "return" or key == "kpenter" then
      applyPick(ui, session, (d.dropdown.scroll or 0) + 1)
      d.dropdown = nil
      rebuild(ui)
    elseif key == "escape" then
      d.dropdown = nil
    elseif #key == 1 then
      d.dropdown.filter = (d.dropdown.filter or "") .. key:upper()
      local pickIdx = Dropdown.uniqueMatch(list, d.dropdown.filter)
      if pickIdx then
        applyPick(ui, session, pickIdx)
        d.dropdown = nil
        rebuild(ui)
      end
    end
    return true
  end

  if d.levelEdit then
    local f = d.fields and d.fields[d.index]
    if key == "return" or key == "kpenter" then
      if f then
        setMember(ui, f.slot, { level = tonumber(d.levelEdit.buf) or f.level })
      end
      d.levelEdit = nil
      rebuild(ui)
    elseif key == "escape" then
      d.levelEdit = nil
    elseif key == "backspace" then
      d.levelEdit.buf = d.levelEdit.buf:sub(1, #d.levelEdit.buf - 1)
    elseif #key == 1 and key >= "0" and key <= "9"
        and #d.levelEdit.buf < 3 then
      d.levelEdit.buf = d.levelEdit.buf .. key
      if f then
        setMember(ui, f.slot, { level = tonumber(d.levelEdit.buf) or f.level })
      end
    end
    return true
  end

  local shift = love.keyboard.isDown
    and (love.keyboard.isDown("lshift") or love.keyboard.isDown("rshift"))
  local f = d.fields and d.fields[d.index]
  if key == "up" then
    if f and shift then moveSlot(ui, f.slot, -1)
    else d.index = math.max(1, d.index - 1) end
  elseif key == "down" then
    if f and shift then moveSlot(ui, f.slot, 1)
    else d.index = math.min(#(d.fields or {}), d.index + 1) end
  elseif key == "left" or key == "right" then
    if f then
      setMember(ui, f.slot, { level = (f.level or 1)
        + (key == "right" and 1 or -1) })
    end
  elseif key == "return" or key == "kpenter" then
    if f then
      -- Toggle expansion on Enter; the species dropdown stays on click.
      d.expand = (d.expand == f.slot) and nil or f.slot
    end
  elseif key == "a" then
    addSlot(ui)
  elseif key == "x" or key == "delete" then
    if f then removeSlot(ui, f.slot) end
  elseif key == "m" then
    autoMoves(ui)
  elseif key == "c" then
    clearMoves(ui)
  elseif key == "escape" then
    PartyEditor.close(ui)
  end
  return true
end

-- ---------------------------------------------------------------------------
-- Draw

local function drawScopeChip(font, d, x, y, w)
  local text
  if d.mode == "custom" then
    text = "ONLY THIS PLACEMENT"
  else
    text = ("EDITS EVERY %s FIGHTING PARTY #%d"):format(
      tostring(d.class), d.partyIndex or 1)
  end
  Text.label(font, Panel.fitText(font, text, w - PAD * 2, 1),
    x + PAD, y + PAD + Panel.TITLE_H + Panel.TITLE_GAP, 1,
    { bg = d.mode == "custom" and { 0.25, 0.5, 0.3, 0.95 }
        or { 0.55, 0.4, 0.15, 0.95 }, padX = 2, padY = 1 })
end

local SUB_LABELS = {
  item = "HELD ITEM", gender = "GENDER", shiny = "SHINY",
}

function PartyEditor.draw(session, state, vw, vh, font)
  local d = state
  local x, y, w, h = PartyEditor.rect(vw, vh)
  Panel.drawBg(x, y, w, h)
  Panel.drawTitle(font, PartyEditor.title(d), x, y)
  drawScopeChip(font, d, x, y, w)

  local mx, my = love.mouse.getPosition()
  Panel.drawTabs(tabDefs(d), x, Panel.titleBottom(y), font,
    d.mode == "custom" and 2 or 1, mx, my)
  Panel.resetColor()

  local rows = PartyEditor.layout(vw, vh, d)
  local btns = bottomButtons(vw, vh)

  for ri, r in ipairs(rows) do
    local f = d.fields[r.slot]
    if r.kind == "head" then
      local ry = r.y
      Text.label(font, tostring(f.slot) .. ":", x + PAD, ry + 3, 2,
        { bg = Panel.CHIP_ROW, padX = 2, padY = 1 })

      local areas = headAreas(x, w, r)
      local isOpen = d.dropdown and d.dropdown.slot == r.slot
        and d.dropdown.list == "species"
      local label = isOpen and ((d.dropdown.filter or "") .. "_")
        or tostring(f.species or "?")
      Panel.renderDropdownButton(font,
        Panel.fitText(font, label, areas.species[3] - 10, 2),
        areas.species[1], areas.species[2], areas.species[3], ROW_H,
        mx, my, isOpen)

      -- Level: click the cell to type 0-100.
      local lvText
      if d.levelEdit and d.levelEdit.slot == r.slot then
        lvText = "Lv" .. d.levelEdit.buf .. "_"
        Text.label(font, lvText, areas.level[1] + 3, ry + 3, 2,
          { bg = Panel.CHIP_EDIT, padX = 1, padY = 1 })
      else
        lvText = "Lv" .. tostring(f.level or 1)
        Text.label(font, lvText, areas.level[1] + 3, ry + 3, 2,
          { bg = Panel.CHIP_VALUE, padX = 1, padY = 1 })
      end

      local mvx = headAreas(x, w, r).moves
      Text.label(font, f.moveCount and (f.moveCount .. " MV") or "AUTO",
        mvx[1] + 4, ry + 3, 2,
        { bg = f.moveCount and { 0.35, 0.35, 0.5, 0.95 } or Panel.CHIP_ROW,
          padX = 2, padY = 1 })

      if d.index == r.slot and not d.dropdown then
        Panel.drawSel(x + 2, ry - 3, w - 4, ROW_H)
      end
      if d.expand == r.slot then
        Text.label(font, "v", x + w - PAD - 12, ry + 3, 1,
          { bg = Panel.CHIP_ROW, padX = 1, padY = 0 })
      end
    else
      -- Sub row.
      local ry = r.y
      local label = SUB_LABELS[r.name]
        or ("MOVE " .. r.name:sub(3))
      Text.label(font, label, x + PAD + 14, ry + 3, 1,
        { bg = Panel.CHIP_ROW, padX = 2, padY = 0 })
      local cx = x + PAD + 90
      if r.name == "item" then
        local isOpen = d.dropdown and d.dropdown.list == "items_none"
          and d.dropdown.slot == r.slot
        local val = f.item or "NONE"
        Panel.renderDropdownButton(font,
          Panel.fitText(font, val, w - cx - PAD * 2 - 8, 2),
          cx, ry, w - cx - PAD * 2, ROW_H - 2, mx, my, isOpen)
      elseif r.name == "gender" then
        local g = f.gender or "auto"
        Text.label(font, ("" .. g:upper() .. ""), cx + 4, ry + 2, 2,
          { bg = Panel.CHIP_VALUE, padX = 2, padY = 1 })
      elseif r.name == "shiny" then
        Text.label(font, f.shiny and "YES" or "NO", cx + 4, ry + 2, 2,
          { bg = f.shiny and { 0.5, 0.42, 0.1, 0.95 } or Panel.CHIP_VALUE,
            padX = 2, padY = 1 })
      else
        local mvIdx = tonumber(r.name:sub(3))
        local mvList = effectiveMoves(session, f)
        local mvId = mvList[mvIdx] or "-"
        local isOpen = d.dropdown and d.dropdown.list == "moves"
          and d.dropdown.slot == r.slot
          and d.dropdown.mvIdx == mvIdx
        Panel.renderDropdownButton(font,
          Panel.fitText(font, mvId, w - cx - PAD * 2 - 8, 2),
          cx, ry, w - cx - PAD * 2, ROW_H - 2, mx, my, isOpen)
      end
      if d.expand == r.slot and d.index == r.slot then
        love.graphics.setColor(0.25, 0.5, 1, 0.35)
        love.graphics.rectangle("fill", x + 8, ry - 1, w - 16, SUB_H - 2)
      end
    end
  end
  Panel.resetColor()

  -- Bottom buttons.
  do
    local defs = {
      { btns.add, "ADD", { 0.16, 0.35, 0.18, 0.95 } },
      { btns.auto, "AUTO MOVES", { 0.14, 0.24, 0.16, 0.95 } },
      { btns.clearm, "CLEAR MOVES", { 0.24, 0.14, 0.14, 0.95 } },
    }
    for _, def in ipairs(defs) do
      local rr, label, bg = def[1], def[2], def[3]
      local hovered = hitRect(rr, mx, my)
      love.graphics.setColor(bg[1], bg[2], bg[3], bg[4])
      love.graphics.rectangle("fill", rr[1], rr[2], rr[3], rr[4])
      love.graphics.setColor(hovered and 0.9 or 0.5, hovered and 0.9 or 0.5,
        hovered and 0.9 or 0.55, 0.7)
      love.graphics.rectangle("line", rr[1], rr[2], rr[3], rr[4])
      Text.label(font, label, rr[1] + 4, rr[2] + 3, 2,
        { bg = Panel.CHIP_TITLE, padX = 2, padY = 1 })
    end
    Panel.resetColor()
  end

  -- Open dropdown (species/items/moves).
  if d.dropdown then
    local dx, dy, dw, dh = PartyEditor.dropRect(vw, vh,
      d.dropdown.anchorY, d.dropdown.scroll)
    if dx then
      local list
      if d.dropdown.list == "species" then
        list = PartyEditor.speciesIds(session)
      else
        list = listFor(session, d.dropdown.list)
      end
      local hoverEntry = PartyEditor.dropEntryAt(vw, vh, mx, my,
        d.dropdown.anchorY, d.dropdown.scroll)
      local f = d.fields[d.dropdown.slot]
      local curVal
      if d.dropdown.list == "species" then curVal = f and f.species
      elseif d.dropdown.list == "items_none" then curVal = f and (f.item or "NONE")
      else
        local mv = effectiveMoves(session, f)
        curVal = mv[d.dropdown.mvIdx]
      end
      -- Highlight the visible row matching the current value.
      local selIdx
      for k = 1, Dropdown.visibleCount(dh) do
        local id = list[(d.dropdown.scroll or 0) + k]
        if id and id == curVal then
          selIdx = (d.dropdown.scroll or 0) + k break
        end
      end
      Dropdown.draw(font, list, dx, dy, dw, dh, d.dropdown.scroll,
        selIdx, hoverEntry)
    end
  end

  local hint
  if d.dropdown then
    hint = "Up/Down: scroll  Enter: select  Esc: close  type: filter"
  elseif d.levelEdit then
    hint = "Type digits (1-100)  Enter: ok  Esc: cancel"
  elseif d.error then
    hint = "!! " .. d.error
  else
    hint = "Click slot: expand  click Lv: type 0-100  species/moves/item dropdowns  A add  X del  S+Up/Dn order  M auto  C clear  Esc close"
  end
  Panel.drawHint(font, hint, x, y, w, h)
  Panel.resetColor()
end

return PartyEditor
