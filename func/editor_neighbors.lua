-- Neighbor management and map switching for the editor screen.

local Neighbors = require("mods.mapamap.func.neighbors")
local MapLoader = require("src.world.MapLoader")
local Snapshot = require("mods.mapamap.func.snapshot")
local Common = require("mods.mapamap.func.common")
local Undo = require("mods.mapamap.func.undo")
local TileRenderer = require("src.render.TileRenderer")
local PaletteFX = require("src.render.PaletteFX")
local FieldDefaults = require("src.world.FieldDefaults")
local BLOCK_PX = Common.BLOCK_PX
local CELL_PX = Common.CELL_PX

local EditorNeighbors = {}

function EditorNeighbors.rebuildNeighbors(self)
  local list, byId = {}, {}
  for _, n in ipairs(Neighbors.compute(self.data.maps, self.mapId, 2)) do
    local ok, m = pcall(MapLoader.load, self.data, n.id)
    if ok and m and m.renderer and m.def then
      byId[n.id] = m
      table.insert(list, {
        id = n.id, ox = n.ox, oy = n.oy,
        def = m.def, map = m,
        tileset = self.data.tilesets[m.def.tileset],
      })
    end
  end
  self.neighbors = list
  self.neighborMaps = byId
  self:refreshNeighborOriginals()
end

function EditorNeighbors.refreshNeighborOriginals(self)
  self.neighborOriginals = {}
  for _, nb in ipairs(self.neighbors or {}) do
    self.neighborOriginals[nb.id] = Snapshot.capture(nb.def)
  end
end

function EditorNeighbors.mapPaletteColors(self)
  local palettes = FieldDefaults.field(self.data, "palettes")
  local palName = self.def.palette
  if not palName then palName = palettes.byMap and palettes.byMap[self.mapId] end
  if not palName then palName = palettes.byTileset and palettes.byTileset[self.def.tileset] end
  if not palName then
    for _, row in ipairs(palettes.byPrefix or {}) do
      if row.prefix and self.mapId:find(row.prefix, 1, true) == 1 then
        palName = row.palette; break
      end
    end
  end
  if not palName then palName = palettes.default end
  return PaletteFX.pal(self.data, palName)
end

function EditorNeighbors.snapshotRecipConnections(self)
  local out = {}
  if self.data and self.data.maps then
    for otherId, otherDef in pairs(self.data.maps) do
      if otherId ~= self.mapId then
        for _, dir in ipairs(Common.DIRS) do
          for _, conn in ipairs(Common.connectionsOn(otherDef, dir)) do
            if conn.map == self.mapId then
              out[otherId] = Common.deepCopy(otherDef.connections)
              break
            end
          end
        end
      end
    end
  end
  return out
end

function EditorNeighbors.injectTextDefs(self)
  if self.def and self.def.textDefs and self.data then
    for _, td in ipairs(self.def.textDefs) do
      if not self.data.text_pointers[self.mapId] then
        self.data.text_pointers[self.mapId] = {}
      end
      self.data.text_pointers[self.mapId][td.const] = { text = td.key }
      self.data.text[td.key] = td.text
    end
  end
end

function EditorNeighbors.cleanupTextInjection(self, mapId, origDefs, label)
  if not self.data then return end
  origDefs = origDefs or {}
  local function inOrig(v, field)
    for _, td in ipairs(origDefs) do if td[field] == v then return true end end
    return false
  end
  if self.data.text_pointers then
    for _, l in ipairs({ mapId, label }) do
      local perMap = l and self.data.text_pointers[l]
      if perMap then
        for k in pairs(perMap) do
          if k:find("^TEXT_EDITOR_") and not inOrig(k, "const") then perMap[k] = nil end
        end
      end
    end
  end
  if self.data.text then
    for k in pairs(self.data.text) do
      if k:find("^map_editor_") and not inOrig(k, "key") then self.data.text[k] = nil end
    end
  end
  for _, td in ipairs(origDefs) do
    if not self.data.text_pointers[mapId] then self.data.text_pointers[mapId] = {} end
    self.data.text_pointers[mapId][td.const] = { text = td.key }
    self.data.text[td.key] = td.text
  end
end

function EditorNeighbors.mapUnderCursor(self)
  local id = Neighbors.mapAt(self.def, self.neighbors, self.cursorBx, self.cursorBy)
  if not id then return nil end
  for _, nb in ipairs(self.neighbors or {}) do
    if nb.id == id then return nb end
  end
  return nil
end

function EditorNeighbors.switchToMap(self, nb)
  local fromId = self.mapId
  local data = self.data

  if self._sessionOriginals[fromId] == nil then
    self._sessionOriginals[fromId] = self._originalSnapshot
  end
  if self._sessionEncounters[fromId] == nil then
    self._sessionEncounters[fromId] = self.originalEncounters
  end
  if self.mapChanged then self._sessionDirty[fromId] = true end

  local orig = self.neighborOriginals and self.neighborOriginals[nb.id]
  if not orig then orig = Snapshot.capture(nb.def) end
  if self._sessionOriginals[nb.id] == nil then
    self._sessionOriginals[nb.id] = orig
  end
  if self._sessionEncounters[nb.id] == nil then
    self._sessionEncounters[nb.id] =
      Common.deepCopy(data and data.encounters and data.encounters[nb.id])
  end
  local pendingEdits = (self.neighborDirty and self.neighborDirty[nb.id] == true)
    or (self._sessionDirty and self._sessionDirty[nb.id] == true)

  self:cleanupTextInjection(fromId, self._originalSnapshot and self._originalSnapshot.textDefs or {}, self.def and self.def.label)

  self.cursorBx = math.floor((self.cursorBx * CELL_PX - nb.ox) / CELL_PX)
  self.cursorBy = math.floor((self.cursorBy * CELL_PX - nb.oy) / CELL_PX)

  self.mapId = nb.id
  self.def = nb.def
  self.tileset = nb.tileset
  self.map = nb.map
  self.mapW = nb.def.width * BLOCK_PX
  self.mapH = nb.def.height * BLOCK_PX
  self.paletteColors = self:mapPaletteColors()
  self.undo = Undo.new()
  self.expandShiftL = 0
  self.expandShiftT = 0
  self.paletteFocus = false
  self.paletteCursorX = nil
  self.paletteCursorY = nil
  self.paletteOffset = 0
  if self.neighborDirty then self.neighborDirty[nb.id] = nil end
  if #self.tileset.blocks > 0 then
    self.selectedBlock = math.max(0, math.min(#self.tileset.blocks - 1, self.selectedBlock))
  end
  self:injectTextDefs()
  TileRenderer.tick(0)

  self:rebuildNeighbors()

  self._originalSnapshot = Snapshot.capture(orig)
  self.originalRecipConnections = self:snapshotRecipConnections()
  self.originalEncounters = Common.deepCopy(self._sessionEncounters[nb.id])
  self.paletteList = {}
  for i = 1, #self.tileset.blocks do self.paletteList[i] = i - 1 end
  if self.map.renderer then self.map.renderer:rebuild() end

  self.mapChanged = pendingEdits
  if self.mapChanged then self._sessionDirty[nb.id] = true end
end

return EditorNeighbors