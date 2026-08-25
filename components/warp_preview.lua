-- WarpPreview: live destination preview for warp editing, plus its
-- interactive panel.
--
-- While a warp is being edited (Entity Creator form or Details), this
-- component shows WHERE it leads:
--   * laid-out destinations (the edited map or a neighbor) are marked in
--     the world -- faint outline over the map body, pulsing highlight on
--     the destination cell (warp # entry) and a label chip;
--   * isolated destinations (e.g. NEW MAP indoor rooms) are not on the
--     walking grid, so they render as a TILED side panel: the real map
--     blocks through the destination's tileset bundle, every destination
--     warp drawn as a numbered marker, the current arrival ringed.
--
-- The tiled panel is also interactive (input.lua routes clicks here):
--   * LMB an empty tile  -> create a destination warp at that cell
--                           (pointing back at the edited map) and select
--                           it as the arrival;
--   * LMB a marker       -> select that warp number as the arrival;
--   * RMB a marker       -> remove it.

local Coords = require("mods.mapamap.engine.coords")
local Text = require("mods.mapamap.components.text")
local Warps = require("mods.mapamap.domain.warps")
local WorldAdapter = require("mods.mapamap.engine.world_adapter")

local WarpPreview = {}

-- Reads the destination under edit from whatever surface is open:
-- returns destMap, destWarp or nil when not editing a warp.
local function draftValues(ui)
  if ui.entityCreator and ui.entityCreator.entityType == "warp" then
    local destMap, destWarp
    for _, f in ipairs(ui.entityCreator.fields or {}) do
      if f.key == "destMap" then destMap = f.value end
      if f.key == "destWarp" then destWarp = tonumber(f.value) or 0 end
    end
    return destMap, destWarp
  end
  if ui.details and ui.details.entityType == "warp"
      and ui.details.entity then
    return ui.details.entity.destMap, ui.details.entity.destWarp
  end
  return nil
end

-- World-cell rect stroke: plain rectangle on the flat blit; projected
-- polygon under the voxel pass.  Mirrors overlay.lua's helper (kept local
-- there because every world marker shares it).
local function strokeCellRect(t, cellX, cellY, cellsW, cellsH, mode)
  if t.kind == "voxel" then
    local poly = { Coords.blockPoly(t, cellX, cellY, cellsW, cellsH) }
    if poly[1] then love.graphics.polygon(mode, poly) end
    return
  end
  local x, y, w, h
  if cellsW == 1 and cellsH == 1 then
    x, y, w, h = Coords.cellRect(t, cellX, cellY)
  else
    x, y, w, h = Coords.blockRect(t, cellX, cellY)
    if x and (cellsW ~= 2 or cellsH ~= 2) then
      w, h = w * cellsW / 2, h * cellsH / 2
    end
  end
  if x then love.graphics.rectangle(mode, x, y, w, h) end
end

-- The screen position of a walk-grid cell's center (flat + voxel).
local function markerCenter(t, ox, oy, cellX, cellY)
  if t.kind == "voxel" then
    return Coords.toScreen(t, ox + cellX * 16 + 8, oy + cellY * 16 + 8)
  end
  local x, y = Coords.toScreen(t, ox + cellX * 16, oy + cellY * 16)
  if not x then return nil end
  return x + 8 * t.sx, y + 8 * t.sy
end

-- Panel geometry for the destination preview; shared by the draw path and
-- the click hit-test so the two can never drift.  The tile scale shrinks so
-- even a full-sized outdoor map fits the panel box.
local function layout(pv)
  local vw, vh = love.graphics.getDimensions()
  local maxW, maxH = vw - 24, vh * 0.55
  local tw = (pv.def.width or 2) * 16
  local th = (pv.def.height or 2) * 16
  local s = math.min(1, maxW / tw, maxH / th)
  tw, th = tw * s, th * s
  local w, h = tw + 16, th + 46
  local px = math.max(8, vw - w - 12)
  local py = math.max(8, math.min(56, vh - h - 8))
  return { px = px, py = py, w = w, h = h,
           tx = px + 8, ty = py + 30, s = s, tw = tw, th = th }
end

local function markerAt(L, w)
  return L.tx + ((w.x or 0) * 2 + 1) * 8 * L.s,
         L.ty + ((w.y or 0) * 2 + 1) * 8 * L.s
end

-- Hit-test for the interactive preview panel.  Returns action
-- { kind = "warp", index } or { kind = "cell", cellX, cellY } plus the
-- destination map id, or nil when the point misses / not editing.
function WarpPreview.interact(ui, session, mx, my)
  local destMap, destWarp = draftValues(ui)
  if not destMap then return nil end
  local pv = Warps.destPreview(session, destMap, destWarp)
  if not pv then return nil end
  local L = layout(pv)
  if mx < L.px or mx >= L.px + L.w or my < L.py or my >= L.py + L.h then
    return nil
  end
  -- Warp markers win over empty cells.
  for i, w in ipairs(pv.def.warps or {}) do
    local mxp, myp = markerAt(L, w)
    local ddx, ddy = mx - mxp, my - myp
    if ddx * ddx + ddy * ddy <= 100 then
      return { kind = "warp", index = i }, destMap
    end
  end
  if mx >= L.tx and mx < L.tx + L.tw and my >= L.ty and my < L.ty + L.th then
    local cellX = math.floor((mx - L.tx) / (16 * L.s))
    local cellY = math.floor((my - L.ty) / (16 * L.s))
    if cellX >= 0 and cellX < (pv.def.width or 0)
        and cellY >= 0 and cellY < (pv.def.height or 0) then
      return { kind = "cell", cellX = cellX, cellY = cellY }, destMap
    end
  end
  return nil
end

-- Applies a preview-panel click: LMB on a marker selects it as the arrival
-- (warp #), LMB on an empty tile CREATES a destination warp there pointing
-- back at the edited map and selects it; RMB on a marker removes it.
function WarpPreview.applyClick(ui, session, hit, destMap, button)
  local def = session.data.maps and session.data.maps[destMap]
  if not def then return false end
  def.warps = def.warps or {}
  local function selectIndex(index)
    -- Warp numbers are 1-based (the engine indexes warps[n] directly).
    index = math.max(1, index)
    if ui.entityCreator and ui.entityCreator.entityType == "warp" then
      for _, f in ipairs(ui.entityCreator.fields or {}) do
        if f.key == "destWarp" then f.value = tostring(index) end
      end
      ui.entityCreator.status = "arrival: #" .. index
    elseif ui.details and ui.details.entityType == "warp"
        and ui.details.entity then
      if not session:setWarpDest(ui.details.entity, nil, index) then
        ui.details.entity.destWarp = math.max(1,
          #(session.data.maps[ui.details.entity.destMap]
            and session.data.maps[ui.details.entity.destMap].warps or {}) )
      end
    end
  end

  if button == 2 then
    if hit.kind == "warp" then
      table.remove(def.warps, hit.index)
      WorldAdapter.refreshWarps(session)
      if #def.warps > 0 then
        selectIndex(math.min(hit.index, #def.warps))
      end
      return true
    end
    return false
  end

  if hit.kind == "warp" then
    selectIndex(hit.index)
    return true
  end
  if hit.kind == "cell" then
    def.warps[#def.warps + 1] = {
      x = hit.cellX, y = hit.cellY,
      destMap = session.mapId, destWarp = 1,
    }
    WorldAdapter.refreshWarps(session)
    selectIndex(#def.warps)
    return true
  end
  return false
end

-- Draws the preview: world markers for laid-out destinations, the tiled
-- panel for isolated ones.  Called from the overlay orchestrator inside the
-- non-obscured world-marker block.
function WarpPreview.draw(ui, session, game)
  local destMap, destWarp = draftValues(ui)
  if not destMap then return end
  local pv = Warps.destPreview(session, destMap, destWarp)
  if not pv then return end
  local pulse = 0.55 + 0.3 * math.abs(math.sin(love.timer.getTime() * 5))

  -- Laid-out destinations ALSO get their world position marked.
  if pv.laidOut then
    local t = Coords.transform(game)
    if t then
      love.graphics.setColor(1, 0.9, 0.3, 0.35)
      love.graphics.setLineWidth(1)
      strokeCellRect(t, pv.ox / 16, pv.oy / 16,
        pv.def.width * 2, pv.def.height * 2, "line")
      love.graphics.setColor(1, 0.9, 0.3, 0.22)
      strokeCellRect(t, pv.cellX, pv.cellY, 1, 1, "fill")
      love.graphics.setColor(1, 0.85, 0.25, pulse)
      love.graphics.setLineWidth(2)
      strokeCellRect(t, pv.cellX, pv.cellY, 1, 1, "line")
      local cx, cy = markerCenter(t, pv.ox, pv.oy, pv.cellX, pv.cellY)
      if cx and session.font then
        Text.label(session.font, pv.label, cx + 8 * t.sx,
          cy - 8 * t.sy - 10 * t.sx, 1, {
            bg = { 0.9, 0.75, 0.2, 0.9 }, padX = 3, padY = 1,
          })
      end
      love.graphics.setColor(1, 1, 1, 1)
    end
  end

  -- The COMPLETE destination map, tiled at a fitted scale -- every
  -- destination warp numbered, the current arrival ringed.
  local L = layout(pv)
  love.graphics.setColor(0, 0, 0, 0.88)
  love.graphics.rectangle("fill", L.px, L.py, L.w, L.h)
  love.graphics.setColor(1, 0.85, 0.25, 0.7)
  love.graphics.rectangle("line", L.px, L.py, L.w, L.h)
  if session.font then
    Text.label(session.font, pv.laidOut and "DEST MAP" or "INDOOR DEST",
      L.px + 8, L.py + 6, 1,
      { bg = { 0.9, 0.75, 0.2, 0.9 }, padX = 3, padY = 1 })
  end
  love.graphics.setColor(0, 0, 0, 0.88)
  love.graphics.rectangle("fill", L.px, L.py, L.w, L.h)
  love.graphics.setColor(1, 0.85, 0.25, 0.7)
  love.graphics.rectangle("line", L.px, L.py, L.w, L.h)
  if session.font then
    Text.label(session.font, "INDOOR DEST", L.px + 8, L.py + 6, 1,
      { bg = { 0.9, 0.75, 0.2, 0.9 }, padX = 3, padY = 1 })
  end

  -- Tiles: the destination map's real blocks through its tileset bundle.
  local bundle = session.thumbnailBundle
    and session:thumbnailBundle(session.data.tilesets[pv.def.tileset])
  local drewTiles = false
  if bundle and bundle.image and bundle.quads then
    for by = 0, (pv.def.height or 1) - 1 do
      for bx = 0, (pv.def.width or 1) - 1 do
        local bid = pv.def.blocks[by * pv.def.width + bx + 1] or 0
        local block = bundle.blocks and bundle.blocks[bid + 1]
        if block then
          for rr = 0, 3 do
            for cc = 0, 3 do
              local tile = block[rr * 4 + cc + 1]
              local remap = bundle.aliasMap and bundle.aliasMap[bid]
              if remap and remap[rr * 4 + cc] then
                tile = remap[rr * 4 + cc]
              end
              local quad = bundle.quads[tile]
              if quad then
                love.graphics.draw(bundle.image, quad,
                  L.tx + bx * 16 * L.s + cc * 8 * L.s,
                  L.ty + by * 16 * L.s + rr * 8 * L.s, 0, L.s, L.s)
                drewTiles = true
              end
            end
          end
        end
      end
    end
  end
  if not drewTiles then
    love.graphics.setColor(0.15, 0.15, 0.2, 0.9)
    love.graphics.rectangle("fill", L.tx, L.ty, L.tw, L.th)
  end

  -- Destination warps: blue markers with their 0-based number; the current
  -- arrival (#destWarp) rings yellow.
  for i, w in ipairs(pv.def.warps or {}) do
    local mxp, myp = markerAt(L, w)
    love.graphics.setColor(0.25, 0.55, 1, 0.85)
    love.graphics.circle("fill", mxp, myp, 7)
    love.graphics.setColor(1, 1, 1, 0.95)
    love.graphics.setLineWidth(1)
    love.graphics.circle("line", mxp, myp, 7)
    if i == math.floor(tonumber(destWarp) or 1) then
      love.graphics.setColor(1, 0.85, 0.25, pulse)
      love.graphics.setLineWidth(2)
      love.graphics.circle("line", mxp, myp, 10)
    end
    if session.font then
      Text.label(session.font, tostring(i - 1),
        mxp + 6, myp - 14, 1,
        { bg = { 0.05, 0.05, 0.09, 0.9 }, padX = 2, padY = 0 })
    end
  end
  if session.font then
    Text.label(session.font, pv.label, L.px + 8, L.py + L.h - 16, 1,
      { bg = { 0.9, 0.75, 0.2, 0.9 }, padX = 3, padY = 1 })
  end
  love.graphics.setColor(1, 1, 1, 1)
end

return WarpPreview
