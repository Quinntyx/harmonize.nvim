--- Strict matching between a completion line and existing buffer text.
local Session = require 'harmonize.completion.session'

local M = {}

--- Match only when all text after the cursor is the end of the predicted line.
---@param suggestion string
---@param line_suffix string
---@return table? match { prefix: string, suffix: string }
function M.current_line(suggestion, line_suffix)
    if line_suffix == '' or suggestion:sub(1, 1) == '\n' then
        return nil
    end

    local predicted_line = suggestion:match '^[^\n]*'
    if #predicted_line < #line_suffix or predicted_line:sub(-#line_suffix) ~= line_suffix then
        return nil
    end

    return {
        prefix = predicted_line:sub(1, #predicted_line - #line_suffix),
        suffix = line_suffix,
    }
end

--- Match only when the full predicted line after a leading newline already
--- exists as the next buffer line.
---@param suggestion string
---@param next_line? string
---@return string? matched_line
function M.next_line(suggestion, next_line)
    if suggestion:sub(1, 1) ~= '\n' or next_line == nil then
        return nil
    end

    local predicted_line = suggestion:match '^\n([^\n]*)'
    if predicted_line == next_line then
        return predicted_line
    end
    return nil
end

---@param lines string[]
---@param cursor integer[] one-based row and zero-based byte column
---@param text string
---@return string[] lines
---@return integer[] cursor
local function insert_text(lines, cursor, text)
    local row, col = cursor[1], cursor[2]
    local before = lines[row]:sub(1, col)
    local after = lines[row]:sub(col + 1)
    local inserted = vim.split(text, '\n', { plain = true })

    if #inserted == 1 then
        lines[row] = before .. text .. after
        return lines, { row, col + #text }
    end

    local replacement = { before .. inserted[1] }
    for index = 2, #inserted - 1 do
        replacement[#replacement + 1] = inserted[index]
    end
    replacement[#replacement + 1] = inserted[#inserted] .. after

    table.remove(lines, row)
    for index = #replacement, 1, -1 do
        table.insert(lines, row, replacement[index])
    end
    return lines, { row + #replacement - 1, #inserted[#inserted] }
end

--- Build the buffer and cursor state produced by accepting a whole completion.
---@param original_lines string[]
---@param original_cursor integer[] one-based row and zero-based byte column
---@param suggestion string
---@param chunk_options? table
---@param match_existing boolean
---@return string[] lines
---@return integer[] cursor
function M.apply_completion(original_lines, original_cursor, suggestion, chunk_options, match_existing)
    local lines = vim.deepcopy(original_lines)
    local cursor = { original_cursor[1], original_cursor[2] }
    local remaining = suggestion

    while remaining ~= '' do
        local chunk, tail = Session.split_chunk(remaining, chunk_options)
        local line = lines[cursor[1]]
        local current_match
        local next_match
        if match_existing then
            current_match = M.current_line(remaining, line:sub(cursor[2] + 1))
            next_match = M.next_line(remaining, lines[cursor[1] + 1])
        end

        if next_match and chunk:sub(1, 1) == '\n' and next_match:sub(1, #chunk - 1) == chunk:sub(2) then
            cursor = { cursor[1] + 1, #chunk - 1 }
        elseif current_match and not chunk:find('\n', 1, true) then
            local insert_length = math.min(#chunk, #current_match.prefix)
            local matched = chunk:sub(insert_length + 1)
            if matched == current_match.suffix:sub(1, #matched) then
                local inserted = chunk:sub(1, insert_length)
                lines, cursor = insert_text(lines, cursor, inserted)
                cursor[2] = cursor[2] + #matched
            else
                lines, cursor = insert_text(lines, cursor, chunk)
            end
        else
            lines, cursor = insert_text(lines, cursor, chunk)
        end
        remaining = tail
    end

    return lines, cursor
end

return M
