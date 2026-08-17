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
| `session.lua`      | Editor state; mixes in `func/map_ops`, `func/editor_neighbors`, `func/warps`; warp/object placement helpers, `paintedBlocks`, `createMapAtCursor` (paint-time void creation) |
| `func/map_grid.lua`| Load-time grid expansion (`autofill`) + paint-time void creation (`createForBlocks`/`createForPaint`): BFS layout, open-void candidates, `createMap` (reciprocal flush wiring) |
| `input.lua`        | Pure input dispatch (press/release/move/wheel/key) + the Input controller table; every operation delegates to a focused module below |
| `func/coords.lua`  | Screen <-> world mapping through the live camera + fit-scale/zoom         |
| `func/state.lua`   | UI controller lifecycle: hotbar configure/serialize, reset, per-map re-pointing, hotbar/inventory save/load |
| `func/blueprints.lua`| Rectangle-select capture (R) and blueprint stamping                        |
| `func/paint.lua`   | Paint/erase/pick/dest-pick world operations through the session's MapOps; triggers paint-time map creation on void |
| `components/overlay.lua`| Draws cursor highlight, a translucent blueprint placement preview (ghost stamp + green footprint outline replacing the plain cursor while a blueprint is selected), blueprint rect, warp circles for every map laid out around the one being rendered (root + neighbors, each at its world offset), dest-pick crosshair, hotbar, inventory, tileset picker, Details panel via `render.hud`; world markers draw first so panels always render above them, and a picked-up item (hotbar/picker drag) floats above everything faded. Warps are enumerated in the RUNTIME's frame (`ow.map` + `ow.neighbors` strip offsets, falling back to the session) so circles stay glued to their tiles across a border cross instead of floating in the stale session anchor |
| `components/hotbar.lua`| Centered square 10-slot hotbar geometry + draw + selection model (tag/selected/apply/loadItem) |
| `components/picker.lua`| Tileset picker panel: catalog (Items & NPCs first), dropdown, grid, draw |
| `components/inventory.lua`| Persistent left panel with category tabs (Tiles/Objects/Warps/Blueprints); each tab's grid is split by a labelled divider — the CURRENT MAP's live content on top (Tiles: unique painted blocks, Objects: live `def.objects`, Warps: live `def.warps`, each with a trailing template cell) and the stored collection below (`tabList` / `paintedBlocks`); also the collection model (add/list) |
| `components/item.lua`  | Shared slot thumbnail renderer (blocks, sprites, items, blueprints, warps, objects)   |
| `components/details.lua`| Modal Details panel for warps + objects + inventory items (Pos/Dest/name/label, nudge, DELETE via keyboard or click); open/close/keyboard model |
| `func/*.lua`       | Reused data operations from `map_editor` (diff, undo, neighbors, save)     |
| `func/warps.lua`   | Warp editing operations (place, move, remove, connect, label) mixed into Session |

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

The paint-time path (`func/paint.lua`) calls `Session:createMapAtCursor()`
which delegates to `MapGrid.createForPaint` (single block) or
`MapGrid.createForBlocks` (blueprint rect).  Blueprint stamps detect void
cells in the stamp rect and pre-create the map before the stamp loop runs.

`func/map_grid.lua` derives world placement from the connection graph alone
(BFS over connection offsets — no schema change, root world-anchored at
(0,0)):

- **Multi-connection sides**: a side can carry MORE than one connection.
  `def.connections[dir]` keeps the single engine-visible primary (the first
  connection on that side); editor-only extras live in
  `def.connectionsExtra[dir]`. `Common.connectionsOn(def, dir)` returns the
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
  `Common.addConnection` (2-way) to every accepting flush contact — an
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
- Paint-time map creation (`createForBlocks`/`createForPaint`) fires when the
  cursor lands on void adjacent to a laid-out map.  The created map is wired
  with reciprocal connections immediately; no session switch or undo step is
  pushed for the creation itself (only the block paint that follows).