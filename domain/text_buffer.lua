-- TextBuffer: the pure editing model behind the dialog composer.
--
-- A buffer is a plain string using the engine's own text markers -- "\n"
-- starts the second line, "\f" is a page break -- so what the editor stores
-- is byte-for-byte what the game's TextBox prints.  The caret is a
-- (line, column) pair over the SPLIT lines; every mutation re-joins into
-- `text` and clamps the caret.  No love.* and no rendering here: this file
-- is the part tests exercise headlessly.

local TextBuffer = {}

-- Splits into logical lines on "\n".  A "\f" page break stays INLINE in its
-- line (the view draws it as [PB]); the paginator treats it as a boundary.
function TextBuffer.lines(text)
  local out = {}
  for line in (tostring(text or "") .. "\n"):gmatch("(.-)\n") do
    out[#out + 1] = line
  end
  if #out == 0 then out[1] = "" end
  return out
end

function TextBuffer.join(lines)
  return table.concat(lines, "\n")
end

local function clamp(d)
  d.curLine = math.max(1, math.min(d.curLine or 1, #d.lines))
  local l = d.lines[d.curLine] or ""
  d.curCol = math.max(1, math.min(d.curCol or 1, #l + 1))
end

local function line(d)
  return d.lines[d.curLine] or ""
end

-- Re-joins the (already mutated) line list into text and clamps the caret.
local function touch(d)
  d.text = TextBuffer.join(d.lines)
  clamp(d)
end

-- Loads text and parks the caret at the very end.
function TextBuffer.setText(d, text)
  d.text = tostring(text or "")
  d.lines = TextBuffer.lines(d.text)
  d.curLine = #d.lines
  d.curCol = #(d.lines[#d.lines] or "") + 1
end

function TextBuffer.getText(d)
  clamp(d)
  return d.text
end

local function isLetter(ch)
  return #ch == 1 and ch:match("%a") ~= nil
end

-- Inserts one resolved character at the caret.  Letters are upper-cased when
-- CAPS is armed (Shift was already applied by the caller).
function TextBuffer.insertChar(d, ch)
  touch(d)
  if d.caps and isLetter(ch) then ch = ch:upper() end
  local l = d.lines[d.curLine]
  d.lines[d.curLine] = l:sub(1, d.curCol - 1) .. ch .. l:sub(d.curCol)
  d.curCol = d.curCol + #ch
  touch(d)
end

-- Inserts a raw marker at the caret: "\n" splits the line, anything else
-- (i.e. "\f") lands inline.
function TextBuffer.insertMarker(d, marker)
  touch(d)
  local l = d.lines[d.curLine]
  if marker == "\n" then
    local before = l:sub(1, d.curCol - 1)
    local after = l:sub(d.curCol)
    d.lines[d.curLine] = before
    table.insert(d.lines, d.curLine + 1, after)
    d.curLine = d.curLine + 1
    d.curCol = 1
  else
    d.lines[d.curLine] = l:sub(1, d.curCol - 1) .. marker .. l:sub(d.curCol)
    d.curCol = d.curCol + #marker
  end
  touch(d)
end

function TextBuffer.backspace(d)
  touch(d)
  local l = line(d)
  if d.curCol > 1 then
    d.lines[d.curLine] = l:sub(1, d.curCol - 2) .. l:sub(d.curCol)
    d.curCol = d.curCol - 1
  elseif d.curLine > 1 then
    -- join with the previous line, caret at the seam
    local prev = d.lines[d.curLine - 1]
    d.curCol = #prev + 1
    d.lines[d.curLine - 1] = prev .. l
    table.remove(d.lines, d.curLine)
    d.curLine = d.curLine - 1
  end
  touch(d)
end

function TextBuffer.deleteChar(d)
  touch(d)
  local l = line(d)
  if d.curCol <= #l then
    d.lines[d.curLine] = l:sub(1, d.curCol - 1) .. l:sub(d.curCol + 1)
  elseif d.curLine < #d.lines then
    d.lines[d.curLine] = l .. d.lines[d.curLine + 1]
    table.remove(d.lines, d.curLine + 1)
  end
  touch(d)
end

-- Horizontal move that wraps across the line seams.
function TextBuffer.moveH(d, dx)
  touch(d)
  d.curCol = d.curCol + dx
  if d.curCol < 1 and d.curLine > 1 then
    d.curLine = d.curLine - 1
    d.curCol = #(d.lines[d.curLine]) + 1
  elseif d.curCol > #(d.lines[d.curLine] or "") + 1
      and d.curLine < #d.lines then
    d.curLine = d.curLine + 1
    d.curCol = 1
  end
  touch(d)
end

function TextBuffer.moveV(d, dy)
  touch(d)
  d.curLine = math.max(1, math.min(d.curLine + dy, #d.lines))
  touch(d)
end

function TextBuffer.toLineStart(d)
  d.curCol = 1
end

function TextBuffer.toLineEnd(d)
  touch(d)
  d.curCol = #(d.lines[d.curLine] or "") + 1
end

function TextBuffer.toggleCaps(d)
  d.caps = not d.caps
  return d.caps
end

function TextBuffer.upperAll(d)
  touch(d)
  for i, l in ipairs(d.lines) do
    d.lines[i] = l:upper()
  end
  touch(d)
end

return TextBuffer
