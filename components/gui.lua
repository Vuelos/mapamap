-- Gui: shared fit-to-window math for every overlay component.
--
-- The game's DEFAULT window is 640x576 (conf.lua) and is freely resizable
-- down to 160x144 / up to desktop sizes, so layouts must adapt instead of
-- assuming one canvas:
--   * s == 1        inside/at the default window -- the classic layout,
--                   byte-for-byte compatible with every existing test;
--   * s < 1         below it -- spacing/slots shrink proportionally
--                   (floored so touch-sized UIs stay tappable);
--   * s > 1         on large windows -- panels loosen, capped so the bitmap
--                   font never mismatches the boxes around it.
-- Dependency-free on purpose: components at ANY layer can require it
-- without creating cycles.

local Gui = {}

-- The default-window tier everything was designed against.
Gui.BASE_W = 640
Gui.BASE_H = 500      -- verticals get a little slack: rows scroll anyway

Gui.MIN_S = 0.35
Gui.MAX_S = 1.25

-- The ui-space scale factor for a viewport.  Monotonic in both axes.
function Gui.s(vw, vh)
  vw, vh = vw or 640, vh or 576
  if vw >= Gui.BASE_W and vh >= Gui.BASE_H then
    if vw >= 1600 or vh >= 900 then
      return math.min(Gui.MAX_S, math.max(vw / 1600, vh / 900))
    end
    return 1
  end
  return math.max(Gui.MIN_S,
    math.min(vw / Gui.BASE_W, vh / Gui.BASE_H))
end

return Gui
