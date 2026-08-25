# mapamap

Factorio-style on-map map editor. Toggle with **F6** while in the overworld,
then paint blocks and place debug NPCs directly on the live game render using
the mouse. A centered square hotbar and a pop-up tileset picker (creative style)
replace the full-screen editor UI of the underlying `map_editor` mod.

## How it works

Instead of pushing an opaque editor screen, `mapamap` draws an **overlay over
the running game** and forwards mouse input to it. The map data it edits is the
live `Data.maps` table the game already draws from, so a paint immediately
shows up in the world. Changes persist as diff patches in the mod save when the
overlay closes.

Entry: `main.lua` toggles F6, registers the `render.hud` hook, and wraps the
`love.*` mouse callbacks while active.

| Module             | Responsibility                                                            |
| ------------------ | ------------------------------------------------------------------------- |
| `main.lua`         | F6 toggle, hook/wrap registration; all session work delegated to `controllers/session_manager.lua` |
| `controllers/session_manager.lua` | Session lifecycle: `open`/`close`, `autoSave`/persist (diff patches + whole new maps + hotbar/inventory), `reconcile` on map-border walk, grid expansion (`MapGrid.autofill`) on open/entry, `createAdjacentMap`, `replayPatches` on save.loaded, `activateSlot` (map-slot switching) |
| `controllers/editor_tools.lua` | Brush/tool drag state (paint/erase arms, dedupe anchors, entity-drag ghost, void-stroke buffer) + `apply`/`erase`/`commitVoidStroke` routing into `domain/paint.lua`; single owner of the `brush` table passed to Paint |
| `domain/edit_session.lua` | Editor state; mixes in `domain/map_ops`, `domain/editor_neighbors`, `domain/warps`; warp/object placement helpers, `paintedBlocks`, `createMapAtCursor` (paint-time void creation) |
| `domain/map_grid.lua`| Load-time grid expansion (`autofill`) + paint-time void creation (`createForBlocks`/`createForPaint`): BFS layout, open-void candidates, `createMap` (reciprocal flush wiring) |
| `controllers/input.lua` | Pure input dispatch (press/release/move/wheel/key) + the Input controller table; brush state reads/writes delegated to `controllers/editor_tools.lua`, every operation delegates to a focused module below |
| `engine/coords.lua` | Screen <-> world mapping through the live camera + fit-scale/zoom         |
| `storage/config.lua`| UI controller lifecycle: hotbar configure/serialize, reset, per-map re-pointing, hotbar/inventory save/load |
| `domain/blueprints.lua`| Rectangle-select capture (R) and blueprint stamping                        |
| `domain/brushes.lua` | Terrain brush model: 20 optional slot positions (core 3x3, inner corners, v/h corridors, borderless line runs ln/ls/lw/le, isolated o), join-mask `pickKey` with fallback chains toward the required center, block membership (native/grafted/verbatim) |
| `domain/paint.lua` | Paint/erase/pick/dest-pick world operations through the session's MapOps; triggers paint-time map creation on void; routes `kind = "brush"` items to `MapOps.paintBrush` |
| `components/overlay.lua`| Draws cursor highlight, a translucent blueprint placement preview (ghost stamp + green footprint outline replacing the plain cursor while a blueprint is selected), blueprint rect, warp circles for every map laid out around the one being rendered (root + neighbors, each at its world offset), dest-pick crosshair, hotbar, inventory, tileset picker, Details panel via `render.hud`; world markers draw first so panels always render above them, and a picked-up item (hotbar/picker drag) floats above everything faded. Warps are enumerated in the RUNTIME's frame (`ow.map` + `ow.neighbors` strip offsets, falling back to the session) so circles stay glued to their tiles across a border cross instead of floating in the stale session anchor |
| `components/hotbar.lua`| Centered square 10-slot hotbar geometry + draw + selection model (tag/selected/apply/loadItem) |
| `components/picker.lua`| Tileset picker panel: catalog (Items & NPCs first), dropdown, grid, draw |
| `components/inventory.lua`| Persistent left panel with category tabs (Tiles/Entities/Blueprints/Brushes); each tab's FIRST grid cell is that tab's own toolbar shortcut ([E] tileset picker, [F] entity factory, [R] blueprint rect-select, [M] Brush Maker; letters draw in caps) and the rest of the grid lists only the stored collection (`tabFor` / `listFor`); adds from hotbar drops file the item silently onto its respective tab, creator/blueprint saves jump to theirs; also the collection model (add/list) |
| `components/item.lua`  | Shared slot thumbnail renderer (blocks, sprites, items, blueprints, warps, objects, brushes)   |
| `components/brush_editor.lua` | Brush Maker panel (toolbar `M`): spatial two-layout slot grid — a 5x5 main grid (core 3x3 centered, inner corners on the panel corners) over a complete 5x5 line cross (borderless runs ln/ls/lw/le at the arm tips, v/h corridors inner on their axes, isolated o at the cross center; nonexistent join positions render as dim placeholders); tiles are dragged/clicked in from the hotbar/picker/inventory, RMB clears a slot, SAVE stores `{ kind = "brush" }` in the inventory's Brushes tab; RMB on a saved brush cell loads it back into the maker |
| `components/slot_panel.lua` | Map Slots panel (toolbar `V`): save-slot manager for the whole edit-set — slots list (click selects, wheel scrolls), action strip (SAVE / LOAD / NEW / RENAME / DEL / EXPORT), and the export-folder listing (`export/*.lua`; click imports). RENAME types inline (printables append, Backspace trims, Enter commits via `Slots.rename`, Esc cancels); all panel state lives on Input (`slotsOpen`, `slotSel`, `slotRename`, `slotScroll`, `slotFileScroll`, `slotMsg`) |
| `storage/slots.lua` | Map-slot persistence: a slot deep-copies ALL five edit buckets (patches / encounters / connections / newMaps / trainerParties) under a name in `mapamap_slots`. `applyBuckets` is a FULL bucket replacement (activation never merges), export/import move records through `export/<name>.lua` under the mod's own folder — always via `love.filesystem` (sandbox-safe: reads fall through to the mod source, writes land in its compat overlay; raw `io.open` is stripped). The auto `previous` slot is written by every LOAD as a recoverable pre-swap backup |
| `components/details.lua`| Modal Details panel for warps + objects + inventory items (Pos/Dest/name/label, nudge); bottom action strip (MOVE / EDIT / REMOVE); keyboard: Up/Down, L/R: +/-, Enter: edit, X: delete, M: move, E: edit entity; open/close/keyboard model |
| `components/entity_creator.lua` | Creator form for NPCs / items / trainers / mons / shops / warps / signs. NEW arms the hotbar slot on CREATE; EDIT (via Details strip) applies written changes back to the placed entity; right-click an inventory cell to edit it |
| `domain/` `engine/` `storage/` | Reused data operations from `map_editor` split by concern: `domain/*` pure data/state mutators, `engine/*` game & LÖVE bridges (gen, graft, coords, world_adapter), `storage/*` persistence (patch_saver, config) |
| `domain/warps.lua` | Warp editing operations (place, move, remove, connect, label) mixed into Session |
| `engine/world_adapter.lua` | Engine/rendering bridge: Gen 1 renderer rebuilds, Gen 2 canvas drop/re-bake, live NPC pool sync, `applySavedPatches`, `createAdjacentMap`, `reconcileSession` |

### Control map (while the overlay is open)

| Action                       | Input                                   |
| ---------------------------- | --------------------------------------- |
| Toggle overlay               | `F6` (or `Esc` closes)                    |
| Paint selected block         | Left-click / left-drag over the world   |
| Erase back to saved baseline | Right-click / right-drag                |
| Select hotbar slot           | Click slot, or `1`–`8`                  |
| Pick block under cursor      | `Q`                                     |
| Undo / redo                  | `Ctrl+Z` / `Ctrl+Y` (covers block paints, warps, objects) |
| Open / close picker          | `E`                                     |
| Choose tileset in picker     | Open the header dropdown and click a name |
| Scroll picker / hotbar       | Mouse wheel                             |
| Scroll dropdown list         | Wheel over the open dropdown list       |
| Drag picker item to slot     | LMB-drag from panel onto a hotbar slot  |
| Drag a hotbar item           | LMB-drag a slot onto another slot (swap) or onto the inventory (copy) |
| Blueprint placement preview  | With a blueprint in the active slot, a translucent ghost stamp + green footprint shows exactly where the next LMB places |
| Toggle rectangle-select      | `R` (drag or click two corners; captures the area into the Blueprints tab) |
| Stamp a blueprint            | Load it into a slot, then LMB paint     |
| Open Brush Maker             | `M` (or the toolbar M button); hides with the inventory |
| Fill a brush slot            | Drag a tile in, or click the slot with a tile on the hotbar; RMB clears a slot; click a filled slot with nothing selected grabs its tile |
| Save / clear / delete        | SAVE (needs only the center tile) stores it in the Brushes tab — updating the loaded brush in place when it was RMB-loaded; CLEAR empties every slot; DELETE removes the loaded brush from the inventory (draft keeps its slots) |
| Paint a terrain brush        | Load a saved brush into a slot, then LMB paint — each cell picks its tile from the join mask and surrounding brush cells re-blend |
| Edit a saved brush           | RMB a Brushes-tab cell loads it into the maker |
| Place a warp                 | Load an Entities-tab cell (or build one in the factory) into a slot, then LMB paint. The New Warp template places exactly ONE self-destined warp (no return pair) |
| Place / copy an object       | Entities-tab cells load copy tools; the entity factory ([F]) configures fresh NPCs / items / trainers / mons / shops and CREATE arms the hotbar slot; both paint with LMB (1x1 cell). Placements follow the cursor across seams onto laid-out neighbors (`Session.targetAt` + `withTargetDef`, neighbor diffs flagged via `refreshNeighborMap`). A picked-up SIGN tool clones the original message silently (no Details popup). Creator tools keep their `create` spec when re-loaded from the inventory. RMB an inventory cell to edit it in the creator form |
| Move a warp                  | MOVE on its Details panel arms a relocation carried on `Input.moveTarget` — the next LMB lands the entity, following the laid-out map that owns the destination cell (`relocateEntityWorld`: fresh index on seam crossings, both defs captured for undo). Right-click NEVER drags: it opens Details at press |
| Graphical dest pick          | `C`, then click the destination on the world     |
| Open Details / rename        | RMB an inventory cell, or any world warp / object / sign |
| Edit a field (Details)       | Up/Down: field, Left/Right: +/-, Enter: edit, X: delete, M: move, E: edit entity, Esc: close; click a row selects it (Enter edits), actions (encounters / team) run on click |
| MOVE / EDIT / REMOVE buttons | Bottom strip of the Details panel for live world entities; MOVE arms a relocation carried on `Input.moveTarget` (next LMB lands the entity), EDIT reopens the entity in its creator form, REMOVE deletes it |
| Open Map Slots               | `V` (or the toolbar V button); Esc closes |
| Save a map slot              | Click a slot row (or NEW for a fresh YY.MM.DD.HH.MM.SS timestamp), then SAVE — captures the whole live edit-set under that name |
| Load / rename / delete       | LOAD swaps the stored edit-set in (auto-backup to the `previous` slot first, then replays into the running world and reopens the session); RENAME types inline (Enter commits, Esc cancels); DEL removes it |
| Export / import slots        | EXPORT writes `export/<name>.lua` next to the mod source; clicking a file under EXPORT FILES imports it as a new slot |
| Scroll Map Slots lists       | Wheel over the slots list or the export-files list |
| Blueprint / inventory save   | `mapamap_inventory` on close (F6)       |

### Map slots

The Map Slots panel (`V`) versions the WHOLE edit-set, not single maps: a slot
snapshot deep-copies all five persistence buckets (patches, encounter
patches, connection patches, new maps, trainer parties) under a name in
`mapamap_slots`. NEW/SAVE default to a YY.MM.DD.HH.MM.SS capture timestamp
(same-second captures step forward; export files inherit the name as
`<name>.lua`), RENAME gives custom names. LOAD is a full bucket replacement
followed by `SessionManager.replayPatches` + a fresh session open, so most
edits show up immediately; maps painted by the outgoing set but untouched by
the loaded one keep their look until the game save reloads. Every LOAD first
stashes the live buckets as the auto `previous` slot. EXPORT/IMPORT share
`mods/mapamap/export/<name>.lua` files (SaveSerializer grammar), so edit-sets
can be committed to the repo and shared like `map_edits/patches.lua`.

### Expand vs. create at the edges

### Grid expansion runs on load; paint-time creation fills adjacent void

Map growth happens at two points:

1. **Load-time autofill** (`MapGrid.autofill`): `main.lua` calls this right
   after `applySavedPatches()` when the overlay opens (F6).  It closes open
   voids within `DEFAULT_DEPTH` hops of the loaded map.

2. **Paint-time creation** (`MapGrid.createForBlocks`/`createForPaint`): when
   a block or blueprint is painted on void adjacent to a laid-out map, a new
   `_EXT` map is created flush against the nearest host.  The new map is wired
   with reciprocal connections and appears as a neighbor immediately — no
   session switch is needed.  Painting far from any laid-out map (no flush
   contact possible) stays a no-op.

The paint-time path (`domain/paint.lua`) calls `Session:createMapAtCursor()`
which delegates to `MapGrid.createForPaint` (single block) or
`MapGrid.createForBlocks` (blueprint rect).  Blueprint stamps detect void
cells in the stamp rect and pre-create the map before the stamp loop runs.

`domain/map_grid.lua` derives world placement from the connection graph alone
(BFS over connection offsets — no schema change, root world-anchored at
(0,0)):

- **Multi-connection sides**: a side can carry MORE than one connection.
  `def.connections[dir]` keeps the single engine-visible primary (the first
  connection on that side); editor-only extras live in
  `def.connectionsExtra[dir]`. `Connections.connectionsOn(def, dir)` returns the
  union and every grid/neighbor traversal walks it. Each connection records a
  `size` (its seam span in blocks) so connections on a side never overlap.
- **Seam gaps** (`seamGaps`/`edgeCoverage`): the free seams of a layout member
  are derived from the ACTUAL laid-out map bodies flush against it, not from
  connection fields. A legacy connection without a `size` restricts nothing on
  its own — only the map it places covers the seam.
- **Candidates**: every open gap-fill void (a rect sitting flush on a free
  seam segment of a depth-capped layout member, not overlapping the full
  reachable layout, sized to the leftover gap width) scored by how many laid-out
  maps accept a connection to it (`contactAccepts` rejects only when the
  void's seam span would overlap an existing connection's `size` there). A side
  may already carry connections — a partial cover just leaves smaller gap voids
  that slot into the leftover space instead of being rejected outright.
- **Create** (`createMap`): a new `_EXT` map wired via
  `Connections.addConnection` (2-way) to every accepting flush contact — an
  occupied side stacks an extra instead of clobbering the primary — tracked
  whole under `mapamap_new_maps` (snapshot taken AFTER wiring) so it persists
  across a reload. Wired existing maps are marked `neighborDirty` so their
  `connectionsExtra` diff patches survive.
- **Fill** (`fillNextVoid`/`bestVoid`): create at the highest-connectivity
  void (tie-break: lowest bx, then by); `expandInDirection(dir)` prioritizes
  one direction; `autofill` fills until no void remains, capped at 64 new maps.
  Default depth is 1, so a pass only extends one layer past the current map.

The engine reads only `connections[dir]`, so extra-connected maps are
editor/overlay-only (their seam crossing is not walked by the runtime
neighbor set).

Undo/redo covers block paints, warps, and objects; **created grid maps are
not** undo steps (their `_newMaps` persistence is separate).

## Coordinate model

The overlay converts the mouse's LOVE screen units to world cells using the
same flat world blit math as `src/render/Renderer.endFrame`:

```
screenUnit = wox + (worldPx - cam.x) * sx
worldPx    = cam.x + (screenUnit - wox) / sx
```

where `sx = Zoom.scale(fitScale)/dpiX`, `wox` is the centered letterbox origin,
and `cam` is `overworld.camera`. **Tilt mode** projects the ground plane
through a perspective mesh, so editing is gated off while `Tilt.active()`.

Block IDs are the tileset's numeric indices (cells are 16 px, blocks are 2x2
cells = 32 px); sprites are `Data.sprites` string ids. Mode coordinates for
map objects are **walk-grid cells** (`px = x * 16`), so sprite placement and
block painting resolve through the same cursor cell.

## Reusing `map_editor` code

The `domain/` `engine/` `storage/` files are copied from `mods/map_editor` with
the internal `mods.map_editor.` requires rewritten to `mods.mapamap.`.
They expect an editor-shaped object (`mod, game, data, mapId, def, tileset,
map, cursorBx/ cursorBy, selectedBlock, mapChanged, undo, neighbors,
neighborMaps, neighborOriginals, neighborDirty, expandShiftL/T,
_originalSnapshot, ...`) which `domain/edit_session.lua` provides and
`controllers/input.lua` fills.

Do **not** pull in the full-screen scene modules (`scene/*`, `renderer/drawing`)
— the overlay draws its own UI. Save keys are namespaced (`mapamap_patches`,
`mapamap_hotbar`, `mapamap_inventory`, `mapamap_new_maps`; legacy
`mapamap_blueprints` is folded into the inventory on load) so both mods can
coexist without clobbering each other.

## Build & verification

- This is a LÖVE project; run with `love <gamedir>` after placing the mod in
  `mods/`.
- Validate a single file's syntax with `luajit -b <file> out` (exit 0 = OK).
- Run the headless unit suites (grid model, connection graph, coords
  round-trip, picker catalog) with
  `luajit mods/mapamap/tests/test_all.lua` — exits 1 on failure.
  Each suite lives in `mods/mapamap/tests/<name>_tests.lua` as individual files.

## Practices

- Keep the overlay non-opaque; the player keeps walking while editing (F6 must not
  pause the game.
- Everything drawn through `render.hud` runs in LOVE screen units — always
  `love.graphics.push("all")` + `origin()` and restore color.
- Guard all love input wrappers with the `active` flag so the vanilla game is
  untouched when the overlay is closed.
- Use `storage/patch_saver`'s diff/patch helpers rather than writing whole maps;
  new maps are stored whole under `mapamap_new_maps`.
- Paint-time map creation (`createForBlocks`/`createForPaint`) fires when the
  cursor lands on void adjacent to a laid-out map.  The created map is wired
  with reciprocal connections immediately; no session switch or undo step is
  pushed for the creation itself (only the block paint that follows).