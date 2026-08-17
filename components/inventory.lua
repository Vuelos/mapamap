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
local Text = require("mods.mapamap.components.text")

local Inventory = {}

Inventory.PAD = 8
Inventory.SLOT = 40          -- square cell size (a bit smaller than the hotbar)
Inventory.GAP = 6
Inventory.TAB_H = 24         -- category tab row height (scaled text fits)
Inventory.TAB_GAP = 4        -- spacing between the per-text tab buttons
Inventory.TAB_PAD_X = 1      -- button padding around the scaled label
Inventory.COLS = 10          -- fixed column count for the item grid
Inventory.SIDE_GAP = 10      -- gap between the inventory and the side panel

Inventory.TABS = {
  { key = "tiles", label = "Tiles" },
  { key = "objects", label = "Objects" },
  { key = "warps", label = "Warps" },
  { key = "blueprints", label = "Blueprints" },
}

-- The tab an item belongs to, by kind.
function Inventory.tabFor(item)
  local k = item and item.kind
  if k == "block" then return 1 end
  if k == "sprite" or k == "item" then return 2 end
  if k == "warp" then return 3 end
  if k == "blueprint" then return 4 end
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
  local avail = hotbarTop(vh) - top - Inventory.PAD - Inventory.TAB_H - Inventory.GAP
  return math.max(1, math.floor(avail / (Inventory.SLOT + Inventory.GAP)))
end

-- Overall panel rect (left-aligned, bottom clamped above the hotbar).
function Inventory.rect(vw, vh)
  local rows = Inventory.rows(vh)
  local w = Inventory.PAD * 2 + Inventory.COLS * Inventory.SLOT
            + (Inventory.COLS - 1) * Inventory.GAP
  local h = Inventory.PAD + Inventory.TAB_H + Inventory.GAP
            + rows * Inventory.SLOT + (rows - 1) * Inventory.GAP
  local y = hotbarTop(vh) - h
  if y < 8 then y = 8 end
  return Inventory.PAD, y, w, h
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

-- Scaled (2x) width of a tab label in screen units, matching Text.label's
-- width math so the button hugs the drawn chip (fonts without a `width`
-- method fall back to the same #glyphs * 8 estimate).
function Inventory.labelWidth(font, label)
  local glyphW = (font and font.width and font.width(label)) or (#tostring(label) * 8)
  return glyphW * 2
end

-- Bounding rect of a tab button: each button is sized to its label's text
-- width (plus padding), and the buttons sit side by side with a small gap.
function Inventory.tabRect(vw, vh, i, font)
  if i < 1 or i > #Inventory.TABS then return nil end
  local px, py, _, _ = Inventory.rect(vw, vh)
  local x = px + Inventory.PAD
  for j = 1, i - 1 do
    x = x + Inventory.labelWidth(font, Inventory.TABS[j].label)
          + Inventory.TAB_PAD_X * 2 + Inventory.TAB_GAP
  end
  local w = Inventory.labelWidth(font, Inventory.TABS[i].label)
            + Inventory.TAB_PAD_X * 2
  return x, py + Inventory.PAD, w, Inventory.TAB_H
end

-- Which tab button (1..n) a screen point is over, or nil.
function Inventory.tabAt(vw, vh, mx, my, font)
  for i = 1, #Inventory.TABS do
    local x, y, w, h = Inventory.tabRect(vw, vh, i, font)
    if mx >= x and mx < x + w and my >= y and my < y + h then return i end
  end
  return nil
end

-- True when a screen point is inside the inventory panel (used to consume
-- clicks/wheel so they never fall through to the world underneath).
function Inventory.over(vw, vh, mx, my)
  local px, py, pw, ph = Inventory.rect(vw, vh)
  return mx >= px and mx < px + pw and my >= py and my < py + ph
end

-- Absolute grid slot index (1-based, page-aware) under (mx,my), or nil.
-- `scroll` is a page number (1-based) into the filtered list.
function Inventory.itemAt(vw, vh, mx, my, scroll)
  local px, py, pw, ph = Inventory.rect(vw, vh)
  if mx < px or mx >= px + pw or my < py or my >= py + ph then return nil end
  local gx = mx - px - Inventory.PAD
  local gy = my - py - Inventory.PAD - Inventory.TAB_H - Inventory.GAP
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
-- For Objects and Warps tabs, templates are always shown first.
function Inventory.tabList(session, state)
  local tab = (state and state.tab) or 1
  local items = state and state.items
  local list = Inventory.listFor(items, tab)
  
  -- For Objects tab (2) and Warps tab (3), sort to show templates first
  if tab == 2 or tab == 3 then
    local templates = {}
    local others = {}
    for _, item in ipairs(list) do
      if (tab == 2 and item.newObject) or (tab == 3 and item.newWarp) then
        table.insert(templates, item)
      else
        table.insert(others, item)
      end
    end
    -- Return templates first, then other items
    for _, item in ipairs(others) do
      table.insert(templates, item)
    end
    return templates
  end
  
  return list
end

-- Adds an item to the inventory, switching to its tab and scrolling so the
-- newest entry is visible.
function Inventory.add(ui, item)
  if not item then return end
  table.insert(ui.inventory.items, item)
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

  love.graphics.setColor(0, 0, 0, 0.85)
  love.graphics.rectangle("fill", px, py, pw, ph)
  love.graphics.setColor(0.55, 0.55, 0.6, 0.5)
  love.graphics.rectangle("line", px, py, pw, ph)

  -- Tab row: single light chip per tab (no dark button rectangle behind it);
  -- the active tab gets a blue outline so the selected category still reads.
  local mx, my = love.mouse.getPosition()
  local hoverTab = Inventory.tabAt(vw, vh, mx, my, font)
  for i = 1, #Inventory.TABS do
    local x, y, w, h = Inventory.tabRect(vw, vh, i)
    Text.label(font, Inventory.TABS[i].label, x + 4, y + 3, 2, {
      bg = { 0.92, 0.92, 0.95, 0.95 }, padX = 2, padY = 1,
    })
    if i == tab then
      love.graphics.setColor(0.25, 0.5, 1, 0.9)
      love.graphics.rectangle("line", x + 1, y + 1, w - 2, h - 2)
    elseif hoverTab == i then
      love.graphics.setColor(1, 1, 1, 0.9)
      love.graphics.rectangle("line", x + 1, y + 1, w - 2, h - 2)
    end
  end

  -- Item grid.
  local perPage = Inventory.perPage(vw, vh)
  local pageStart = ((state.scroll or 1) - 1) * perPage
  local gx = px + Inventory.PAD
  local gy = py + Inventory.PAD + Inventory.TAB_H + Inventory.GAP
  local hoverIdx = Inventory.itemAt(vw, vh, mx, my, state.scroll or 1)

  for row = 0, Inventory.rows(vh) - 1 do
    for col = 0, Inventory.COLS - 1 do
      local slot = pageStart + row * Inventory.COLS + col + 1
      local cellX = gx + col * (Inventory.SLOT + Inventory.GAP)
      local cellY = gy + row * (Inventory.SLOT + Inventory.GAP)
      local item = list[slot]
      love.graphics.setColor(0.2, 0.2, 0.24, 0.9)
      love.graphics.rectangle("fill", cellX, cellY, Inventory.SLOT, Inventory.SLOT)
      if item then
        local pad = 2
        Item.draw(session, item, cellX + pad, cellY + pad, Inventory.SLOT - pad * 2)
        if hoverIdx == slot then
          love.graphics.setColor(1, 1, 1, 0.95)
          love.graphics.rectangle("line", cellX - 1, cellY - 1,
            Inventory.SLOT + 2, Inventory.SLOT + 2)
        elseif selectedItem == item then
          love.graphics.setColor(1, 0.3, 0.3, 0.8)
          love.graphics.rectangle("line", cellX - 1, cellY - 1,
            Inventory.SLOT + 2, Inventory.SLOT + 2)
        end
      end
    end
  end
  love.graphics.setColor(1, 1, 1, 1)
end

return Inventory
