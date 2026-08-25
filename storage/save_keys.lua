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
-- Edited trainer parties (class -> partyIndex -> party slots), applied over
-- data.trainers on replay so shared-team edits survive a reload.
Keys.TRAINER_PARTIES = "mapamap_trainer_parties"
-- Named map-slot snapshots ({ [name] = record }) written by the Map Slots
-- panel; each record snapshots every edit bucket at once.
Keys.SLOTS = "mapamap_slots"
-- Crash log written by main.lua's error handler.
Keys.CRASH_LOG = "mapamap_crash.log"

return Keys
