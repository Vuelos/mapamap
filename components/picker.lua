-- Tileset picker component: the panel to the inventory's right with a tileset
-- dropdown at the top and a grid of the active category below.
--
-- The dropdown entry is a mixed catalog: a virtual "Items & NPCs" entry first,
-- then every real tileset (the current map's tileset kept default /
-- highlighted).  Selecting a real tileset shows its blocks; selecting the
-- virtual entry shows the NPC sprite catalog.
--
-- This module owns all picker geometry (panel, dropdown, grid), the catalog
-- ordering, and the draw routine.  Input queries it for hit-testing; the
-- overlay orchestrator only calls Picker.draw.

local Common = require("mods.mapamap.func.common")
local Item = require("mods.mapamap.components.item")
local Inventory = require("mods.mapamap.components.inventory")
local Text = require("mods.mapamap.components.text")

local Picker = {}

Picker.SPEC = "__ITEMS_NPCS__"   -- pseudo-tileset id for NPC sprites
Picker.SPECIAL_LABEL = "NPCs"

-- The block grid matches the inventory exactly: same cell size, gap, padding
-- and column count, so picker thumbnails read at the same scale as the left
-- collection's.
Picker.PAD = Inventory.PAD
Picker.SLOT = Inventory.SLOT
Picker.GAP = Inventory.GAP
Picker.COLS = Inventory.COLS
Picker.DROP_H = 24      -- height of the tileset dropdown rows

-- Header rows: padding, title text (2x = 16px), gap, dropdown row.
Picker.HEAD_H = Picker.PAD + 16 + 6 + Picker.DROP_H

-- Truncates a label to fit `budgetPx` of love screen width once drawn at
-- `scale` (glyphs measure against the real Font.width, halved back for scale).
local function fitText(font, s, budgetPx, scale)
  scale = scale or 2
  local function w(t)
    return ((font.width and font.width(t)) or (#t * 8)) * scale
  end
  if w(s) <= budgetPx then return s end
  while #s > 0 and w(s) > budgetPx do s = s:sub(1, #s - 1) end
  return s .. "..."
end

-- Panel rect: the same size as the inventory, sitting at its right side.
function Picker.rect(vw, vh)
  return Inventory.sideRect(vw, vh)
end

-- Block grid columns: fixed to the inventory's (10).
function Picker.cols(vw, vh)
  return Picker.COLS
end

-- How many item rows fit below the chip row.
function Picker.rows(vw, vh)
  local _, _, _, ph = Picker.rect(vw, vh)
  local usable = ph - Picker.HEAD_H - Picker.PAD * 2 - 6
  return math.max(1, math.floor(usable / (Picker.SLOT + Picker.GAP)))
end

-- How many items fit on one picker page.
function Picker.perPage(vw, vh)
  return Picker.cols(vw, vh) * Picker.rows(vw, vh)
end

-- Which picker-list index (1-based, into the full item list) is under
-- (mx,my), or nil.  `scroll` is a page number (1-based).
function Picker.itemAt(vw, vh, mx, my, scroll)
  local px, py, pw, ph = Picker.rect(vw, vh)
  if mx < px or mx >= px + pw or my < py or my >= py + ph then return nil end
  local cols = Picker.cols(vw, vh)
  local gx = mx - px - Picker.PAD
  local gy = my - py - Picker.HEAD_H - 6
  if gx < 0 then return nil end
  local col = math.floor(gx / (Picker.SLOT + Picker.GAP))
  local row = math.floor(gy / (Picker.SLOT + Picker.GAP))
  if col >= cols or row < 0 then return nil end
  local pageStart = ((scroll or 1) - 1) * Picker.perPage(vw, vh)
  return pageStart + row * cols + col + 1
end

-- Bounding rect of the closed tileset dropdown button (fills the header band
-- below the title).
function Picker.dropRect(vw, vh)
  local px, py, pw, _ = Picker.rect(vw, vh)
  return px + Picker.PAD, py + Picker.PAD + 16 + 6, pw - Picker.PAD * 2, Picker.DROP_H
end

-- True when a screen point is on the dropdown button.
function Picker.dropAt(vw, vh, mx, my)
  local x, y, w, h = Picker.dropRect(vw, vh)
  return mx >= x and mx < x + w and my >= y and my < y + h
end

-- How many catalog entries fit in the open list (bounded by the panel).
function Picker.dropPerPage(session, vw, vh)
  local _, py, _, ph = Picker.rect(vw, vh)
  local _, by, _, _ = Picker.dropRect(vw, vh)
  local top = by + Picker.DROP_H + Picker.GAP
  local avail = (py + ph) - top - Picker.PAD
  local per = math.floor(avail / (Picker.DROP_H + 2))
  return math.max(1, per)
end

-- Bounding rect of the open dropdown list (directly below the button, drawn
-- over the grid).
function Picker.dropListRect(session, vw, vh)
  local x, y, w, _ = Picker.dropRect(vw, vh)
  return x, y + Picker.DROP_H + Picker.GAP, w,
    Picker.dropPerPage(session, vw, vh) * Picker.DROP_H
end

-- Catalog entry index (1-based, into the catalog) under (mx,my) in the open
-- list, or nil.  `page` is a page number (1-based).
function Picker.dropEntryAt(session, vw, vh, mx, my, page)
  local x, y, w, h = Picker.dropListRect(session, vw, vh)
  if mx < x or mx >= x + w or my < y or my >= y + h then return nil end
  local row = math.floor((my - y) / Picker.DROP_H) + 1
  local per = Picker.dropPerPage(session, vw, vh)
  if row < 1 or row > per then return nil end
  return ((page or 1) - 1) * per + row
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

-- The tileset DEF currently browsed: the selected real tileset, or the current
-- map's tileset when nothing has been selected.  Returns nil for the virtual
-- "Items & NPCs" catalog (it carries no blocks).  Resolving the browsed tileset
-- here (rather than reaching back to session.tileset inside itemList) is what
-- keeps a non-current tileset listing ITS OWN blocks instead of the live map's.
function Picker.tilesetDef(session, selection)
  local tsName = Picker.resolve(selection, session)
  if not tsName or tsName == Picker.SPEC then return nil end
  return session.data and session.data.tilesets and session.data.tilesets[tsName]
end

-- The full item list for the currently-browsed catalog entry (or the current
-- map's tileset when unset), as { kind, id } items.  Block ids are indices into
-- the BROWSED tileset's blocks (see tilesetDef), so a non-current tileset lists
-- its own block count -- not the live map's.  For a FOREIGN tileset the items
-- carry srcTileset so the paint brush can graft them into the current map.
function Picker.itemList(session, selection)
  local data = session.data
  if selection == Picker.SPEC then
    -- Virtual catalog: NPC sprites only (map items live in the inventory,
    -- not the picker).
    local list = {}
    local sprites = data and data.sprites
    if sprites then
      local keys = {}
      for k in pairs(sprites) do table.insert(keys, k) end
      table.sort(keys)
      for _, id in ipairs(keys) do list[#list + 1] = { kind = "sprite", id = id } end
    end
    return list
  end
  local ts = Picker.tilesetDef(session, selection)
  local blocks = ts and ts.blocks
  local list = {}
  if blocks then
    -- Foreign tilesets tag their items so painting sits trees/water/etc from
    -- another tileset into the current map via grafting.
    local cur = Picker.current(session)
    local foreign = ts and ts.id ~= cur
    for i = 1, #blocks do
      local item = { kind = "block", id = i - 1 }
      if foreign then item.srcTileset = ts.id end
      list[#list + 1] = item
    end
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
-- { selection, scroll, listScroll = dropdown page, dropOpen }.
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

  -- Atlas bundle for the block thumbnails: when browsing a tileset other than
  -- the live map's, render from THAT tileset's image/quads/blocks (cached) so
  -- each catalog entry shows its own tiles, not the current map's.  nil lets
  -- Item.draw fall back to the live map renderer (current tileset / sprites).
  local browsedTs = Picker.tilesetDef(session, selection)
  local thumbBundle = (browsedTs and browsedTs ~= session.tileset)
    and session:thumbnailBundle(browsedTs) or nil

  -- Big, high-contrast header; the active label is clipped to the panel.
  local pages = math.max(1, math.ceil(#Picker.itemList(session, selection)
    / Picker.perPage(vw, vh)))
  local head = fitText(font,
    "TILESETS (E)  " .. activeLabel .. "  pg " .. tostring(app.scroll or 1)
    .. "/" .. tostring(pages), iw - Picker.PAD * 2, 2)
  Text.label(font, head, ix + Picker.PAD, iy + 6, 2, {
    bg = { 0.92, 0.92, 0.95, 0.95 }, padX = 3, padY = 2,
  })
  love.graphics.setColor(1, 1, 1, 1)
  local mx, my = love.mouse.getPosition()

  -- Tileset dropdown: a single button showing the active catalog entry; the
  -- open list is drawn over the grid below.
  local dropX, dropY, dropW, dropH = Picker.dropRect(vw, vh)
  Text.label(font, fitText(font, activeLabel, dropW - 24, 2),
    dropX + 4, dropY + 3, 2, { bg = { 0.92, 0.92, 0.95, 0.95 }, padX = 3, padY = 2 })
  -- Down-chevron on the button's right end.
  love.graphics.setColor(0.05, 0.05, 0.09, 1)
  love.graphics.polygon("fill",
    dropX + dropW - 16, dropY + 6,
    dropX + dropW - 8, dropY + 6,
    dropX + dropW - 12, dropY + dropH - 7)
  if app.dropOpen or Picker.dropAt(vw, vh, mx, my) then
    love.graphics.setColor(0.35, 0.55, 0.95, 0.9)
    love.graphics.rectangle("line", dropX, dropY, dropW, dropH)
  end
  love.graphics.setColor(1, 1, 1, 1)

  -- Grid for the active catalog.
  local list = Picker.itemList(session, selection)
  local cols = Picker.cols(vw, vh)
  local perPageItems = Picker.perPage(vw, vh)
  local gridStart = ((app.scroll or 1) - 1) * perPageItems

  local hoverItem = Picker.itemAt(vw, vh, mx, my, app.scroll or 1)

  local gx = ix + Picker.PAD
  local gy = iy + Picker.HEAD_H + 6
  local row = 0
  while gy + Picker.SLOT <= iy + ih and row < math.floor(perPageItems / cols) do
    for col = 0, cols - 1 do
      local slot = gridStart + row * cols + col + 1
      if slot > #list then break end
      local item = list[slot]
      love.graphics.setColor(0.22, 0.22, 0.26, 0.92)
      love.graphics.rectangle("fill", gx, gy, Picker.SLOT, Picker.SLOT)
      Item.draw(session, item, gx + 2, gy + 2, Picker.SLOT - 4, thumbBundle)
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
    gx = ix + Picker.PAD
    gy = gy + Picker.SLOT + Picker.GAP
    row = row + 1
  end
  love.graphics.setColor(1, 1, 1, 1)

  -- Open tileset dropdown list (drawn over the grid).
  if app.dropOpen then
    local lx, ly, lw, lh = Picker.dropListRect(session, vw, vh)
    love.graphics.setColor(0, 0, 0, 0.94)
    love.graphics.rectangle("fill", lx, ly, lw, lh)
    love.graphics.setColor(0.55, 0.55, 0.6, 0.5)
    love.graphics.rectangle("line", lx, ly, lw, lh)
    local per = Picker.dropPerPage(session, vw, vh)
    local pageStart = ((app.listScroll or 1) - 1) * per
    local hoverEntry = Picker.dropEntryAt(session, vw, vh, mx, my, app.listScroll or 1)
    local activeSel = selection or Picker.current(session)
    for i = 1, per do
      local idx = pageStart + i
      local cid = catalog[idx]
      if not cid then break end
      local ey = ly + (i - 1) * Picker.DROP_H
      local isSel = (cid == activeSel) and cid ~= Picker.SPEC
      if cid == Picker.SPEC and selection == Picker.SPEC then isSel = true end
      -- Single light chip per entry (no dark button rectangle behind it).
      Text.label(font, fitText(font, Picker.label(session, cid), lw - 12, 2),
        lx + 4, ey + 2, 2, { bg = { 0.92, 0.92, 0.95, 0.95 }, padX = 2, padY = 1 })
      if isSel then
        love.graphics.setColor(0.25, 0.5, 1, 0.9)
        love.graphics.rectangle("line", lx + 1, ey + 1, lw - 2, Picker.DROP_H - 2)
      elseif hoverEntry == idx then
        love.graphics.setColor(1, 1, 1, 0.9)
        love.graphics.rectangle("line", lx + 1, ey + 1, lw - 2, Picker.DROP_H - 2)
      end
    end
    love.graphics.setColor(1, 1, 1, 1)
  end
end

return Picker