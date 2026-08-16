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
| `main.lua`         | F6 toggle, hook/wrap registration, auto-save on close, patch replay, `MapGrid.autofill` on open/load |
| `session.lua`      | Editor state; mixes in `func/map_ops`, `func/editor_neighbors`; warp/object placement helpers, `paintedBlocks` |
| `func/map_grid.lua`| Load-time grid expansion: BFS layout from connection offsets, open-void candidates, `createMap` (reciprocal flush wiring), `autofill` |
| `input.lua`        | Pure input dispatch (press/release/move/wheel/key) + the Input controller table; every operation delegates to a focused module below |
| `func/coords.lua`  | Screen <-> world mapping through the live camera + fit-scale/zoom         |
| `func/state.lua`   | UI controller lifecycle: hotbar configure/serialize, reset, per-map re-pointing, hotbar/inventory save/load |
| `func/blueprints.lua`| Rectangle-select capture (R) and blueprint stamping                        |
| `func/paint.lua`   | Paint/erase/pick/dest-pick world operations through the session's MapOps  |
| `components/overlay.lua`| Draws cursor highlight, blueprint rect, warp circles for every map laid out around the one being rendered (root + neighbors, each at its world offset), dest-pick crosshair, hotbar, inventory, tileset picker, Details panel via `render.hud`; world markers draw first so panels always render above them. Warps are enumerated in the RUNTIME's frame (`ow.map` + `ow.neighbors` strip offsets, falling back to the session) so circles stay glued to their tiles across a border cross instead of floating in the stale session anchor |
| `components/hotbar.lua`| Centered square 10-slot hotbar geometry + draw + selection model (tag/selected/apply/loadItem) |
| `components/picker.lua`| Tileset picker panel: catalog (Items & NPCs first), dropdown, grid, draw |
| `components/inventory.lua`| Persistent left panel with category tabs (Tiles/Objects/Warps/Blueprints); each tab's grid is split by a labelled divider — the CURRENT MAP's live content on top (Tiles: unique painted blocks, Objects: live `def.objects`, Warps: live `def.warps`, each with a trailing template cell) and the stored collection below (`tabList` / `paintedBlocks`); also the collection model (add/list) |
| `components/item.lua`  | Shared slot thumbnail renderer (blocks, sprites, items, blueprints, warps, objects)   |
| `components/details.lua`| Modal Details panel for warps + objects + inventory items (Pos/Dest/name/label, nudge, DELETE via keyboard or click); open/close/keyboard model |
| `func/*.lua`       | Reused data operations from `map_editor` (diff, undo, neighbors, save)     |

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
| Toggle rectangle-select      | `R` (drag to grab a block area)         |
| Open Blueprints tab          | `B`                                     |
| Stamp a blueprint            | Load it into a slot, then LMB paint     |
| Place a warp                 | Load a Warps-tab cell (or the New Warp template) into a slot, then LMB paint. The template places exactly ONE self-destined warp (no return pair) |
| Place / copy an object       | Objects-tab live cell loads a copy tool; the New Object template creates a fresh NPC; both paint with LMB (1x1 cell) |
| Move a warp                  | Right-drag a warp to its new cell       |
| Graphical dest pick          | `C`, then click the destination on the world     |
| Open Details / rename        | RMB an inventory cell, a world warp, or a world object |
| Edit a field (Details)       | Up/Down: field, Left/Right: +/-, Enter: edit, X: delete, Esc: close; click a row selects it (Enter edits), the DELETE row runs on click |
| Blueprint / inventory save   | `mapamap_inventory` on close (F6)       |

### Expand vs. create at the edges

### Grid expansion runs on load, never on paint

Map growth is a **load-time** operation: `main.lua` calls
`MapGrid.autofill(session, MapGrid.DEFAULT_DEPTH)` right after
`applySavedPatches()` when the overlay opens (F6) and again when the player
walks onto a different map. Painting a block off the current map's body simply
no-ops (`input.lua` returns `false` for edge cells) — nothing is created or
grown at paint time.

`func/map_grid.lua` derives world placement from the connection graph alone
(BFS over connection offsets — no schema change, root world-anchored at
(0,0)):

- **Candidates**: every open-void cell (a map-footprint rect sitting flush on
  a side of a depth-capped layout member, not overlapping the full reachable
  layout) scored by how many laid-out maps it touches. A void is only usable
  when every flush contact's reciprocal connection side is still free, so
  creating it can never clobber an existing connection.
- **Create** (`createMap`): a new `_EXT` map wired with a 2-way connection to
  every free flush contact, tracked whole under `mapamap_new_maps` (snapshot
  taken AFTER wiring) so it persists across a reload.
- **Fill** (`fillNextVoid`/`bestVoid`): create at the highest-connectivity
  void (tie-break: lowest bx, then by); `expandInDirection(dir)` prioritizes
  one direction; `autofill` fills until no void remains, capped at 64 new maps.
  Default depth is 1, so a pass only extends one layer past the current map.

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

The `func/` files are copied from `mods/map_editor` with the internal
`mods.map_editor.` requires rewritten to `mods.mapamap.`.
They expect an editor-shaped object (`mod, game, data, mapId, def, tileset,
map, cursorBx/ cursorBy, selectedBlock, mapChanged, undo, neighbors,
neighborMaps, neighborOriginals, neighborDirty, expandShiftL/T,
_originalSnapshot, ...`) which `session.lua` provides and `input.lua` fills.

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
- Use `func.save`'s diff/patch helpers rather than writing whole maps; new maps
  are stored whole under `mapamap_new_maps`.
- Map creation only happens in `MapGrid` at load (F6 open / map entry); never
  grow or create maps from a paint/erase handler.