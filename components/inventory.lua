-- Inventory component: the persistent Factorio-style panel along the left
-- edge of the screen.  It holds every placeable collected while editing --
-- blocks (tiles), objects (sprites/items), warps, and captured blueprints --
-- in a scrollable grid organised into category tabs.
--
-- The panel is always visible while the overlay is open.  A click on an
-- inventory cell loads that item into the active hotbar slot (the same
-- selection surface used by painting); blueprint captures and picker
-- drag-drops land here instead of a separate blueprint bar.
--
-- This module owns all inventory geometry (panel, tabs, grid cells) and the
-- draw routine, mirroring the Hotbar/Picker component style.  Input queries
-- it for hit-testing; the overlay orchestrator only calls Inventory.draw.

local Hotbar = require("mods.mapamap.components.hotbar")
local Item = require("mods.mapamap.components.item")
local Panel = require("mods.mapamap.components.panel")
local Text = require("mods.mapamap.components.text")

local Inventory = {}

Inventory.SLOT = 40          -- square cell size (a bit smaller than the hotbar)
Inventory.GAP = 6
Inventory.COLS = 10          -- fixed column count for the item grid
Inventory.SIDE_GAP = 10      -- gap between the inventory and the side panel

Inventory.TABS = {
  { key = "tiles", label = "Tiles" },
  { key = "entities", label = "Entities" },
  { key = "blueprints", label = "Blueprints" },
  { key = "brushes", label = "Brushes" },
}

-- Toolbar shortcut pinned to the FIRST grid slot of every tab, one letter
-- per tab in TABS order: [E] tileset picker on Tiles, [F] entity factory on
-- Entities, [R] blueprint rect-select on Blueprints, [M] Brush Maker on
-- Brushes.  The cell's action follows its tab (letters draw in caps).
Inventory.SHORTCUTS = { "e", "f", "r", "m" }

-- The tab an item belongs to, by kind.
function Inventory.tabFor(item)
  local k = item and item.kind
  if k == "block" then return 1 end
  if k == "entity" or k == "sprite" or k == "item" then return 2 end
  if k == "blueprint" then return 3 end
  if k == "brush" then return 4 end
  return 2
end

-- The top of the panel is pinned just above the hotbar band so the inventory
-- never covers the slot strip.
local function hotbarTop(vh)
  return vh - Hotbar.SLOT - Hotbar.PAD - Hotbar.GAP
end

-- How many item rows fit above the hotbar.
function Inventory.rows(vh)
  local top = 8 -- clearance above the panel keeps it inside the window
  local avail = hotbarTop(vh) - top - Panel.PAD - Panel.TITLE_H
                - Panel.TITLE_GAP - Panel.TAB_H - Inventory.GAP
  return math.max(1, math.floor(avail / (Inventory.SLOT + Inventory.GAP)))
end

-- Overall panel rect (left-aligned, bottom clamped above the hotbar).
function Inventory.rect(vw, vh)
  local rows = Inventory.rows(vh)
  local w = Panel.PAD * 2 + Inventory.COLS * Inventory.SLOT
            + (Inventory.COLS - 1) * Inventory.GAP
  local h = Panel.PAD + Panel.TITLE_H + Panel.TITLE_GAP
            + Panel.TAB_H + Inventory.GAP
            + rows * Inventory.SLOT + (rows - 1) * Inventory.GAP
  local y = hotbarTop(vh) - h
  if y < 8 then y = 8 end
  return Panel.PAD, y, w, h
end

-- The full panel size (w, h).  The side panels (tileset picker, blueprint
-- book) are the same size and sit directly to the right of the inventory.
function Inventory.dim(vw, vh)
  local _, _, w, h = Inventory.rect(vw, vh)
  return w, h
end

-- The rect for the panel of equal size sitting at the inventory's right.
function Inventory.sideRect(vw, vh)
  local x, y, w, h = Inventory.rect(vw, vh)
  return x + w + Inventory.SIDE_GAP, y, w, h
end

-- Number of slots on one inventory page.
function Inventory.perPage(vw, vh)
  return Inventory.COLS * Inventory.rows(vh)
end

-- Content slots per page: the leading toolbar shortcut occupies the first
-- grid slot of every page, so each page carries one fewer collection cell.
function Inventory.contentPerPage(vw, vh)
  return math.max(1, Inventory.perPage(vw, vh) - 1)
end

-- Bounding rect of a tab button: delegates to Panel.tabRect with the
-- inventory's tabs.  The tabs sit below the title, so panelY is offset.
function Inventory.tabRect(vw, vh, i, font)
  local px, py = Inventory.rect(vw, vh)
  return Panel.tabRect(Inventory.TABS, px, Panel.titleBottom(py), font, i)
end

-- Which tab button (1..n) a screen point is over, or nil.
function Inventory.tabAt(vw, vh, mx, my, font)
  local px, py = Inventory.rect(vw, vh)
  return Panel.tabAt(Inventory.TABS, px, Panel.titleBottom(py), font, mx, my)
end

-- True when a screen point is inside the inventory panel (used to consume
-- clicks/wheel so they never fall through to the world underneath).
function Inventory.over(vw, vh, mx, my)
  return Panel.over(Inventory.rect, vw, vh, mx, my)
end

-- The raw within-page grid slot (row-major, 1-based) under (mx,my), or nil.
local function gridSlotAt(vw, vh, mx, my)
  local px, py, pw, ph = Inventory.rect(vw, vh)
  if mx < px or mx >= px + pw or my < py or my >= py + ph then return nil end
  local gx = mx - px - Panel.PAD
  local gy = my - py - Panel.PAD - Panel.TITLE_H - Panel.TITLE_GAP
             - Panel.TAB_H - Inventory.GAP
  if gx < 0 then return nil end
  local col = math.floor(gx / (Inventory.SLOT + Inventory.GAP))
  local row = math.floor(gy / (Inventory.SLOT + Inventory.GAP))
  if col >= Inventory.COLS or row < 0 then return nil end
  return row * Inventory.COLS + col + 1
end

-- The toolbar shortcut under (mx,my): the first grid slot of the panel.
-- Its action follows the ACTIVE tab (input.lua dispatches on it).
function Inventory.shortcutAt(vw, vh, mx, my)
  local g = gridSlotAt(vw, vh, mx, my)
  if g and g == 1 then return g end
  return nil
end

-- The absolute content index (1-based over the tab's filtered list) under
-- (mx,my), or nil.  The first grid slot is the tab's toolbar shortcut and
-- is not content.
function Inventory.itemAt(vw, vh, mx, my, scroll)
  local g = gridSlotAt(vw, vh, mx, my)
  if not g or g <= 1 then return nil end
  local pageStart = ((scroll or 1) - 1) * Inventory.contentPerPage(vw, vh)
  return pageStart + g - 1
end

-- The filtered item list for the active tab.  `items` is the full inventory
-- array; `tab` a tab index (1..4).
function Inventory.listFor(items, tab)
  local out = {}
  for _, it in ipairs(items or {}) do
    if Inventory.tabFor(it) == tab then out[#out + 1] = it end
  end
  return out
end

-- The panel's display list for the active tab: only the saved collection.
-- Live current-map content is owned by separate components.
function Inventory.tabList(session, state)
  local tab = (state and state.tab) or 1
  return Inventory.listFor(state and state.items, tab)
end

-- Adds an item to the inventory, switching to its tab and scrolling so the
-- newest entry is visible.  Pass opts.silent to file the item without moving
-- the view: it only shows on its respective tab when that tab is opened.
function Inventory.add(ui, item, opts)
  if not item then return end
  table.insert(ui.inventory.items, item)
  if opts and opts.silent then return end
  local tabIdx = Inventory.tabFor(item)
  ui.inventory.tab = tabIdx
  local vw, vh = love.graphics.getDimensions()
  local list = Inventory.listFor(ui.inventory.items, tabIdx)
  local per = Inventory.contentPerPage(vw, vh)
  ui.inventory.scroll = math.max(1, math.ceil(#list / per))
end

-- The filtered inventory list for the active tab of the UI controller state.
function Inventory.list(ui)
  return Inventory.listFor(ui.inventory.items, ui.inventory.tab)
end

-- ---------------------------------------------------------------------------
-- Draw

-- Draws one toolbar shortcut cell: the key letter big on a light chip with
-- the tab's name under it (shrunk until it fits the cell).
local function drawShortcut(session, font, key, name, cellX, cellY, hovered)
  love.graphics.setColor(Panel.COLOR_CELL_BG2[1], Panel.COLOR_CELL_BG2[2],
    Panel.COLOR_CELL_BG2[3], Panel.COLOR_CELL_BG2[4])
  love.graphics.rectangle("fill", cellX, cellY, Inventory.SLOT, Inventory.SLOT)
  if font then
    key = key:upper()
    local kw = ((font.width and font.width(key)) or #key * 8) * 2
    Text.label(font, key, cellX + (Inventory.SLOT - kw) / 2, cellY + 5, 2,
      { bg = { 0.85, 0.88, 0.92, 0.95 } })
    while #name > 1
        and ((font.width and font.width(name)) or #name * 8) > Inventory.SLOT - 8 do
      name = name:sub(1, -2)
    end
    local nw = (font.width and font.width(name)) or #name * 8
    Text.label(font, name, cellX + (Inventory.SLOT - nw) / 2,
      cellY + Inventory.SLOT - 13, 1,
      { bg = { 0.85, 0.88, 0.92, 0.95 }, padY = 0 })
  end
  if hovered then Panel.drawCellHover(cellX, cellY, Inventory.SLOT) end
end

-- Draws the panel.  `state` carries the Input-owned UI state
-- { items, tab, scroll } and `selectedItem` is the active hotbar item (for
-- the selection ring).  Styling matches the tileset picker.
function Inventory.draw(session, state, vw, vh, font, selectedItem)
  local tab = (state and state.tab) or 1
  local list = Inventory.tabList(session, state)
  local px, py, pw, ph = Inventory.rect(vw, vh)

  Panel.drawBg(px, py, pw, ph, 0.85)

  Panel.drawTitle(font, "INVENTORY", px, py)

  local mx, my = love.mouse.getPosition()
  Panel.drawTabs(Inventory.TABS, px, Panel.titleBottom(py),
    font, tab, mx, my)
  Panel.resetColor()

  -- Item grid: the tab's shortcut in the first cell, then this page's
  -- slice of the list.
  local cpp = Inventory.contentPerPage(vw, vh)
  local pageStart = ((state.scroll or 1) - 1) * cpp
  local gx = px + Panel.PAD
  local gy = Panel.titleBottom(py) + Panel.PAD + Panel.TAB_H + Inventory.GAP
  local hoverSlot = gridSlotAt(vw, vh, mx, my)
  local shortKey = Inventory.SHORTCUTS[tab] or "e"
  local shortName = Inventory.TABS[tab] and Inventory.TABS[tab].label or ""

  for row = 0, Inventory.rows(vh) - 1 do
    for col = 0, Inventory.COLS - 1 do
      local slot = row * Inventory.COLS + col + 1
      local cellX = gx + col * (Inventory.SLOT + Inventory.GAP)
      local cellY = gy + row * (Inventory.SLOT + Inventory.GAP)
      if slot == 1 then
        drawShortcut(session, font, shortKey, shortName, cellX, cellY,
          hoverSlot == 1)
      else
        local item = list[pageStart + slot - 1]
        love.graphics.setColor(Panel.COLOR_CELL_BG[1], Panel.COLOR_CELL_BG[2],
          Panel.COLOR_CELL_BG[3], Panel.COLOR_CELL_BG[4])
        love.graphics.rectangle("fill", cellX, cellY, Inventory.SLOT, Inventory.SLOT)
        if item then
          local pad = 2
          Item.draw(session, item, cellX + pad, cellY + pad, Inventory.SLOT - pad * 2)
          if hoverSlot == slot then
            Panel.drawCellHover(cellX, cellY, Inventory.SLOT)
          elseif selectedItem == item then
            love.graphics.setColor(1, 0.3, 0.3, 0.8)
            love.graphics.rectangle("line", cellX - 1, cellY - 1,
              Inventory.SLOT + 2, Inventory.SLOT + 2)
          end
        end
      end
    end
  end
  Panel.resetColor()
end

return Inventory
