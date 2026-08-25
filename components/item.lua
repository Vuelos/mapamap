-- Item thumbnail rendering shared by the hotbar and the picker.
--
-- A slot item is one of:
--   { kind = "block", id = <number>, tileset = <id> }  tileset block id
--   { kind = "sprite", id = <string> }                 NPC / object sprite id
--   { kind = "item", id = <string> }                   pickable map item (data.items id)
--   { kind = "blueprint", id, w, h, tiles }            captured block grid
--   { kind = "entity", entityType = "warp"|"object"|"sign",
--           newWarp | newObject | newSign legacy template flags are dropped
--           on load; entity tools carry warp|obj|sign or a create payload }
-- Blocks are drawn straight from the map renderer's tile atlas (or the owning
-- tileset's bundle when they came from a foreign tileset); sprites from a
-- lazily-built SpriteRenderer; blueprints from the renderer quads scaled to
-- the box.  Everything runs in LOVE screen units (render.hud space).

local Common = require("mods.mapamap.common")
local TILE_PX = 8

local Item = {}

-- Draws one item scaled into a boxSize square at (x, y).  Returns false when
-- nothing could be drawn.  `tileset`, when supplied, is a renderer bundle
-- { image, quads, aliasMap, blocks } for the tileset whose blocks this item
-- belongs to -- so the picker can thumbnail a non-current tileset's blocks from
-- its own atlas instead of always the live map's tileset.  `alpha` (0..1)
-- fades the whole thumbnail (used for drag ghosts).
function Item.draw(session, item, x, y, boxSize, tileset, alpha)
  if not item then return false end
  local r = session.map and session.map.renderer
  local A = alpha or 1

  -- Tree paint tools: render the resolved tileset block as the thumbnail.
  if item.kind == "tree" or item.kind == "headbutt" then
    local okT, TreeBlocks = pcall(require,
      "mods.mapamap.domain.tree_blocks")
    local bid = nil
    if okT and session then
      bid = (item.kind == "tree") and TreeBlocks.cutBlockFor(session)
        or TreeBlocks.headbuttBlockFor(session)
    end
    if bid then
      return Item.draw(session, { kind = "block", id = bid,
        tileset = session.tileset and session.tileset.id }, x, y, boxSize,
        nil, A)
    end
    love.graphics.setColor(0.2, 0.55, 0.25, 0.85 * A)
    love.graphics.rectangle("fill", x, y, boxSize, boxSize)
    love.graphics.setColor(1, 1, 1, A)
    if session.font then
      session.font.draw("?", x + boxSize / 3, y + boxSize / 3)
    end
    return true
  end

  if item.kind == "blueprint" then
    local bp = item
    if not bp or not bp.w or not bp.h or not bp.tiles or #bp.tiles == 0 then
      return false
    end
    local image, quads, aliasMap
    if r and r.image then
      image, quads, aliasMap = r.image, r.quads, r.aliasMap
    elseif session.tileset and session.thumbnailBundle then
      local bundle = session:thumbnailBundle(session.tileset)
      if bundle and bundle.image then
        image, quads, aliasMap = bundle.image, bundle.quads, bundle.aliasMap
      end
    end
    if not image then return false end
    local block = session.tileset and session.tileset.blocks
    local maxDim = math.max(bp.w, bp.h, 1)
    local thumbCell = math.max(1, math.floor(boxSize / maxDim))
    local ox = x + math.floor((boxSize - bp.w * thumbCell) / 2)
    local oy = y + math.floor((boxSize - bp.h * thumbCell) / 2)
    local scale = thumbCell / Common.BLOCK_PX
    love.graphics.setColor(1, 1, 1, A)
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
              local remap = aliasMap and aliasMap[bid]
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

  -- Brushes preview their resolved 3x3 core: every core position falls back
  -- to its assigned tile so sparse brushes still read as terrain.
  if item.kind == "brush" then
    local Brushes = require("mods.mapamap.domain.brushes")
    local cell = math.max(1, math.floor(boxSize / 3))
    local ox = x + math.floor((boxSize - cell * 3) / 2)
    local oy = y + math.floor((boxSize - cell * 3) / 2)
    local any = false
    for i, key in ipairs(Brushes.CORE) do
      local _, slotItem = Brushes.resolve(item, key)
      if slotItem then
        local col = (i - 1) % 3
        local row = math.floor((i - 1) / 3)
        Item.draw(session, slotItem, ox + col * cell, oy + row * cell, cell,
          tileset, A)
        any = true
      end
    end
    if not any then
      love.graphics.setColor(0.35, 0.6, 1, 0.5 * A)
      love.graphics.rectangle("fill", x, y, boxSize, boxSize)
      love.graphics.setColor(1, 1, 1, A)
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
    if not bundle and not tileset and not r then
      if session.tileset and session.thumbnailBundle then
        bundle = session:thumbnailBundle(session.tileset)
      end
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
    love.graphics.setColor(1, 1, 1, A)
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
        local sr = require("src.render.SpriteRenderer").new(def,
          "mapamap_" .. item.id)
        -- Gen 2 color mode: tint from the live palette data so thumbnails
        -- are not DMG gray (no-op on Gen 1 / headless).
        require("mods.mapamap.engine.gen").applySpritePalette(session, sr, def)
        session._spriteRenderers[item.id] = sr
      end
    end
    local sr = session._spriteRenderers[item.id]
    if not sr then
      love.graphics.setColor(0.8, 0.3, 0.2, 0.7 * A)
      love.graphics.rectangle("fill", x, y, boxSize, boxSize)
      love.graphics.setColor(1, 1, 1, A)
      return true
    end
    love.graphics.setColor(1, 1, 1, A)
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

  if item.kind == "entity" then
    local et = item.entityType
    if et == "warp" then
      love.graphics.setColor(0.2, 0.6, 1, 0.7 * A)
      love.graphics.circle("fill", x + boxSize / 2, y + boxSize / 2, boxSize / 3)
      love.graphics.setColor(1, 1, 1, 0.85 * A)
      love.graphics.circle("line", x + boxSize / 2, y + boxSize / 2, boxSize / 3)
      love.graphics.setColor(1, 1, 1, A)
      local destLabel = item.destMap
        or (item.create and item.create.destMap) or nil
      if session.font and destLabel then
        session.font.draw(destLabel, x + 2, y + boxSize / 2 + boxSize / 3 + 2)
      end
      return true
    end
    if et == "object" then
      -- A creator tool (create payload) previews the sprite it will place;
      -- fixed-sheet tools (boulder/blocker/berry tree) fall back to their
      -- own sheets so the thumbnail is never blank.
      local o = item.obj
      local spr = o and o.sprite or (item.create and item.create.sprite)
      if not spr and item.create then
        local candidates = ({
          boulder = { "SPRITE_BOULDER" },
          blocker = { "SPRITE_SNORLAX" },
          berrytree = { "SPRITE_FRUIT_TREE", "SPRITE_BERRY_TREE",
            "SPRITE_SMALL_TREE" },
          shop = { "SPRITE_CLERK", "SPRITE_RECEPTIONIST" },
        })[item.create.objectType]
        for _, id in ipairs(candidates or {}) do
          if session.data and session.data.sprites[id] then
            spr = id break
          end
        end
      end
      if not spr and ((item.create and item.create.objectType == "itemball")
          or (o and o.object_type == "item")) then
        spr = "SPRITE_POKE_BALL"
      end
      if spr and session.data and session.data.sprites[spr] then
        return Item.draw(session, { kind = "sprite", id = spr }, x, y, boxSize, nil, A)
      end
      love.graphics.setColor(0.35, 0.8, 0.4, 0.65 * A)
      love.graphics.circle("fill", x + boxSize / 2, y + boxSize / 2, boxSize / 3)
      love.graphics.setColor(1, 1, 1, 0.85 * A)
      love.graphics.circle("line", x + boxSize / 2, y + boxSize / 2, boxSize / 3)
      if session.font and item.name then
        session.font.draw(item.name, x + 2, y + boxSize / 2 + boxSize / 3 + 2)
      end
      return true
    end
    if et == "sign" then
      love.graphics.setColor(1, 0.55, 0.2, 0.7 * A)
      love.graphics.circle("fill", x + boxSize / 2, y + boxSize / 2, boxSize / 3)
      love.graphics.setColor(1, 1, 1, 0.85 * A)
      love.graphics.circle("line", x + boxSize / 2, y + boxSize / 2, boxSize / 3)
      local signLabel = (item.sign and item.sign.label)
        or (item.create and item.create.label) or nil
      if session.font and signLabel then
        session.font.draw(signLabel, x + 2, y + boxSize / 2 + boxSize / 3 + 2)
      end
      return true
    end
    return false
  end

  if item.kind == "item" then
    -- Items render as their overworld sprite when the data carries one; all
    -- item balls display as a pokeball on the overworld, so default to that.
    local idef = session.data and session.data.items and session.data.items[item.id]
    local sprite = (idef and idef.sprite) or "SPRITE_POKE_BALL"
    return Item.draw(session, { kind = "sprite", id = sprite }, x, y, boxSize, nil, A)
  end

  return false
end

return Item
