-- Tileset picker component: the centered panel with a scrollable left column
-- of tileset names and a right grid of the active category.
--
-- The left list is a mixed catalog: a virtual "Items & NPCs" entry first, then
-- every real tileset (the current map's tileset kept default / highlighted).
-- Selecting a real tileset shows its blocks; selecting the virtual entry shows
-- the map-item and NPC sprite catalog.
--
-- This module owns all picker geometry (panel, grid, tileset list), the
-- catalog ordering, and the draw routine.  Input queries it for hit-testing;
-- the overlay orchestrator only calls Picker.draw.

local Common = require("mods.mapamap.func.common")
local Item = require("mods.mapamap.components.item")

local Picker = {}

Picker.SPEC = "__ITEMS_NPCS__"   -- pseudo-tileset id for items + NPCs
Picker.SPECIAL_LABEL = "Items & NPCs"

Picker.GAP = 6
Picker.PAD = 10
Picker.HEAD_H = 40   -- title row height (above list + grid)
Picker.LIST_W = 150  -- left column width (tileset names)
Picker.LIST_ROW = 26 -- height of one tileset name row
Picker.SLOT = 48     -- square item cell size (matches the hotbar)

local function boxRows(vh)
  local band = vh * 0.6 - Picker.HEAD_H - Picker.PAD * 2
  return math.max(4, math.min(8, math.floor(band / (Picker.SLOT + Picker.GAP))))
end

-- How many item columns fit in a viewport width (right of the name column).
function Picker.cols(vw)
  local usable = vw * 0.72 - Picker.PAD * 2 - Picker.LIST_W - Picker.GAP
  local cols = math.floor(usable / (Picker.SLOT + Picker.GAP))
  return math.max(6, math.min(16, cols))
end

-- How many item rows fit, given a viewport height (~ top 60% band).
function Picker.rows(vh)
  return boxRows(vh)
end

-- Centered panel rect (left name column + right item grid).
function Picker.rect(vw, vh)
  local cols = Picker.cols(vw)
  local rows = Picker.rows(vh)
  local w = Picker.PAD + Picker.LIST_W + Picker.GAP
            + cols * (Picker.SLOT + Picker.GAP) + Picker.GAP + Picker.PAD
  local h = Picker.HEAD_H + rows * (Picker.SLOT + Picker.GAP) + Picker.PAD * 2 + 6
  local x = math.floor((vw - w) / 2)
  local y = math.floor((vh - h) / 3)
  return x, y, w, h
end

-- How many items fit on one picker page.
function Picker.perPage(vw, vh)
  return Picker.cols(vw) * Picker.rows(vh)
end

-- Which picker-list index (1-based, into the full item list) is under
-- (mx,my), or nil.  `scroll` is a page number (1-based).
function Picker.itemAt(vw, vh, mx, my, scroll)
  local px, py, pw, ph = Picker.rect(vw, vh)
  if mx < px or mx >= px + pw or my < py or my >= py + ph then return nil end
  local cols = Picker.cols(vw)
  local gx = mx - px - Picker.PAD - Picker.LIST_W - Picker.GAP
  local gy = my - py - Picker.HEAD_H - 6
  if gx < 0 then return nil end
  local col = math.floor(gx / (Picker.SLOT + Picker.GAP))
  local row = math.floor(gy / (Picker.SLOT + Picker.GAP))
  if col >= cols or row < 0 then return nil end
  local pageStart = ((scroll or 1) - 1) * Picker.perPage(vw, vh)
  return pageStart + row * cols + col + 1
end

-- Bounding rect of the left tileset-name list.
function Picker.listRect(vw, vh)
  local px, py, _, ph = Picker.rect(vw, vh)
  local x = px + Picker.PAD
  local y = py + Picker.HEAD_H + 6
  local h = ph - (py + Picker.HEAD_H + 6) - Picker.PAD
  return x, y, Picker.LIST_W, h
end

-- How many tileset names fit in the left list viewport.
function Picker.namesPerPage(vw, vh)
  local _, _, _, h = Picker.listRect(vw, vh)
  return math.max(1, math.floor(h / Picker.LIST_ROW))
end

-- Index (1-based, into the sorted name list) of the tilesetName row under
-- (mx,my) for the given scroll page, or nil.
function Picker.nameAt(vw, vh, mx, my, scroll)
  local x, y, w, h = Picker.listRect(vw, vh)
  if mx < x or mx >= x + w or my < y or my >= y + h then return nil end
  local per = Picker.namesPerPage(vw, vh)
  local idx = math.floor((my - y) / Picker.LIST_ROW) + 1
  if idx < 1 or idx > per then return nil end
  return ((scroll or 1) - 1) * per + idx
end

-- ---------------------------------------------------------------------------
-- Catalog

-- The display name for a catalog id (the virtual entry has a friendly label).
function Picker.label(session, id)
  if id == Picker.SPEC then return Picker.SPECIAL_LABEL end
  local ts = session.data and session.data.tilesets and session.data.tilesets[id]
  return (ts and ts.name) or ts and ts.label or id or "?"
end

-- Ordered catalog list: the "Items & NPCs" pseudo-tileset first, then every
-- real tileset.  The current map's tileset is moved to the head of the real
-- tilesets so the picker always shows the map it is editing first.
function Picker.catalog(session)
  local out = { Picker.SPEC }
  local cur = session.tileset and session.tileset.id
  local names = {}
  for k in pairs(session.data and session.data.tilesets or {}) do
    if k ~= cur then table.insert(names, k) end
  end
  table.sort(names)
  if cur then table.insert(out, cur) end
  for _, k in ipairs(names) do table.insert(out, k) end
  return out
end

-- The tileset a picker selection refers to: nil (unset) or the virtual id
-- always resolves to the current map's tileset for blocks, while the virtual
-- id maps to the items/NPC catalog.
function Picker.resolve(selection, session)
  return (selection == nil) and (session.tileset and session.tileset.id)
        or selection
end

-- The full item list for the currently-browsed catalog entry (or the current
-- map's tileset when unset), as { kind, id } items.
function Picker.itemList(session, selection)
  local data = session.data
  if selection == Picker.SPEC then
    -- Virtual catalog: NPC sprites, then items.
    local list = {}
    local sprites = data and data.sprites
    if sprites then
      local keys = {}
      for k in pairs(sprites) do table.insert(keys, k) end
      table.sort(keys)
      for _, id in ipairs(keys) do list[#list + 1] = { kind = "sprite", id = id } end
    end
    local items = data and data.items
    if items then
      local ik = {}
      for k in pairs(items) do table.insert(ik, k) end
      table.sort(ik)
      for _, id in ipairs(ik) do list[#list + 1] = { kind = "item", id = id } end
    end
    return list
  end
  local tsName = Picker.resolve(selection, session)
  local ts = tsName and data and data.tilesets and data.tilesets[tsName]
  local blocks = ts and ts.blocks
  local list = {}
  if blocks then
    for i = 1, #blocks do list[#list + 1] = { kind = "block", id = i - 1 } end
  end
  return list
end

-- The current map's tileset id (used as the highlighted default).
function Picker.current(session)
  return session.tileset and session.tileset.id
end

-- ---------------------------------------------------------------------------
-- Draw

-- Draws the picker panel.  `state` carries the Input-owned UI state
-- { selection, scroll, listScroll, perPage }.
function Picker.draw(session, vw, vh, state, font)
  local app = state or {}
  local selection = app.selection -- may be nil = default to current map
  local ix, iy, iw, ih = Picker.rect(vw, vh)
  love.graphics.setColor(0, 0, 0, 0.92)
  love.graphics.rectangle("fill", ix, iy, iw, ih)
  love.graphics.setColor(0.55, 0.55, 0.6, 0.5)
  love.graphics.rectangle("line", ix, iy, iw, ih)

  local catalog = Picker.catalog(session)
  local active = Picker.resolve(selection, session) or Picker.current(session)
  local activeLabel = Picker.label(session, active)

  love.graphics.setColor(1, 1, 1, 0.95)
  font.draw("Tilesets   (E to close)   showing: " .. activeLabel
    .. "   page " .. tostring(app.scroll or 1)
    .. "/" .. tostring(math.max(1, math.ceil(#Picker.itemList(session, selection)
    / Picker.perPage(vw, vh)))), ix + 6, iy + 8)
  love.graphics.setColor(1, 1, 1, 1)

  -- Left column: catalog names, scrollable.  White text on black.
  local lx, ly, lw, lh = Picker.listRect(vw, vh)
  love.graphics.setColor(0, 0, 0, 0.6)
  love.graphics.rectangle("fill", lx, ly, lw, lh)
  love.graphics.setColor(0.35, 0.35, 0.4, 0.6)
  love.graphics.rectangle("line", lx, ly, lw, lh)
  local mx, my = love.mouse.getPosition()
  local hoverIdx = Picker.nameAt(vw, vh, mx, my, app.listScroll or 1)
  local perTs = Picker.namesPerPage(vw, vh)
  local pageStart = ((app.listScroll or 1) - 1) * perTs
  local y = ly
  for i = 1, perTs do
    local idx = pageStart + i
    local cid = catalog[idx]
    if not cid then break end
    local name = Picker.label(session, cid)
    local isActive = (cid == active) and not (cid == Picker.SPEC)
    if cid == Picker.SPEC and selection == Picker.SPEC then isActive = true end
    local isHover = (hoverIdx == idx)
    love.graphics.setColor(0.3, 0.3, 0.35, 0.9)
    if isActive then
      love.graphics.setColor(1, 1, 1, 0.16)
    elseif isHover then
      love.graphics.setColor(1, 1, 1, 0.08)
    end
    love.graphics.rectangle("fill", lx + 1, y + 1, lw - 2, Picker.LIST_ROW - 2)
    love.graphics.setColor(1, 1, 1, 1)
    font.draw(name, lx + 6, y + 4)
    if isActive then
      love.graphics.setColor(1, 1, 1, 0.8)
      love.graphics.rectangle("line", lx + 1, y + 1, lw - 2, Picker.LIST_ROW - 2)
    end
    y = y + Picker.LIST_ROW
  end
  love.graphics.setColor(1, 1, 1, 1)

  -- Right side: grid for the active catalog.
  local list = Picker.itemList(session, selection)
  local cols = Picker.cols(vw)
  local perPageItems = Picker.perPage(vw, vh)
  local gridStart = ((app.scroll or 1) - 1) * perPageItems

  local hoverItem = Picker.itemAt(vw, vh, mx, my, app.scroll or 1)

  local gx = ix + Picker.PAD + Picker.LIST_W + Picker.GAP
  local gy = iy + Picker.HEAD_H + 6
  local row = 0
  while gy + Picker.SLOT <= iy + ih and row < math.floor(perPageItems / cols) do
    for col = 0, cols - 1 do
      local slot = gridStart + row * cols + col + 1
      if slot > #list then break end
      local item = list[slot]
      love.graphics.setColor(0.22, 0.22, 0.26, 0.92)
      love.graphics.rectangle("fill", gx, gy, Picker.SLOT, Picker.SLOT)
      Item.draw(session, item, gx + 2, gy + 2, Picker.SLOT - 4)
      -- white ring on hover, red ring on the selected hotbar item
      if hoverItem == slot then
        love.graphics.setColor(1, 1, 1, 0.95)
        love.graphics.rectangle("line", gx - 1, gy - 1, Picker.SLOT + 2, Picker.SLOT + 2)
      elseif item.kind == "block" and item.id == session.selectedBlock then
        love.graphics.setColor(1, 0.3, 0.3, 0.8)
        love.graphics.rectangle("line", gx - 1, gy - 1, Picker.SLOT + 2, Picker.SLOT + 2)
      elseif (item.kind == "sprite" or item.kind == "item")
            and item.id == session.selectedSprite then
        love.graphics.setColor(1, 0.3, 0.3, 0.8)
        love.graphics.rectangle("line", gx - 1, gy - 1, Picker.SLOT + 2, Picker.SLOT + 2)
      end
      gx = gx + Picker.SLOT + Picker.GAP
    end
    gx = ix + Picker.PAD + Picker.LIST_W + Picker.GAP
    gy = gy + Picker.SLOT + Picker.GAP
    row = row + 1
  end
  love.graphics.setColor(1, 1, 1, 1)
end

return Picker