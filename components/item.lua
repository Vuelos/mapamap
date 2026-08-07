-- Item thumbnail rendering shared by the hotbar and the picker.
--
-- A slot item is one of:
--   { kind = "block", id = <number> }        tileset block id
--   { kind = "sprite", id = <string> }       NPC / object sprite id
--   { kind = "item", id = <string> }         pickable map item (data.items id)
--   { kind = "blueprint", id = <string> }    captured block grid
--
-- Blocks are drawn straight from the map renderer's tile atlas; sprites from
-- a lazily-built SpriteRenderer; blueprints from the renderer quads scaled to
-- the box.  Everything runs in LOVE screen units (render.hud space).

local Common = require("mods.mapamap.func.common")
local TILE_PX = 8

local Item = {}

-- Draws one item scaled into a boxSize square at (x, y).  Returns false when
-- nothing could be drawn.  `blueprints` is the blueprint book array (only used
-- by the blueprint kind).  `tileset`, when supplied, is a renderer bundle
-- { image, quads, aliasMap, blocks } for the tileset whose blocks this item
-- belongs to -- so the picker can thumbnail a non-current tileset's blocks from
-- its own atlas instead of always the live map's tileset.
function Item.draw(session, item, x, y, boxSize, blueprints, tileset)
  if not item then return false end
  local r = session.map and session.map.renderer

  if item.kind == "blueprint" then
    local bp = nil
    for _, e in ipairs(blueprints or {}) do if e.id == item.id then bp = e; break end end
    if not bp or not r or not r.image then return false end
    local image, quads = r.image, r.quads
    local block = session.tileset and session.tileset.blocks
    local maxDim = math.max(bp.w, bp.h, 1)
    local cell = math.max(1, math.floor(boxSize / maxDim))
    local ox = x + math.floor((boxSize - bp.w * cell) / 2)
    local oy = y + math.floor((boxSize - bp.h * cell) / 2)
    local scale = cell / Common.BLOCK_PX
    love.graphics.setColor(1, 1, 1, 1)
    for row = 0, bp.h - 1 do
      for col = 0, bp.w - 1 do
        local bid = bp.tiles[row * bp.w + col + 1]
        local b = block and block[bid + 1]
        if b then
          love.graphics.push()
          love.graphics.scale(scale, scale)
          local bx = (ox + col * cell) / scale
          local by = (oy + row * cell) / scale
          for rr = 0, 3 do
            for cc = 0, 3 do
              local ci = rr * 4 + cc + 1
              local tile = b[ci]
              local remap = r.aliasMap and r.aliasMap[bid]
              if remap and remap[ci - 1] then tile = remap[ci - 1] end
              local quad = quads[tile]
              if quad then love.graphics.draw(image, quad, bx + cc * TILE_PX, by + rr * TILE_PX) end
            end
          end
          love.graphics.pop()
        end
      end
    end
    return true
  end

  if item.kind == "block" then
    if not r or not r.image then return false end
    local image, quads, aliasMap, blocksTable
    if tileset then
      image, quads, aliasMap, blocksTable =
        tileset.image, tileset.quads, tileset.aliasMap, tileset.blocks
    else
      image, quads, aliasMap, blocksTable =
        r.image, r.quads, r.aliasMap, (session.tileset and session.tileset.blocks)
    end
    local block = blocksTable and blocksTable[item.id + 1]
    if not block then return false end
    local scale = boxSize / Common.BLOCK_PX
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.push()
    love.graphics.scale(scale, scale)
    for rr = 0, 3 do
      for cc = 0, 3 do
        local ci = rr * 4 + cc + 1
        local tile = block[ci]
        local remap = aliasMap and aliasMap[item.id]
        if remap and remap[ci - 1] then tile = remap[ci - 1] end
        local quad = quads[tile]
        if quad then
          love.graphics.draw(image, quad, x / scale + cc * TILE_PX,
            y / scale + rr * TILE_PX)
        end
      end
    end
    love.graphics.pop()
    return true
  end

  if item.kind == "sprite" then
    if not session._spriteRenderers then session._spriteRenderers = {} end
    if not session._spriteRenderers[item.id] then
      local def = session.data and session.data.sprites[item.id]
      if def then
        session._spriteRenderers[item.id] =
          require("src.render.SpriteRenderer").new(def, "mapamap_" .. item.id)
      end
    end
    local sr = session._spriteRenderers[item.id]
    if not sr then
      love.graphics.setColor(0.8, 0.3, 0.2, 0.7)
      love.graphics.rectangle("fill", x, y, boxSize, boxSize)
      love.graphics.setColor(1, 1, 1, 1)
      return true
    end
    love.graphics.setColor(1, 1, 1, 1)
    local scale = boxSize / 32
    love.graphics.push()
    love.graphics.scale(scale, scale)
    sr:draw(x / scale, y / scale + 8, 0, 0, "down", 0, false)
    love.graphics.pop()
    return true
  end

  if item.kind == "item" then
    -- Items render as their overworld sprite when the data carries one; else
    -- a small labelled pill so the slot still reads.
    local idef = session.data and session.data.items and session.data.items[item.id]
    local sprite = idef and idef.sprite
    if sprite then
      return Item.draw(session, { kind = "sprite", id = sprite }, x, y, boxSize, blueprints)
    end
    love.graphics.setColor(0.35, 0.6, 1, 0.5)
    love.graphics.rectangle("fill", x, y, boxSize, boxSize)
    love.graphics.setColor(1, 1, 1, 1)
    if session.font then
      session.font.draw(item.id, x + 2, y + 2)
    end
    return true
  end

  return false
end

return Item
