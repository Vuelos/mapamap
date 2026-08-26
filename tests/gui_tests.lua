-- Gui fit-math tests: the shared scale tiers every adaptive component reads.
--
-- The game's DEFAULT window is 640x576, so that tier must answer exactly 1
-- (the classic layout existing suites assert against); below it the scale
-- shrinks with the viewport (floored), above it grows (capped).

package.path = "../../../?.lua;" .. package.path

if not _G.love then _G.love = require("tests.love_stub") end

local Gui = require("mods.mapamap.components.gui")

function test_default_window_is_scale_one()
  assert(Gui.s(640, 576) == 1, "the default window runs the classic layout")
  assert(Gui.s(800, 600) == 1, "slightly larger stays at 1")
  assert(Gui.s(1280, 720) == 1, "common fullscreen stays at 1")
end

function test_large_windows_loosen_but_cap()
  local s1920 = Gui.s(1920, 1080)
  assert(s1920 > 1 and s1920 <= Gui.MAX_S,
    "large windows loosen spacing up to the cap")
end

function test_small_windows_shrink_with_floor()
  local s500 = Gui.s(500, 450)
  assert(s500 < 1 and s500 >= 0.5, "sub-default windows shrink")
  local tiny = Gui.s(200, 200)
  assert(tiny == Gui.MIN_S, "tiny windows clamp at the floor")
  assert(tiny >= 0.3, "the floor keeps touch targets reachable")
end

function test_monotonic_across_widths()
  local prev = 0
  for _, w in ipairs({ 320, 480, 640, 1024, 1600, 2560 }) do
    local s = Gui.s(w, 576)
    assert(s >= prev, "scale never decreases as the window widens")
    prev = s
  end
end

-- Hotbar key labels: slots 1-9 read "1".."9", slot 10 reads "0" (matching
-- the digit handler).
function test_hotbar_labels_are_key_names()
  local Hotbar = require("mods.mapamap.components.hotbar")
  assert(Hotbar.label(1) == "1" and Hotbar.label(9) == "9",
    "slots 1-9 label with their own number")
  assert(Hotbar.label(10) == "0", "slot 10 labels as 0")
end

-- Labels draw on EVERY slot, empty ones included (dimmer chip), via a
-- capture over Text.label.
function test_hotbar_labels_draw_on_empty_slots()
  local Hotbar = require("mods.mapamap.components.hotbar")
  local Text = require("mods.mapamap.components.text")
  local seen = {}
  local orig = Text.label
  Text.label = function(font, str, x, y, scale, opts)
    seen[#seen + 1] = { str = tostring(str), opts = opts }
  end
  local ok = pcall(function()
    Hotbar.draw(nil, 640, 576, {}, 1, { draw = function() end,
      width = function(s) return #s * 8 end })
  end)
  Text.label = orig
  assert(ok, "hotbar draw survives an empty bar")
  assert(#seen == 10, "one label per slot: " .. #seen)
  local byStr = {}
  for _, l in ipairs(seen) do byStr[l.str] = l end
  assert(byStr["0"] and byStr["0"].opts.bg[4] < 0.88,
    "empty slot 0 uses the dim chip")
  for i = 1, 9 do
    assert(byStr[tostring(i)], "label " .. i .. " drawn")
  end
end

-- Toolbar placement at two window sizes: wide windows keep one row beside
-- the hotbar; narrow windows wrap into a grid that stays on-screen.
function test_toolbar_layout_fits_both_sizes()
  local Toolbar = require("mods.mapamap.components.toolbar")
  for _, dims in ipairs({ { vw = 1280, vh = 720 }, { vw = 640, vh = 576 },
                          { vw = 320, vh = 288 } }) do
    local rects, box = Toolbar.layout(dims.vw, dims.vh)
    assert(#rects == #Toolbar.BUTTONS,
      "every button has a rect at " .. dims.vw)
    assert(box.x >= 0 and box.x + box.w <= dims.vw,
      "toolbar stays inside the window horizontally at " .. dims.vw)
    assert(box.y >= 0 and box.y + box.h <= dims.vh,
      "toolbar stays inside the window vertically at " .. dims.vw)
    -- Hit-test agrees with the drawn rects.
    for i, r in ipairs(rects) do
      assert(Toolbar.at(dims.vw, dims.vh, r.x + r.w / 2, r.y + r.h / 2) == i,
        "button " .. i .. " hit-tests to itself at " .. dims.vw)
    end
  end
end

return {
  name = "MAPAMAP_GUI",
  tests = {
    "test_default_window_is_scale_one",
    "test_large_windows_loosen_but_cap",
    "test_small_windows_shrink_with_floor",
    "test_monotonic_across_widths",
    "test_hotbar_labels_are_key_names",
    "test_hotbar_labels_draw_on_empty_slots",
    "test_toolbar_layout_fits_both_sizes",
  },
}
