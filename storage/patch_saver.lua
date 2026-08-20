-- Patch persistence for the map editor.
-- Builds minimal change-diff patches, saves/loads them via the mod save
-- system, and provides helpers for export and application.

local Common = require("mods.mapamap.common")
local SaveSerializer = require("src.core.SaveSerializer")
local Save = {}

local KEY = "mapamap_patches"
local ENC_KEY = "mapamap_encounter_patches"
local CONN_KEY = "mapamap_connection_patches"
-- Bulk export/import target: a single file in a map_edits/ subfolder of
-- the mod source, holding all three patch buckets at once.
local EXPORT_REL = "map_edits/patches.lua"
local tablesEqual = Common.tablesEqual

-- Builds a minimal patch containing only the fields that differ between
-- the current map definition and the original snapshot.
function Save.buildPatch(mapDef, original)
  local patch = {}
  local tracked = {"blocks", "warps", "objects", "signs", "borderBlock", "width", "height", "name", "textDefs", "connections", "connectionsExtra", "graftBlocks"}
  if original then
    for _, key in ipairs(tracked) do
      local cur = mapDef[key]
      local orig = original[key]
      if not tablesEqual(cur, orig) then
        patch[key] = cur
      end
    end
  else
    for _, key in ipairs(tracked) do
      patch[key] = mapDef[key]
    end
  end
  return patch
end

-- Returns all saved patches from the mod save data.
function Save.getPatches(mod)
  return mod.save:get(KEY, {})
end

-- Persists a patch for the given mapId into the mod save system.
function Save.savePatch(mod, mapId, patch)
  local patches = Save.getPatches(mod)
  patches[mapId] = patch
  mod.save:set(KEY, patches)
end

-- Sets a single field on an existing (or new) patch for mapId without
-- dropping any other fields the patch already carries.
function Save.updatePatchField(mod, mapId, key, value)
  local patches = Save.getPatches(mod)
  local patch = patches[mapId] or {}
  patch[key] = value
  patches[mapId] = patch
  mod.save:set(KEY, patches)
end

-- Removes the patch for the given mapId from the mod save data.
function Save.removePatch(mod, mapId)
  local patches = Save.getPatches(mod)
  patches[mapId] = nil
  mod.save:set(KEY, patches)
end

-- Applies a patches table (mapId -> patch) to Data.maps entries in place.
-- Returns the number of maps that were patched.  Missing data (a caller
-- holding a registry that has no maps yet) is a 0-apply no-op, never a crash.
function Save.applyPatchesToData(patches, data)
  local maps = data and data.maps
  if not (patches and maps) then return 0 end
  local applied = 0
  for mapId, patch in pairs(patches) do
    local target = maps[mapId]
    if target then
      for key, value in pairs(patch) do
        target[key] = value
      end
      -- Inject custom text defs into the text resolution system
      if patch.textDefs and data.text_pointers and data.text then
        for _, td in ipairs(patch.textDefs) do
          if not data.text_pointers[mapId] then
            data.text_pointers[mapId] = {}
          end
          data.text_pointers[mapId][td.const] = { text = td.key }
          data.text[td.key] = td.text
        end
      end
      applied = applied + 1
    end
  end
  return applied
end

-- Formats a patch as a Lua source string suitable for export.
-- Returns nil if no patch exists for the given mapId.
function Save.exportAsLua(mod, mapId)
  local patches = Save.getPatches(mod)
  local patch = patches[mapId]
  if not patch then return nil end
  local lines = {
    "-- Map editor patch for " .. mapId,
    "return {",
  }
  for key, value in pairs(patch) do
    if key == "blocks" then
      lines[#lines + 1] = "  blocks = {"
      local parts = {}
      for _, v in ipairs(value) do
        parts[#parts + 1] = tostring(v)
      end
      lines[#lines + 1] = "    " .. table.concat(parts, ", ")
      lines[#lines + 1] = "  },"
    elseif type(value) == "table" then
      local ok, enc = pcall(require("src.mods.Merge").encode, value)
      lines[#lines + 1] = "  " .. key .. " = " .. (ok and enc or "{}") .. ","
    else
      lines[#lines + 1] = "  " .. key .. " = " .. tostring(value) .. ","
    end
  end
  lines[#lines + 1] = "}"
  return table.concat(lines, "\n")
end

-- Saves an encounter patch for the given mapId.
function Save.saveEncounterPatch(mod, mapId, data)
  local patches = Save.getEncounterPatches(mod)
  patches[mapId] = data
  mod.save:set(ENC_KEY, patches)
end

-- Returns all saved encounter patches from the mod save data.
function Save.getEncounterPatches(mod)
  return mod.save:get(ENC_KEY, {})
end

-- Removes the encounter patch for the given mapId from the mod save data.
function Save.removeEncounterPatch(mod, mapId)
  local patches = Save.getEncounterPatches(mod)
  patches[mapId] = nil
  mod.save:set(ENC_KEY, patches)
end

-- Saves a connection patch for the given mapId.
function Save.saveConnectionPatch(mod, mapId, data)
  local patches = Save.getConnectionPatches(mod)
  patches[mapId] = data
  mod.save:set(CONN_KEY, patches)
end

-- Returns all saved connection patches from the mod save data.
function Save.getConnectionPatches(mod)
  return mod.save:get(CONN_KEY, {})
end

-- Removes the connection patch for the given mapId from the mod save data.
function Save.removeConnectionPatch(mod, mapId)
  local patches = Save.getConnectionPatches(mod)
  patches[mapId] = nil
  mod.save:set(CONN_KEY, patches)
end

-- Applies connection patches to data.connections.
function Save.applyEncounterPatches(patches, data)
  if not patches then return 0 end
  local applied = 0
  for mapId, encData in pairs(patches) do
    if data.encounters then
      data.encounters[mapId] = encData
      applied = applied + 1
    end
  end
  return applied
end

function Save.applyConnectionPatches(patches, data)
    if not patches then return 0 end

    for k, v in pairs(patches) do
        if data.connections then
          data.connections[k] = v
        end
    end
end

-- Writes a Lua file to the save directory under edited_maps/ and returns
-- the full path.
function Save.writeFile(mapId, luaContent)
  local path = "edited_maps/" .. mapId .. ".lua"
  love.filesystem.createDirectory("edited_maps")
  love.filesystem.write(path, luaContent)
  return love.filesystem.getSaveDirectory() .. "/" .. path
end

-- ------- bulk export/import (mods/<mod>/map_edits/patches.lua)

-- Game source root: the folder that holds the mods/ tree (the directory
-- passed to `love <gamedir>` in a source run).  Exports go there so the
-- edits land in the repo, where they can be committed and shared.
local function sourceRoot()
  if not (love and love.filesystem) then return nil end
  if love.filesystem.getSource then
    local src = love.filesystem.getSource()
    if src and src ~= "" then return src end
  end
  if love.filesystem.getSourceBaseDirectory then
    local sbd = love.filesystem.getSourceBaseDirectory()
    if sbd and sbd ~= "" then return sbd end
  end
  return nil
end

local SEP = package.config:sub(1, 1)
local mkdirFn

-- Windowless directory creation for an absolute path (FFI syscall with an
-- os.execute fallback), so an export never flashes a console window.
local function mkdir(path)
  if mkdirFn == nil then
    mkdirFn = false
    local ok, ffi = pcall(require, "ffi")
    if ok then
      if ffi.os == "Windows" then
        pcall(ffi.cdef,
          "int CreateDirectoryA(const char *lpPathName, void *lpSecurityAttributes);")
        local ok2, fn = pcall(function() return ffi.C.CreateDirectoryA end)
        if ok2 then mkdirFn = function(p) pcall(fn, p, nil) end end
      else
        pcall(ffi.cdef, "int mkdir(const char *pathname, unsigned int mode);")
        local ok2, fn = pcall(function() return ffi.C.mkdir end)
        if ok2 then mkdirFn = function(p) pcall(fn, p, 493) end end
      end
    end
  end
  if mkdirFn then return mkdirFn(path) end
  if SEP == "\\" then
    os.execute('mkdir "' .. path .. '" 2>nul')
  else
    os.execute('mkdir -p "' .. path .. '" 2>/dev/null')
  end
end

-- Creates every parent directory of an absolute forward-slash path.
local function ensureParents(absPath)
  local cur = ""
  for part in absPath:gmatch("[^/]+") do
    cur = cur .. part
    mkdir(cur)
    cur = cur .. "/"
  end
end

-- Writes a file on the real filesystem (love.filesystem.write only reaches
-- the save directory, so the game source is written with raw io instead).
-- Returns true, or false + an error message.
local function writeSourceFile(absPath, content)
  local dir = absPath:match("^(.*)/[^/]+$")
  if dir then ensureParents(dir) end
  local f, err = io.open(absPath, "wb")
  if not f then return false, err or ("cannot open " .. absPath) end
  f:write(content)
  f:close()
  return true
end

-- Collects every saved map edit (map, encounter and connection patches)
-- into one table keyed by bucket.
function Save.allEdits(mod)
  return {
    patches = Save.getPatches(mod),
    encounters = Save.getEncounterPatches(mod),
    connections = Save.getConnectionPatches(mod),
  }
end

-- Absolute filesystem path of the mod's map_edits/ export file.
function Save.exportPath(mod)
  local root = sourceRoot()
  if not root then return nil end
  return root .. "/" .. mod.path .. "/" .. EXPORT_REL
end

-- Writes every saved map edit to the mod's map_edits/patches.lua in the
-- game source folder.  Returns the absolute path, or nil + an error message.
function Save.exportAll(mod)
  local edits = Save.allEdits(mod)
  if not (next(edits.patches) or next(edits.encounters) or next(edits.connections)) then
    return nil, "no saved map edits to export"
  end
  local path = Save.exportPath(mod)
  if not path then return nil, "could not locate the game source folder" end
  local lua = SaveSerializer.encode(edits)
  local ok, err = pcall(writeSourceFile, path, lua)
  if not ok then return nil, tostring(err) end
  return path
end

-- Loads mods/<mod>/map_edits/patches.lua from the game source and writes
-- the decoded edits into the mod save buckets.  Returns the edits table,
-- or nil + an error message when the file is missing or invalid.
function Save.importAll(mod)
  local rel = mod.path .. "/" .. EXPORT_REL
  local raw = love and love.filesystem and love.filesystem.read
    and love.filesystem.read(rel)
  if not raw then return nil, "map_edits/patches.lua not found" end
  local edits, err = SaveSerializer.decode(raw)
  if not edits then return nil, tostring(err) end
  if edits.patches then mod.save:set(KEY, edits.patches) end
  if edits.encounters then mod.save:set(ENC_KEY, edits.encounters) end
  if edits.connections then mod.save:set(CONN_KEY, edits.connections) end
  return edits
end

return Save