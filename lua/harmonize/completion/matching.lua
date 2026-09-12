--- Strict matching between a completion line and existing buffer text.
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

return M
