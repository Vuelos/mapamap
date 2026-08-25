# mapamap

A live map editor mod for [gen1recomp](https://github.com/bryanthaboi/gen1recomp).

Paint blocks, drop NPCs/signs/warps, and reshape the overworld **directly on the
running game** -- Factorio-style. No editor screen, no restarts: you keep walking
around while the world changes under your cursor. Works on both generations.

> ## ⚠️ WARNING!
> **Save your game after editing the map** so you don't get stuck inside a solid
> block or outside the map bounds. If a change traps you, load your save.

*Mostly vibecoded.*

---

## Getting started

1. Drop this folder into your game's `mods/` directory.
2. Play, walk somewhere with room to work.
3. Press **F6** to open the editor overlay. Press **F6** or **Esc** again to
   close it -- everything you painted is saved automatically.

## The basics

- **Left-click / left-drag** paints the selected tile onto the world.
- **Right-click / right-drag** erases back to the original map.
- **Right-click an NPC, item, sign or warp** opens its Details panel --
  edit fields there, hit **MOVE** and then left-click a new spot to relocate
  it, or **REMOVE** to delete it.
- **Click any entity with left-click** to copy it onto your hotbar
  (signs keep their message).
- The player never stops moving -- the world stays live while you edit.

## Controls

### Keyboard

| Key        | Action                                          |
| ---------- | ----------------------------------------------- |
| `F6`       | Open / close the editor                         |
| `Esc`      | Close the editor (or the open panel)            |
| `1`–`8`    | Select a hotbar slot                            |
| `Q`        | Pick the tile under the cursor                  |
| `E`        | Tileset picker                                  |
| `F`        | Entity factory (NPCs, items, trainers, warps…)  |
| `R`        | Blueprint rectangle-select                      |
| `M`        | Brush Maker (terrain autotiling brushes)        |
| `V`        | Map Slots (save / load / export your edit-set)  |
| `N`        | Encounter editor                                |
| `O`        | Toggle map border outlines                      |
| `P`        | Toggle entity markers                           |
| `C`        | Pick a warp destination by clicking the world   |
| `Ctrl+Z` / `Ctrl+Y` | Undo / redo                           |
| `Tab`      | Toggle the inventory panel                      |

### Mouse

| Input                          | Action                                    |
| ------------------------------ | ----------------------------------------- |
| Left-click / drag              | Paint, place, or copy                     |
| Right-click                    | Erase / open Details on entities          |
| Mouse wheel                    | Scroll panels or cycle the hotbar         |
| Drag from picker/inventory     | Drop tiles onto hotbar slots              |
| Right-click inventory cell     | Edit that saved item                      |

## Map Slots (`V`)

Your whole edit-set -- every touched map, created map, encounter table,
connection and trainer party -- can be stored under a name and swapped later:

- **SAVE** captures the current edits (new slots are timestamp-named).
- **LOAD** swaps a stored set in; the previous state is auto-backed up as
  the `previous` slot.
- **EXPORT** writes `export/<name>.lua` next to the mod so edit-sets can be
  committed to the repo and shared -- click a file under **EXPORT FILES** to
  import someone else's.

Edits persist through the mod's own save data and are replayed whenever a
game save loads, so your maps survive quitting and reloading.
