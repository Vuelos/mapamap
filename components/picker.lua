-- Tileset picker component: the panel to the inventory's right with a catalog
-- dropdown at the top and a grid of the active category below.
--
-- The dropdown entry is a mixed catalog: three virtual NPC entries first
-- (People = placeable person sprites, Monsters = wild-Pokemon tools,
-- Balls = item-ball tools), then every real tileset (the current map's
-- tileset kept default / highlighted).  Selecting a real tileset shows its
-- blocks; selecting a virtual entry shows its entity tool catalog.
--
-- This module owns all picker geometry (panel, dropdown, grid), the catalog
-- ordering, and the draw routine.  Input queries it for hit-testing; the
-- overlay orchestrator only calls Picker.draw.

local Common = require("mods.mapamap.common")
local Item = require("mods.mapamap.components.item")
local Inventory = require("mods.mapamap.components.inventory")
local Panel = require("mods.mapamap.components.panel")

local Picker = {}

Picker.SPEC_PERSON = "__NPC_PEOPLE__"    -- pseudo-tileset id: person sprites
Picker.SPEC_MONSTER = "__NPC_MONSTERS__" -- pseudo-tileset id: wild mon tools
Picker.SPEC_ITEMS = "__NPC_ITEMS__"      -- pseudo-tileset id: item ball tools

Picker.SPECIAL_LABELS = {
  [Picker.SPEC_PERSON] = "People",
  [Picker.SPEC_MONSTER] = "Monsters",
  [Picker.SPEC_ITEMS] = "Items",
}

-- True for every virtual (non-tileset) catalog id.
function Picker.isSpecial(id)
  return Picker.SPECIAL_LABELS[id] ~= nil
end

-- Every catchable species straight from data.pokemon -- no hardcoded list:
-- one entry per dex record, ordered by dex number (ties break on name).
function Picker.speciesList(session)
  local pokemon = session.data and session.data.pokemon or {}
  local out = {}
  for k, v in pairs(pokemon) do
    if type(v) == "table" and v.dex then out[#out + 1] = { id = k, dex = v.dex } end
  end
  table.sort(out, function(a, b)
    if a.dex ~= b.dex then return a.dex < b.dex end
    return a.id < b.id
  end)
  return out
end

-- Generic critter sheets used as the thumbnail when a species has no
-- overworld sheet of its own; picked deterministically per species so each
-- keeps a stable look across sessions.
local GENERIC_MONSTER_SPRITES = {
  "SPRITE_MONSTER", "SPRITE_BIRD", "SPRITE_SEEL",
  "SPRITE_FAIRY", "SPRITE_SNORLAX",
}

-- The overworld sprite shown for a species tool: an exact-named sheet when
-- the extraction carries one (SNORLAX -> SPRITE_SNORLAX), else a stable
-- generic monster sheet.
function Picker.speciesSprite(session, speciesId)
  local sprites = session.data and session.data.sprites or {}
  if sprites["SPRITE_" .. speciesId] then return "SPRITE_" .. speciesId end
  local keys = {}
  for _, s in ipairs(GENERIC_MONSTER_SPRITES) do
    if sprites[s] then keys[#keys + 1] = s end
  end
  if #keys == 0 then return nil end
  local h = 0
  for i = 1, #speciesId do h = (h * 31 + speciesId:byte(i)) % 1000003 end
  return keys[(h % #keys) + 1]
end

-- The block grid matches the inventory exactly: same cell size, gap, padding
-- and column count, so picker thumbnails read at the same scale as the left
-- collection's.
Picker.SLOT = Inventory.SLOT
Picker.GAP = Inventory.GAP
Picker.COLS = Inventory.COLS
Picker.DROP_H = 24      -- height of the tileset dropdown rows

-- Header rows: padding, title text (2x = 16px), gap, dropdown row.
Picker.HEAD_H = Panel.PAD + 16 + 6 + Picker.DROP_H

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
  local usable = ph - Picker.HEAD_H - Panel.PAD * 2 - 6
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
  local gx = mx - px - Panel.PAD
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
  return px + Panel.PAD, py + Panel.PAD + 16 + 6, pw - Panel.PAD * 2, Picker.DROP_H
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
  local avail = (py + ph) - top - Panel.PAD
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

-- The display name for a catalog id (virtual entries have friendly labels).
function Picker.label(session, id)
  if Picker.SPECIAL_LABELS[id] then return Picker.SPECIAL_LABELS[id] end
  local ts = session.data and session.data.tilesets and session.data.tilesets[id]
  return (ts and ts.name) or ts and ts.label or id or "?"
end

-- Ordered catalog list: the three NPC pseudo-catalogs first, then every real
-- tileset.  The current map's tileset is moved to the head of the real
-- tilesets so the picker always shows the map it is editing first.
function Picker.catalog(session)
  local out = { Picker.SPEC_PERSON, Picker.SPEC_MONSTER, Picker.SPEC_ITEMS }
  local cur = session.tileset and session.tileset.id
  local names = {}
  for k, v in pairs(session.data and session.data.tilesets or {}) do
    -- Only real tileset records: the Gen 2 extraction shares this table with
    -- animation side-tables (animFrames, flowerCgbFrames, flowerFrames,
    -- waterFrames) that are not tilesets and have no block list to browse.
    if k ~= cur and type(v) == "table" and v.blocks then
      table.insert(names, k)
    end
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
  if not tsName or Picker.isSpecial(tsName) then return nil end
  return session.data and session.data.tilesets and session.data.tilesets[tsName]
end

-- The full item list for the currently-browsed catalog entry (or the current
-- map's tileset when unset), as { kind, id } items.  Block ids are indices into
-- the BROWSED tileset's blocks (see tilesetDef), so a non-current tileset lists
-- its own block count -- not the live map's.  For a FOREIGN tileset the items
-- carry srcTileset so the paint brush can graft them into the current map.
function Picker.itemList(session, selection)
  local data = session.data
  local sprites = data and data.sprites

  -- People: every person sprite, directly placeable as an NPC (kind = "sprite"
  -- paints through Objects.placeSprite).
  if selection == Picker.SPEC_PERSON then
    local list = {}
    if sprites then
      local keys = {}
      for k in pairs(sprites) do keys[#keys + 1] = k end
      table.sort(keys)
      for _, id in ipairs(keys) do
        list[#list + 1] = { kind = "sprite", id = id }
      end
    end
    return list
  end

  -- Monsters: one wild-Pokemon tool per species from data.pokemon (paints
  -- through Objects.placeObjectSpec with objectType = "mon").
  if selection == Picker.SPEC_MONSTER then
    local list = {}
    for _, sp in ipairs(Picker.speciesList(session)) do
      list[#list + 1] = {
        kind = "entity", entityType = "object",
        create = { objectType = "mon", sprite = Picker.speciesSprite(session, sp.id),
                   pokemon = sp.id, level = 5 },
        label = sp.id,
      }
    end
    return list
  end

  -- Items: one item-ball tool per data.items entry (paints through
  -- Objects.placeObjectSpec with objectType = "itemball"; the ball sprite is
  -- defaulted by the placer when the entry has no sheet of its own).
  if selection == Picker.SPEC_ITEMS then
    local list = {}
    local names = {}
    for k in pairs(data and data.items or {}) do
      names[#names + 1] = k
    end
    table.sort(names)
    for _, itemId in ipairs(names) do
      list[#list + 1] = {
        kind = "entity", entityType = "object",
        create = { objectType = "itemball", item = itemId },
        label = itemId,
      }
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
    -- Gen 2: stop before the trailing $00 filler metatile slots (see
    -- Common.effectiveBlockCount) instead of listing pages of dead tiles.
    local count = Common.effectiveBlockCount(ts)
    for i = 1, count do
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
  Panel.drawBg(ix, iy, iw, ih)

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

  local mx, my = love.mouse.getPosition()
  local list = Picker.itemList(session, selection)

  -- Big, high-contrast header; the active label is clipped to the panel.
  -- Hovering a named entry (species / item tool, sprite id) swaps the title
  -- for that name so virtual-catalog cells stay identifiable without chips.
  local pages = math.max(1, math.ceil(#list / Picker.perPage(vw, vh)))
  local baseLabel = Picker.isSpecial(selection)
    and Picker.label(session, selection) or "TILESETS"
  local headText = baseLabel .. " - pg " .. tostring(app.scroll or 1)
    .. "/" .. tostring(pages)
  local hoverItem = Picker.itemAt(vw, vh, mx, my, app.scroll or 1)
  if hoverItem then
    local it = list[hoverItem]
    local nm = it and (it.label
      or ((it.kind == "sprite" or it.kind == "item") and it.id) or nil)
    if nm then
      headText = nm .. " - pg " .. tostring(app.scroll or 1)
        .. "/" .. tostring(pages)
    end
  end
  local head = Panel.fitText(font, headText, iw - Panel.PAD * 2, 2)
  Panel.drawTitle(font, head, ix, iy)
  Panel.resetColor()

  -- Tileset dropdown: a single button showing the active catalog entry; the
  -- open list is drawn over the grid below.
  local dropX, dropY, dropW, dropH = Picker.dropRect(vw, vh)
  Panel.renderDropdownButton(font, activeLabel, dropX, dropY, dropW, dropH,
    mx, my, app.dropOpen)

  -- Grid for the active catalog.
  local cols = Picker.cols(vw, vh)
  local perPageItems = Picker.perPage(vw, vh)
  local gridStart = ((app.scroll or 1) - 1) * perPageItems

  local gx = ix + Panel.PAD
  local gy = iy + Picker.HEAD_H + 6
  local row = 0
  while gy + Picker.SLOT <= iy + ih and row < math.floor(perPageItems / cols) do
    for col = 0, cols - 1 do
      local slot = gridStart + row * cols + col + 1
      if slot > #list then break end
      local item = list[slot]
      love.graphics.setColor(Panel.COLOR_CELL_BG2[1], Panel.COLOR_CELL_BG2[2],
        Panel.COLOR_CELL_BG2[3], Panel.COLOR_CELL_BG2[4])
      love.graphics.rectangle("fill", gx, gy, Picker.SLOT, Picker.SLOT)
      Item.draw(session, item, gx + 2, gy + 2, Picker.SLOT - 4, thumbBundle)
      if hoverItem == slot then
        Panel.drawCellHover(gx, gy, Picker.SLOT)
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
    gx = ix + Panel.PAD
    gy = gy + Picker.SLOT + Picker.GAP
    row = row + 1
  end
  Panel.resetColor()

  -- Open tileset dropdown list (drawn over the grid).
  if app.dropOpen then
    local lx, ly, lw, lh = Picker.dropListRect(session, vw, vh)
    local per = Picker.dropPerPage(session, vw, vh)
    local pageStart = ((app.listScroll or 1) - 1) * per
    local hoverEntry = Picker.dropEntryAt(session, vw, vh, mx, my, app.listScroll or 1)
    local activeSel = selection or Picker.current(session)
    local entries = {}
    for i = 1, per do
      local idx = pageStart + i
      local cid = catalog[idx]
      if not cid then break end
      local isSel = (cid == activeSel) and not Picker.isSpecial(cid)
      if Picker.isSpecial(cid) and selection == cid then isSel = true end
      entries[i] = { label = Picker.label(session, cid), _sel = isSel }
    end
    local selIdx = nil
    for i, e in ipairs(entries) do
      if e._sel then selIdx = pageStart + i; break end
    end
    Panel.renderDropdownList(font, lx, ly, lw, lh,
      entries, 1, per, selIdx, hoverEntry, Picker.DROP_H)
  end
end

return Picker
