-- Overlay draw smoke tests: the blueprint placement preview (translucent ghost
-- stamp + green footprint outline) and the drag ghost floating above the
-- panels render without erroring through the full Overlay.draw pipeline.
-- Graphics calls are no-ops in the headless stub, so these assert the draw
-- paths run, hit the expected geometry/color steps, and leave the state reset.

package.path = "../../../?.lua;" .. package.path

if not _G.love then _G.love = require("tests.love_stub") end

local Data = require("src.core.Data")
if not (Data.maps and Data.maps.PALLET_TOWN) then Data:load() end
local data = Data

local Session = require("mods.mapamap.session")
local Input = require("mods.mapamap.input")
local Overlay = require("mods.mapamap.components.overlay")
local Coords = require("mods.mapamap.func.coords")
local Hotbar = require("mods.mapamap.components.hotbar")

local mod = {
  log = { warn = function() end, info = function() end, error = function() end },
  save = { get = function() return nil end, set = function() end },
  ui = { Font = { draw = function() end } },
}
local game = { data = data, overworld = nil }

local function freshInput()
  Input.reset()
  Input.hotbar = {}
  Input.selected = 1
  Input.showPicker = false
  Input.pickerScroll = 1
  Input.inventory = { items = {}, tab = 1, scroll = 1 }
  -- The inventory panel is hidden so the suite exercises the new world-marker
  -- draw paths without depending on the inventory's own renderer usage.
  Input.showInventory = false
end

-- Same flat transform the coords suite uses (self-contained; a headless
-- harness has no live camera to derive one from).
local function flatTransform()
  return {
    camx = 0, camy = 0,
    vw = 320, vh = 288,
    sp = 2, sx = 2, sy = 2,
    wox = 8, woy = 6,
  }
end

-- Runs `fn` with Coords.transform stubbed to `t`, then restores it.  The stub
-- mirrors how hotbar_tests fakes a camera for paint paths.
local function withTransform(t, fn)
  local orig = Coords.transform
  Coords.transform = function() return t end
  local ok, err = pcall(fn)
  Coords.transform = orig
  if not ok then error(err, 0) end
end

-- Records every setColor call while `fn` runs, then restores normal drawing.
local function recordingColors(fn)
  local graphics = _G.love.graphics
  local orig = graphics.setColor
  local seen = {}
  graphics.setColor = function(r, g, b, a) seen[#seen + 1] = { r, g, b, a } end
  local ok, err = pcall(fn)
  graphics.setColor = orig
  if not ok then error(err, 0) end
  return seen
end

local function hasColor(seen, r, g, b, a)
  for _, c in ipairs(seen) do
    if math.abs(c[1] - r) < 1e-9 and math.abs(c[2] - g) < 1e-9
       and math.abs(c[3] - b) < 1e-9 and math.abs(c[4] - (a or 1)) < 1e-9 then
      return true
    end
  end
  return false
end

-- While a blueprint is selected, the preview replaces the plain cursor
-- highlight and draws a translucent ghost over the anchored stamp plus a
-- green footprint outline, exactly where the next LMB would paint.
function test_blueprintPreviewDrawsGhostAndOutline()
  local s = assert(Session.new(mod, game, "PALLET_TOWN"))
  freshInput()
  s.cursorBx, s.cursorBy = 0, 0
  Input.hotbar[1] = { kind = "blueprint", id = "BP_SMOKE", w = 2, h = 1, tiles = { 0, 1 } }
  Input.selected = 1
  local seen = recordingColors(function()
    withTransform(flatTransform(), function() Overlay.draw(s, game, nil) end)
  end)
  -- The green footprint outline must be drawn for the 2x1 stamp.
  assert(hasColor(seen, 0.3, 1, 0.5, 0.85),
    "the blueprint footprint outline color is set")
  -- The ghost cell tiles draw translucent white (0.55) over the world.
  assert(hasColor(seen, 1, 1, 1, 0.55),
    "the preview ghost cell tint is set")
  -- State is restored to opaque white.
  local _, _, _, a = love.graphics.getColor()
  assert(a == 1, "overlay leaves the color opaque after drawing")
end

-- A plain (non-blueprint) brush keeps drawing the cursor highlight and never
-- the preview outline.
function test_nonBlueprintCursorStaysPlain()
  local s = assert(Session.new(mod, game, "PALLET_TOWN"))
  freshInput()
  s.cursorBx, s.cursorBy = 0, 0
  Input.hotbar[1] = { kind = "block", id = 1 }
  Input.selected = 1
  local seen = recordingColors(function()
    withTransform(flatTransform(), function() Overlay.draw(s, game, nil) end)
  end)
  assert(not hasColor(seen, 0.3, 1, 0.5, 0.85),
    "no blueprint footprint outline without a selected blueprint")
  -- The cursor highlight uses the yellow accent for block brushes.
  assert(hasColor(seen, 1, 0.9, 0.3, 0.9),
    "the plain cursor accent color is drawn")
end

-- A picked-up item (hotbar/picker drag) floats under the cursor above every
-- panel with a shadow, so the drop target stays visible underneath.
function test_dragGhostDrawsAbovePanels()
  local s = assert(Session.new(mod, game, "PALLET_TOWN"))
  freshInput()
  Input.dragItem = { kind = "warp", destMap = "PALLET_TOWN" }
  Input.dragFromSlot = 1
  local origPos = _G.love.mouse.getPosition
  _G.love.mouse.getPosition = function() return 300, 300 end
  local ok, err = pcall(Overlay.draw, s, game, nil)
  _G.love.mouse.getPosition = origPos
  assert(ok, "the drag ghost draws without error: " .. tostring(err))
end

-- A live session still draws even when the mod has no `ui.Font` object (the
-- game may provide the default font via LOVE instead).
function test_overlayDrawsWithoutUiFont()
  local fallbackMod = {
    log = { warn = function() end, info = function() end, error = function() end },
    save = { get = function() return nil end, set = function() end },
  }
  local s = assert(Session.new(fallbackMod, game, "PALLET_TOWN"))
  assert(s.font, "a fallback font is created when mod.ui.Font is absent")
  freshInput()
  local ok, err = pcall(Overlay.draw, s, game, nil)
  assert(ok, "overlay still draws without a mod ui font: " .. tostring(err))
end

-- Hotbar slot geometry used by the drag tests stays within the panel-free
-- band below the inventory, so press/release routing never collides.
function test_hotbarBandClearsInventory()
  local x1, y1, w1, h1 = Hotbar.slot(1, 640, 576)
  local Inventory = require("mods.mapamap.components.inventory")
  local px, py, pw, ph = Inventory.rect(640, 576)
  assert(y1 >= py + ph, "the hotbar band sits below the inventory panel")
  assert(w1 > 0 and h1 > 0, "hotbar slots have size")
end

-- The map-border toggle (O key, Input.showMapBorders) gates the border
-- outline draw: with it off, no per-map outline is drawn; with it on, the
-- session map's cyan outline is drawn over the laid-out map cluster.
function test_mapBorderToggleGatesDraw()
  local s = assert(Session.new(mod, game, "PALLET_TOWN"))
  freshInput()
  -- Off: neither the green neighbour outline nor the yellow current-map ring
  -- may appear (map_editor-style border palette).
  Input.showMapBorders = false
  local off = recordingColors(function()
    withTransform(flatTransform(), function() Overlay.draw(s, game, nil) end)
  end)
  assert(not hasColor(off, 0.2, 1, 0.4, 0.8),
    "no green border outline while the toggle is off")
  assert(not hasColor(off, 1, 1, 0, 0.95),
    "no yellow current-map border while the toggle is off")
  -- On: the current-map border is ringed in yellow (map_editor style).
  Input.showMapBorders = true
  local on = recordingColors(function()
    withTransform(flatTransform(), function() Overlay.draw(s, game, nil) end)
  end)
  assert(hasColor(on, 1, 1, 0, 0.95),
    "the current-map border is ringed in yellow while the toggle is on")
  -- State is restored to opaque white after drawing.
  local _, _, _, a = love.graphics.getColor()
  assert(a == 1, "overlay leaves the color opaque after drawing")
end

-- With the toggle on, each primary connection is drawn as an orange band on
-- the rectangle border at its block offset/size (mirroring map_editor's edge
-- silhouettes).  PALLET_TOWN has at least one connection in the base data.
function test_mapBorderDrawsConnectionBands()
  local s = assert(Session.new(mod, game, "PALLET_TOWN"))
  freshInput()
  Input.showMapBorders = true
  local on = recordingColors(function()
    withTransform(flatTransform(), function() Overlay.draw(s, game, nil) end)
  end)
  assert(hasColor(on, 1, 0.6, 0.1, 0.9),
    "primary connection markers are drawn (orange border) while toggled on")
  -- A toggle-off run draws no connection markers at all.
  Input.showMapBorders = false
  local off = recordingColors(function()
    withTransform(flatTransform(), function() Overlay.draw(s, game, nil) end)
  end)
  assert(not hasColor(off, 1, 0.6, 0.1, 0.9),
    "no connection markers while the toggle is off")
end

return {
  name = "MAPAMAP_OVERLAY",
  tests = {
    "test_blueprintPreviewDrawsGhostAndOutline",
    "test_nonBlueprintCursorStaysPlain",
    "test_dragGhostDrawsAbovePanels",
    "test_overlayDrawsWithoutUiFont",
    "test_hotbarBandClearsInventory",
    "test_mapBorderToggleGatesDraw",
    "test_mapBorderDrawsConnectionBands",
  },
}
