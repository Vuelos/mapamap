-- Small text renderer for the overlay UI: draws the game font scaled up
-- (2x by default) on a light chip so the GB black-ink glyphs stay readable
-- over the dark editing panels.  Everything runs in LOVE screen units.

local Text = {}

-- Draws `str` at (x, y) scaled by `scale` (default 2), optionally behind a
-- light contrast chip.  `opts`:
--   bg     - { r, g, b, a } chip fill (default nil = no chip)
--   padX/padY - chip padding around the glyphs
--   dx/dy  - extra offset applied inside the scaled space
-- Returns the drawn width in screen units.
function Text.label(font, str, x, y, scale, opts)
  local s = scale or 2
  opts = opts or {}
  local glyphW = (font and font.width and font.width(str)) or (#tostring(str) * 8)
  local tw = glyphW * s
  local th = (opts.h or 8) * s
  local padX = opts.padX or 2
  local padY = opts.padY or 1
  local bg = opts.bg
  if bg then
    love.graphics.setColor(bg[1], bg[2], bg[3], bg[4] or 0.92)
    love.graphics.rectangle("fill", x - padX, y - padY, tw + padX * 2, th + padY * 2)
  end
  -- Dark ink on the light chip (GB glyphs are black-on-transparent; TTF text
  -- respects the color too, so this keeps both readable).
  love.graphics.setColor(0.05, 0.05, 0.09, 1)
  love.graphics.push()
  love.graphics.scale(s, s)
  font.draw(str, x / s + (opts.dx or 0), y / s + (opts.dy or 0))
  love.graphics.pop()
  love.graphics.setColor(1, 1, 1, 1)
  return tw
end

return Text