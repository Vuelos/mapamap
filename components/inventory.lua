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

-- Absolute grid slot index (1-based, page-aware) under (mx,my), or nil.
-- `scroll` is a page number (1-based) into the filtered list.
function Inventory.itemAt(vw, vh, mx, my, scroll)
  local px, py, pw, ph = Inventory.rect(vw, vh)
  if mx < px or mx >= px + pw or my < py or my >= py + ph then return nil end
  local gx = mx - px - Panel.PAD
  local gy = my - py - Panel.PAD - Panel.TITLE_H - Panel.TITLE_GAP
             - Panel.TAB_H - Inventory.GAP
  if gx < 0 then return nil end
  local col = math.floor(gx / (Inventory.SLOT + Inventory.GAP))
  local row = math.floor(gy / (Inventory.SLOT + Inventory.GAP))
  if col >= Inventory.COLS or row < 0 then return nil end
  local pageStart = ((scroll or 1) - 1) * Inventory.perPage(vw, vh)
  return pageStart + row * Inventory.COLS + col + 1
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

-- The panel's display list for the active tab. Inventory is only the saved
-- collection; live current-map content is owned by separate components.
-- For Entities tab (2), templates are always shown first.
function Inventory.tabList(session, state)
  local tab = (state and state.tab) or 1
  local items = state and state.items
  local list = Inventory.listFor(items, tab)
  
  -- For Entities tab (2), sort to show templates first
  if tab == 2 then
    local templates = {}
    local others = {}
    for _, item in ipairs(list) do
      if item.kind == "entity" and (item.newWarp or item.newObject or item.newSign) then
        table.insert(templates, item)
      else
        table.insert(others, item)
      end
    end
    for _, item in ipairs(others) do
      table.insert(templates, item)
    end
    return templates
  end
  
  return list
end

-- Adds an item to the inventory, switching to its tab and scrolling so the
-- newest entry is visible.  Template items (newWarp / newObject / newSign) are
-- always inserted as the first element of their tab.
function Inventory.add(ui, item)
  if not item then return end
  local isTemplate = item.newWarp or item.newObject or item.newSign
  if isTemplate then
    -- Find the first item belonging to the same tab and insert before it
    -- so the template is always first in that tab's filtered list.
    local tabIdx = Inventory.tabFor(item)
    local insertPos = 1
    for i, it in ipairs(ui.inventory.items) do
      if Inventory.tabFor(it) == tabIdx then
        insertPos = i
        break
      end
      insertPos = i + 1
    end
    table.insert(ui.inventory.items, insertPos, item)
  else
    table.insert(ui.inventory.items, item)
  end
  local tabIdx = Inventory.tabFor(item)
  ui.inventory.tab = tabIdx
  local vw, vh = love.graphics.getDimensions()
  local list = Inventory.listFor(ui.inventory.items, tabIdx)
  local per = Inventory.perPage(vw, vh)
  ui.inventory.scroll = math.max(1, math.ceil(#list / per))
end

-- The filtered inventory list for the active tab of the UI controller state.
function Inventory.list(ui)
  return Inventory.listFor(ui.inventory.items, ui.inventory.tab)
end

-- ---------------------------------------------------------------------------
-- Draw

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

  -- Item grid.
  local perPage = Inventory.perPage(vw, vh)
  local pageStart = ((state.scroll or 1) - 1) * perPage
  local gx = px + Panel.PAD
  local gy = Panel.titleBottom(py) + Panel.PAD + Panel.TAB_H + Inventory.GAP
  local hoverIdx = Inventory.itemAt(vw, vh, mx, my, state.scroll or 1)

  for row = 0, Inventory.rows(vh) - 1 do
    for col = 0, Inventory.COLS - 1 do
      local slot = pageStart + row * Inventory.COLS + col + 1
      local cellX = gx + col * (Inventory.SLOT + Inventory.GAP)
      local cellY = gy + row * (Inventory.SLOT + Inventory.GAP)
      local item = list[slot]
      love.graphics.setColor(Panel.COLOR_CELL_BG[1], Panel.COLOR_CELL_BG[2],
        Panel.COLOR_CELL_BG[3], Panel.COLOR_CELL_BG[4])
      love.graphics.rectangle("fill", cellX, cellY, Inventory.SLOT, Inventory.SLOT)
      if item then
        local pad = 2
        Item.draw(session, item, cellX + pad, cellY + pad, Inventory.SLOT - pad * 2)
        if hoverIdx == slot then
          Panel.drawCellHover(cellX, cellY, Inventory.SLOT)
        elseif selectedItem == item then
          love.graphics.setColor(1, 0.3, 0.3, 0.8)
          love.graphics.rectangle("line", cellX - 1, cellY - 1,
            Inventory.SLOT + 2, Inventory.SLOT + 2)
        end
      end
    end
  end
  Panel.resetColor()
end

return Inventory
