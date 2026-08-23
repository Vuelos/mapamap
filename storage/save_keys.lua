-- Single owner of every mod-save bucket name and persisted-filename literal
-- the mapamap mod writes.  A rename or collision audit touches exactly this
-- file; every consumer requires Keys and reads a field.

local Keys = {}

-- Diff patches for edited existing maps (mapId -> { field = value, ... }).
Keys.PATCHES = "mapamap_patches"
-- Gen-specific encounter diff patches.
Keys.ENCOUNTER_PATCHES = "mapamap_encounter_patches"
-- Extra editor-only connection diff patches.
Keys.CONNECTION_PATCHES = "mapamap_connection_patches"
-- Whole defs of maps created by the overlay (data.maps has nothing to diff).
Keys.NEW_MAPS = "mapamap_new_maps"
-- Hotbar slot layout.
Keys.HOTBAR = "mapamap_hotbar"
-- Persistent inventory collection (tiles/entities/blueprints/brushes).
Keys.INVENTORY = "mapamap_inventory"
-- Pre-inventory blueprint book; folded into INVENTORY on load.
Keys.LEGACY_BLUEPRINTS = "mapamap_blueprints"
-- Crash log written by main.lua's error handler.
Keys.CRASH_LOG = "mapamap_crash.log"

return Keys
