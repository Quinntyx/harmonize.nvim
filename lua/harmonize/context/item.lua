--- A chunk of buffer lines from one background context source, with the
--- range arithmetic (overlap trimming, char counting) the coordinator needs.
--- Rows are 0-based; end_row is exclusive.

---@class harmonize.ContextItem
local ContextItem = {}
ContextItem.__index = ContextItem

---@param source string
---@param chunk table { bufnr?, filename?, start_row, end_row, lines }
function ContextItem.new(source, chunk)
    return setmetatable({
        source = chunk.source or source,
        bufnr = chunk.bufnr,
        filename = chunk.filename,
        start_row = chunk.start_row,
        end_row = chunk.end_row,
        lines = chunk.lines,
    }, ContextItem)
end

--- Count characters including one newline per line: what one `text` field
--- contributes to the request body.
function ContextItem:char_count()
    local chars = 0
    for _, line in ipairs(self.lines) do
        chars = chars + vim.fn.strchars(line) + 1
    end
    return chars
end

--- Drop the part of the chunk that the cursor context already covers. The
--- larger remaining side wins; ties keep the lines before the covered range.
---@param covered { start: integer, end_exclusive: integer? }
---@return harmonize.ContextItem[]
function ContextItem:trim_covered(covered)
    local covered_end = covered.end_exclusive or math.huge

    if self.end_row <= covered.start or self.start_row >= covered_end then
        return { self }
    end

    local overlap_start = math.max(self.start_row, covered.start)
    local overlap_end = math.min(self.end_row, covered_end)
    local before_count = overlap_start - self.start_row
    local after_count = self.end_row - overlap_end

    if before_count >= after_count then
        -- Keep the lines before the covered range.
        self.lines = vim.list_slice(self.lines, 1, before_count)
        self.end_row = overlap_start
    else
        -- Keep the lines after the covered range.
        self.lines = vim.list_slice(self.lines, (overlap_end - self.start_row) + 1)
        self.start_row = overlap_end
    end

    if self.start_row >= self.end_row or #self.lines == 0 then
        return {}
    end

    return { self }
end

---@param covered { start: integer, end_exclusive: integer? }
function ContextItem:overlaps(covered)
    local covered_end = covered.end_exclusive or math.huge
    return self.end_row > covered.start and self.start_row < covered_end
end

return ContextItem
