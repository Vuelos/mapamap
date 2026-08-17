-- Editor UI state lifecycle: seeding, reset, per-map re-pointing, and the
-- mod-save persistence for the hotbar layout and the inventory collection.
--
-- Everything operates on the Input controller table (`ui`): the hotbar /
-- inventory / picker / selection state lives there, and these helpers are the
-- only places that know how to (re)build it.  Kept out of input.lua so the
-- input module stays a pure dispatcher.

local Hotbar = require("mods.mapamap.components.hotbar")

local State = {}

-- Re-seeds the hotbar from a saved mod-save layout (or the default pick).
function State.configure(ui, initial)
  ui.hotbar = {}
  for i = 1, Hotbar.SLOTS do
    ui.hotbar[i] = initial and initial[i] or nil
  end
  ui.selected = 1
end

-- Serialized hotbar for persistence.
function State.serialize(ui)
  return ui.hotbar
end

-- Resets every transient editor flag for a fresh session open.  The brush
-- drag state (paint/erase arm, dedupe anchors) is cleared too.
function State.reset(ui, brush)
  brush.painting = false
  brush.erasing = false
  brush.draggingWarp = false
  brush.paintingMap = nil
  brush.lastBlockX = nil
  brush.lastBlockY = nil
  brush.lastCellX = nil
  brush.lastCellY = nil
  ui.mouseButtons = { [1] = false, [2] = false, [3] = false }
  ui.dragItem = nil
  ui.dragFromSlot = nil
  ui.pickerTilesetScroll = 1
  ui.pickerDropOpen = false
  ui.blueprintMode = false
  ui.selectStart = nil
  ui.selectEnd = nil
  ui._bpMoved = false
  ui.selectedWarp = nil
  ui.selectedObject = nil
  ui.warpDestPick = false
  ui.details = nil
  ui.inventory.tab = 1
  ui.inventory.scroll = 1
  ui.showInventory = true
  ui.showMapBorders = false
  ui._needsGraftRebuild = false
end

-- Re-points the picker and hotbar when the session switches to a new map
-- (walking across a border or adopting a created map).  The picker re-defaults
-- to the incoming map's tileset.  The hotbar is NOT re-seeded onto the incoming
-- tileset: block slots keep the tileset tag they were tagged with at placement
-- (Hotbar.tag), so the same tile stays selected and the graft layer re-imports
-- it whenever it is painted on a map with a different tileset.  The current
-- hotbar item is re-pointed at the Details/warp panel whenever the session (and
-- therefore def.warps) changes.
function State.onMapEntry(ui, session)
  -- Re-default the picker to the current map's tileset (featured first).
  ui.pickerTileset = nil
  ui.pickerScroll = 1
  ui.pickerTilesetScroll = 1
  ui.pickerDropOpen = false
  -- Warp selection / details reference live def.warps entries: drop them on a
  -- session change so they never dangle onto the old map's data.
  ui.selectedWarp = nil
  ui.selectedObject = nil
  ui.warpDestPick = false
  ui.details = nil
  if Hotbar.selected(ui) then Hotbar.apply(ui, session) end
end

-- Persists the hotbar layout through the mod save system.
function State.saveHotbar(ui, mod)
  mod.save:set("mapamap_hotbar", State.serialize(ui))
end

-- Persists the inventory collection through the mod save system.
function State.saveInventory(ui, mod)
  mod.save:set("mapamap_inventory", ui.inventory)
end

-- Loads the saved inventory collection ({ items, tab, scroll }).  Older saves
-- from the pre-inventory blueprint book are folded in so no captures are lost.
function State.loadInventory(ui, mod)
  local saved = mod.save:get("mapamap_inventory", nil)
  if saved and type(saved) == "table" and type(saved.items) == "table" then
    ui.inventory = saved
  else
    ui.inventory = { items = {}, tab = 1, scroll = 1 }
  end
  local book = mod.save:get("mapamap_blueprints", nil)
  if book and type(book) == "table" then
    for _, e in ipairs(book) do
      if e and e.id then
        local dupe = false
        for _, it in ipairs(ui.inventory.items) do
          if it.kind == "blueprint" and it.id == e.id then dupe = true; break end
        end
        if not dupe then
          ui.inventory.items[#ui.inventory.items + 1] =
            { kind = "blueprint", id = e.id, w = e.w, h = e.h, tiles = e.tiles }
        end
      end
    end
  end
end

return State
