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
| `main.lua`         | F6 toggle, hook/wrap registration, auto-save on close, patch replay       |
| `session.lua`      | Editor state; mixes in `func/map_ops`, `func/editor_neighbors`; object placement |
| `input.lua`        | Brush logic: paint/erase/pick, hotbar select, picker drag, wheel scroll       |
| `func/coords.lua`  | Screen <-> world mapping through the live camera + fit-scale/zoom         |
| `components/overlay.lua`| Draws cursor highlight, hotbar, tileset picker via `render.hud`        |
| `components/hotbar.lua`| Centered square 8-slot hotbar geometry + draw                            |
| `components/picker.lua`| Tileset picker panel: catalog (Items & NPCs first), grid, geometry, draw |
| `components/item.lua`  | Shared slot thumbnail renderer (blocks, sprites, items, blueprints)   |
| `components/blueprints.lua`| Blueprint book panel geometry + draw                                  |
| `func/*.lua`       | Reused data operations from `map_editor` (diff, undo, neighbors, save)     |

### Control map (while the overlay is open)

| Action                       | Input                                   |
| ---------------------------- | --------------------------------------- |
| Toggle overlay               | `F6` (or `Esc` closes)                    |
| Paint selected block         | Left-click / left-drag over the world   |
| Erase back to saved baseline | Right-click / right-drag                |
| Select hotbar slot           | Click slot, or `1`–`8`                  |
| Pick block under cursor      | `Q`                                     |
| Undo / redo                  | `Ctrl+Z` / `Ctrl+Y`                     |
| Open / close picker          | `E`                                     |
| Choose tileset in picker     | Click its name in the left list   |
| Scroll picker / hotbar       | Mouse wheel                             |
| Scroll tileset name list     | Wheel over the left list               |
| Drag picker item to slot     | LMB-drag from panel onto a hotbar slot  |
| Toggle rectangle-select      | `R` (drag to grab a block area)         |
| Open / close blueprint book  | `B`                                     |
| Stamp a blueprint            | Load it into a slot, then LMB paint     |
| Blueprint book save          | `mapamap_blueprints` on close (F6)      |

### Expand vs. create at the edges

Painting a block off the map's body runs a decision rule instead of always
growing the current map (`Session:handleEdgePaint` → `NewMap.expandOrCreate`):

- **Expand**: when the map's dimension parallel to the side (width for
  north/south, height for east/west) is **lower than** the map directly on the
  opposite edge, the current map is grown to match it (keeping the seam
  anchored at 0).
- **Create**: otherwise a new `_EXT` map is placed at the edge in the correct
  world position and wired with a **2-way connection to every map it touches**
  (`NewMap.createSidedMap` driven by `Neighbors.probePlacement`/`mapRectAt`),
  not just the source map.

The new map is tracked whole under `mapamap_new_maps` so it persists across a
reload.

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
`mapamap_hotbar`, `mapamap_new_maps`, `mapamap_blueprints`) so both mods can
coexist without clobbering each other.

## Build & verification

- This is a LÖVE project; run with `love <gamedir>` after placing the mod in
  `mods/`.
- Validate a single file's syntax with `luajit -b <file> out` (exit 0 = OK).
- Run the headless unit suites (connection graph, coords round-trip, picker
  catalog) with `luajit mods/mapamap/tests/test_all.lua` — exits 1 on failure.
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