-- Item thumbnail rendering shared by the hotbar and the picker.
--
-- A slot item is one of:
--   { kind = "block", id = <number>, tileset = <id> }  tileset block id
--   { kind = "sprite", id = <string> }                 NPC / object sprite id
--   { kind = "item", id = <string> }                   pickable map item (data.items id)
--   { kind = "blueprint", id, w, h, tiles }            captured block grid
--   { kind = "warp", warp|destMap, destWarp }          live warp tool / new-warp template
--   { kind = "object", obj|newObject }                 live map object / new-object template
--
-- Blocks are drawn straight from the map renderer's tile atlas (or the owning
-- tileset's bundle when they came from a foreign tileset); sprites from a
-- lazily-built SpriteRenderer; blueprints from the renderer quads scaled to
-- the box.  Everything runs in LOVE screen units (render.hud space).

local Common = require("mods.mapamap.func.common")
local TILE_PX = 8

local Item = {}

-- Draws one item scaled into a boxSize square at (x, y).  Returns false when
-- nothing could be drawn.  `tileset`, when supplied, is a renderer bundle
-- { image, quads, aliasMap, blocks } for the tileset whose blocks this item
-- belongs to -- so the picker can thumbnail a non-current tileset's blocks from
-- its own atlas instead of always the live map's tileset.
function Item.draw(session, item, x, y, boxSize, tileset)
  if not item then return false end
  local r = session.map and session.map.renderer

  if item.kind == "blueprint" then
    local bp = item
    if not bp or not bp.w or not bp.h or not bp.tiles or #bp.tiles == 0
       or not r or not r.image then return false end
    local image, quads = r.image, r.quads
    local block = session.tileset and session.tileset.blocks
    local maxDim = math.max(bp.w, bp.h, 1)
    local thumbCell = math.max(1, math.floor(boxSize / maxDim))
    local ox = x + math.floor((boxSize - bp.w * thumbCell) / 2)
    local oy = y + math.floor((boxSize - bp.h * thumbCell) / 2)
    local scale = thumbCell / Common.BLOCK_PX
    love.graphics.setColor(1, 1, 1, 1)
    for row = 0, bp.h - 1 do
      for col = 0, bp.w - 1 do
        local tileCell = bp.tiles[row * bp.w + col + 1]
        local bid = type(tileCell) == "table" and tileCell.id or tileCell
        local b = bid and block and block[bid + 1]
        if b then
          love.graphics.push()
          love.graphics.scale(scale, scale)
          local bx = (ox + col * thumbCell) / scale
          local by = (oy + row * thumbCell) / scale
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
    -- A foreign-tagged block (srcTileset/tileset) thumbs from its OWN tileset
    -- bundle (grown/own atlas), never the live map's renderer -- the id
    -- indexes the source tileset's block list, not the current one's.
    local srcts = item.srcTileset or item.tileset
    local bundle
    if srcts and session.tileset and srcts ~= session.tileset.id then
      local tsDef = session.data and session.data.tilesets and session.data.tilesets[srcts]
      local thumb = session.thumbnailBundle
      if tsDef and thumb then bundle = thumb(session, tsDef) end
    end
    if not r and not bundle then return false end
    local image, quads, aliasMap, blocksTable
    if bundle then
      image, quads, aliasMap, blocksTable =
        bundle.image, bundle.quads, bundle.aliasMap, bundle.blocks
    elseif tileset then
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
    -- Full size x2: a sprite frame is 16x16, so render it at the box size
    -- (the old code fit it into a 32px box, showing sprites at half scale).
    local scale = boxSize / 16
    local ox = (boxSize / scale - 16) / 2
    local oy = (boxSize / scale - 16) / 2
    love.graphics.push()
    love.graphics.scale(scale, scale)
    sr:draw(x / scale + ox, y / scale + oy, 0, 0, "down", 0, false)
    love.graphics.pop()
    return true
  end

  if item.kind == "warp" then
    -- Warp entries render as a blue-filled circle with a white ring, matching
    -- the entity-marker style used in the world overlay (blue = warp).  The
    -- "new warp" template cell draws a green plus so it reads as a builder.
    if item.newWarp then
      love.graphics.setColor(0.2, 0.8, 0.35, 0.7)
      love.graphics.circle("fill", x + boxSize / 2, y + boxSize / 2, boxSize / 3)
      love.graphics.setColor(1, 1, 1, 0.9)
      love.graphics.line(x + boxSize / 2 - boxSize / 6, y + boxSize / 2,
        x + boxSize / 2 + boxSize / 6, y + boxSize / 2)
      love.graphics.line(x + boxSize / 2, y + boxSize / 2 - boxSize / 6,
        x + boxSize / 2, y + boxSize / 2 + boxSize / 6)
    else
      love.graphics.setColor(0.2, 0.6, 1, 0.7)
      love.graphics.circle("fill", x + boxSize / 2, y + boxSize / 2, boxSize / 3)
      love.graphics.setColor(1, 1, 1, 0.85)
      love.graphics.circle("line", x + boxSize / 2, y + boxSize / 2, boxSize / 3)
    end
    love.graphics.setColor(1, 1, 1, 1)
    if session.font and item.newWarp then
      session.font.draw("NEW", x + 2, y + boxSize / 2 + boxSize / 3 + 2)
    elseif session.font and item.destMap then
      session.font.draw(item.destMap, x + 2, y + boxSize / 2 + boxSize / 3 + 2)
    end
    return true
  end

  if item.kind == "object" then
    -- Object cells: the "new object" template is a green plus builder; live
    -- map objects reuse the sprite/item thumbnail so the cell shows exactly
    -- what placing it copies, else a green disc with the object's name.
    if item.newObject then
      love.graphics.setColor(0.2, 0.8, 0.35, 0.7)
      love.graphics.circle("fill", x + boxSize / 2, y + boxSize / 2, boxSize / 3)
      love.graphics.setColor(1, 1, 1, 0.9)
      love.graphics.line(x + boxSize / 2 - boxSize / 6, y + boxSize / 2,
        x + boxSize / 2 + boxSize / 6, y + boxSize / 2)
      love.graphics.line(x + boxSize / 2, y + boxSize / 2 - boxSize / 6,
        x + boxSize / 2, y + boxSize / 2 + boxSize / 6)
      if session.font then
        session.font.draw("NEW", x + 2, y + boxSize / 2 + boxSize / 3 + 2)
      end
      return true
    end
    local o = item.obj
    if o and o.sprite and session.data and session.data.sprites[o.sprite] then
      return Item.draw(session, { kind = "sprite", id = o.sprite }, x, y, boxSize)
    end
    love.graphics.setColor(0.35, 0.8, 0.4, 0.65)
    love.graphics.circle("fill", x + boxSize / 2, y + boxSize / 2, boxSize / 3)
    love.graphics.setColor(1, 1, 1, 0.85)
    love.graphics.circle("line", x + boxSize / 2, y + boxSize / 2, boxSize / 3)
    if session.font and item.name then
      session.font.draw(item.name, x + 2, y + boxSize / 2 + boxSize / 3 + 2)
    end
    return true
  end

  if item.kind == "item" then
    -- Items render as their overworld sprite when the data carries one; else
    -- a small labelled pill so the slot still reads.
    local idef = session.data and session.data.items and session.data.items[item.id]
    local sprite = idef and idef.sprite
    if sprite then
      return Item.draw(session, { kind = "sprite", id = sprite }, x, y, boxSize)
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
