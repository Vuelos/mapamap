-- Coords mapping tests (headless): verify the overlay's screen <-> world cell
-- conversion is round-trip consistent under integer scales (the same scale as
-- a real overworld frame) so a paint lands on the cell under the cursor.

package.path = "../../../?.lua;" .. package.path

if not _G.love then _G.love = require("tests.love_stub") end

local Coords = require("mods.mapamap.engine.coords")

-- Build a transform with explicit values so the tests are self-contained and
-- do not depend on the live Renderer / camera (a headless harness has none).
local function flatTransform()
  return {
    camx = 100, camy = 50,   -- camera top-left in world px
    vw = 320, vh = 288,
    sp = 2,                   -- zoom scale (units per world px at 1x)
    sx = 2, sy = 2,           -- units per world px
    wox = 8, woy = 6,         -- integer letterbox origin (units)
  }
end

function test_roundTripScreen()
  local t = flatTransform()
  for _, cell in ipairs({ { 0, 0 }, { 5, 3 }, { -2, 7 }, { 12, -4 } }) do
    local cx, cy = cell[1], cell[2]
    -- centre of the cell maps to the cell itself.
    local wx, wy = cx * 16 + 8, cy * 16 + 8
    local sxU, syU = Coords.toScreen(t, wx, wy)
    local bx, by = Coords.toWorldCell(t, sxU, syU)
    assert(bx == cx and by == cy,
      ("cell (%d,%d) == (%d,%d) after round trip"):format(cx, cy, bx, by))
  end
end

function test_cellRectGeometry()
  local t = flatTransform()
  local x, y, w, h = Coords.cellRect(t, 0, 0)
  -- cell 0,0: world px 0,0 -> screen origin at (wox-camx*sx, woy-camy*sy).
  local ex = t.wox + (0 - t.camx) * t.sx
  local ey = t.woy + (0 - t.camy) * t.sy
  assert(math.abs(x - ex) < 1e-6 and math.abs(y - ey) < 1e-6,
    ("cellRect origin wrong: got (%d,%d) want (%d,%d)"):format(x, y, ex, ey))
  assert(math.abs(w - 32) < 1e-6, "16px cell at 2x scale should be 32 units")
  assert(math.abs(h - 32) < 1e-6, "16px cell at 2x scale should be 32 units high")
end

function test_blockRectIsTwoCells()
  local t = flatTransform()
  -- A whole block (2x2 cells) whose top-left cell is (1,1).
  local x, y, w, h = Coords.blockRect(t, 1, 1)
  assert(math.abs(w - 64) < 1e-6, "block should be 64 units wide (2 cells)")
  assert(math.abs(h - 64) < 1e-6, "block should be 64 units tall")
end

function test_transformGatedWithoutCamera()
  local t = Coords.transform({ overworld = {} })
  assert(t == nil, "transform should be nil when no camera is present")
  -- Affine helpers must not misbehave on a missing transform.
  assert(Coords.toWorldCell(nil, 0, 0) == nil, "toWorldCell(nil) should return nil")
  assert(Coords.blockRect(nil, 1, 1) == nil, "blockRect(nil) should return nil")
end

return {
  name = "MAPAMAP_COORDS",
  tests = {
    "test_roundTripScreen",
    "test_cellRectGeometry",
    "test_blockRectIsTwoCells",
    "test_transformGatedWithoutCamera",
  },
}