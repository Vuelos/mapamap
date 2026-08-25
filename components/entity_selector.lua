-- Entity Selector panel: the first half of the entity creation workflow.
--
-- A side panel listing every basic entity the editor can create -- NPC,
-- item ball, battler (trainer), wild mon, sign, warp, encounter -- as one
-- labelled button per row.  Clicking a button opens the Entity Creator panel
-- (components/entity_creator.lua) pre-loaded with that type's required-data
-- form; ENCOUNTER routes straight into the existing encounter editor since
-- encounters are map-level data, not world placements.
--
-- Geometry mirrors the other side panels: same box as the tileset picker /
-- Details / encounter editor (Inventory.sideRect), so only one of them is
-- open at a time.  Input queries it for hit-testing; the overlay orchestrator
-- only calls EntitySelector.draw.

local Inventory = require("mods.mapamap.components.inventory")
local Panel = require("mods.mapamap.components.panel")
local Text = require("mods.mapamap.components.text")
local Gen = require("mods.mapamap.engine.gen")

local EntitySelector = {}

-- The creatable entity catalog.  `key` names the creator form to open;
-- `label` is the button caption; `desc` is the hint-bar blurb; `gen` gates
-- generation-specific entries ("gen1"/"gen2" -- nil means both).  Encounters
-- are deliberately NOT here (map-level data, not world placements): they
-- stay on their own N/toolbar surface.
EntitySelector.TYPES = {
  { key = "npc",       label = "NPC",        desc = "plain overworld person" },
  { key = "item",      label = "ITEM BALL",  desc = "pickable item ball" },
  { key = "hiddenitem", label = "HIDDEN ITEM", desc = "invisible item ball" },
  { key = "battler",   label = "TRAINER",    desc = "trainer that battles you" },
  { key = "mon",       label = "WILD MON",   desc = "static pokemon encounter" },
  { key = "shop",      label = "SHOP",       desc = "poke mart with editable items" },
  { key = "sign",      label = "SIGN",       desc = "readable sign" },
  { key = "warp",      label = "WARP",       desc = "map-to-map warp" },
  { key = "boulder",   label = "BOULDER",    desc = "strength-pushable boulder" },
  { key = "headbutt",  label = "HEADBUTT TREE", gen = "gen2",
    desc = "paints a headbutt-able tree block" },
  { key = "blocker",   label = "SLEEPING MON", gen = "gen1",
    desc = "sleeping mon; needs POKe FLUTE; catchable battle" },
  { key = "berrytree", label = "BERRY TREE", gen = "gen2",
    desc = "daily berry hand-out" },
  { key = "pc",        label = "PC",         desc = "player character marker" },
  { key = "healing",   label = "HEALING",    desc = "healing point with pre/post text" },
}

-- The types creatable in THIS run's generation, in order.
function EntitySelector.visibleTypes()
  local gen2 = Gen.isGen2()
  local out = {}
  for _, t in ipairs(EntitySelector.TYPES) do
    if (t.gen == "gen2") == gen2 or t.gen == nil then
      out[#out + 1] = t
    end
  end
  return out
end

-- The full catalog row backing visibleTypes()[i] (button indices are
-- per-generation, so hit-tests resolve through this).
function EntitySelector.typeAt(index, gen2)
  local seen = 0
  for _, t in ipairs(EntitySelector.TYPES) do
    if (t.gen == "gen2") == (gen2 == true) or t.gen == nil then
      seen = seen + 1
      if seen == index then return t end
    end
  end
  return nil
end

function EntitySelector.rect(vw, vh)
  return Inventory.sideRect(vw, vh)
end

function EntitySelector.over(vw, vh, mx, my)
  return Panel.over(EntitySelector.rect, vw, vh, mx, my)
end

-- Row top Y (below the title chip), matching the Details panel's rhythm.
local function rowTopY(y)
  return y + Panel.PAD + 20
end

-- The type index whose button row a screen point falls over, or nil.
function EntitySelector.buttonAt(vw, vh, mx, my)
  local x, y, w, h = EntitySelector.rect(vw, vh)
  if mx < x or mx >= x + w or my < y or my >= y + h then return nil end
  local n = math.floor((my - rowTopY(y)) / (Panel.ROW_H + 6)) + 1
  if n < 1 or n > #EntitySelector.visibleTypes() then return nil end
  return n
end

-- Draws the selector panel.  Purely visual: click routing lives in the input
-- dispatcher so the creator-open side effect stays next to its siblings.
function EntitySelector.draw(session, vw, vh, font)
  local x, y, w, h = EntitySelector.rect(vw, vh)
  Panel.drawBg(x, y, w, h)
  Panel.drawTitle(font, "NEW ENTITY", x, y)

  local mx, my = love.mouse.getPosition()
  local types = EntitySelector.visibleTypes()
  local hoverIdx = EntitySelector.buttonAt(vw, vh, mx, my)
  local top = rowTopY(y)
  for i, t in ipairs(types) do
    local ry = top + (i - 1) * (Panel.ROW_H + 6)
    Text.label(font, t.label, x + Panel.PAD + 4, ry + 3, 2, {
      bg = Panel.CHIP_VALUE, padX = 3, padY = 2,
    })
    if hoverIdx == i then
      Panel.drawHover(x + 2, ry - 3, w - 4, Panel.ROW_H)
    end
  end

  local desc = hoverIdx and types[hoverIdx].desc or nil
  Panel.drawHint(font, desc or "Click a type to configure it", x, y, w, h)
  Panel.resetColor()
end

return EntitySelector
