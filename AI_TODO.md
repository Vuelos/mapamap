## Bugs

1. Map expansion desyncs neighbors — when a map grows into an area that touches other maps (connected or not), their state diverges. Goal: fill empty space but leave existing maps untouched, regardless of editor-side sizing or connections. `expand` should only be used for external maps when no map exists in that direction. If a map exists on a direction neighboor or not, create a bridge map sized to close the gap (current map H/W + needed delta) and wire a 2-way connection.

2. Blueprints do not correctly handle placement across multiple connected maps.

## Features

4. use tiles from any tileset on any map

5. Create a Factorio-style inventory component, positioned to the left of the palette picker and blueprints panels (move picker and blueprints right; same size/positioning; one panel active at a time).

6. Replace the current blueprint bar with inventory-based blueprint storage.

7. Allow placing tiles, objects, and warps from the inventory.

8. Right-click an object in inventory to open a Details panel for editing name, text, etc.

9. Render warps as circles (like `map_editor`). Add graphical warp editing: pick destination map with cursor and set coordinates visually.
