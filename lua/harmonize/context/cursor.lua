--- Capture of the text around the cursor, truncated to the context window.
--- Produces the fields every backend consumes plus the buffer line range the
--- sent text covers (so extra context chunks overlapping it can be dropped).
local CursorCapture = {}
CursorCapture.__index = CursorCapture

---@param config table merged harmonize config
function CursorCapture.new(config)
    return setmetatable({ config = config }, CursorCapture)
end

--- A self-contained copy of the context shape completion menus use.
---@class harmonize.BlinkCmpContext
---@field line string
---@field cursor number[]

---@param blink_context harmonize.BlinkCmpContext?
function CursorCapture:make_cmp_context(blink_context)
    local self_cmp = {}
    local cursor

    if blink_context then
        cursor = blink_context.cursor
        self_cmp.cursor_line = blink_context.line
    else
        cursor = vim.api.nvim_win_get_cursor(0)
        self_cmp.cursor_line = vim.api.nvim_get_current_line()
    end

    self_cmp.cursor = {}
    self_cmp.cursor.row = cursor[1]
    self_cmp.cursor.col = cursor[2] + 1
    self_cmp.cursor.line = self_cmp.cursor.row - 1
    self_cmp.cursor_before_line = string.sub(self_cmp.cursor_line, 1, self_cmp.cursor.col - 1)
    self_cmp.cursor_after_line = string.sub(self_cmp.cursor_line, self_cmp.cursor.col)
    return self_cmp
end

--- Full context snapshot around the cursor in `bufnr`.
---@param bufnr integer
---@param blink_context harmonize.BlinkCmpContext?
---@return table snapshot with lines_before, lines_after, opts and covered_lines
function CursorCapture:context(bufnr, blink_context)
    -- A completed cmp-shaped table (cursor + cursor_before_line +
    -- cursor_after_line) is passed through as-is; everything else is
    -- treated as a blink-cmp context and expanded first.
    local cmp_context
    if blink_context and blink_context.cursor_before_line then
        cmp_context = blink_context
    else
        cmp_context = self:make_cmp_context(blink_context)
    end
    local config = self.config
    local cursor = cmp_context.cursor

    local lines_before_list = vim.api.nvim_buf_get_lines(bufnr, 0, cursor.line, false)
    local lines_after_list = vim.api.nvim_buf_get_lines(bufnr, cursor.line + 1, -1, false)

    local lines_before = table.concat(lines_before_list, '\n')
    local lines_after = table.concat(lines_after_list, '\n')

    lines_before = lines_before .. '\n' .. cmp_context.cursor_before_line
    lines_after = cmp_context.cursor_after_line .. '\n' .. lines_after

    local n_chars_before = vim.fn.strchars(lines_before)
    local n_chars_after = vim.fn.strchars(lines_after)

    local full_before = lines_before
    local full_after = lines_after

    local opts = {
        is_incomplete_before = false,
        is_incomplete_after = false,
    }

    if n_chars_before + n_chars_after > config.context_window then
        -- use some heuristic to decide the context length of before cursor and after cursor
        if n_chars_before < config.context_window * config.context_ratio then
            -- If the context length before cursor does not exceed the maximum
            -- size, we include the full content before the cursor.
            lines_after = vim.fn.strcharpart(lines_after, 0, config.context_window - n_chars_before)
            opts.is_incomplete_after = true
        elseif n_chars_after < config.context_window * (1 - config.context_ratio) then
            -- if the context length after cursor does not exceed the maximum
            -- size, we include the full content after the cursor.
            lines_before = vim.fn.strcharpart(lines_before, n_chars_before + n_chars_after - config.context_window)
            opts.is_incomplete_before = true
        else
            -- at the middle of the file, use the context_ratio to determine the allocation
            lines_after =
                vim.fn.strcharpart(lines_after, 0, math.floor(config.context_window * (1 - config.context_ratio)))

            lines_before = vim.fn.strcharpart(
                lines_before,
                n_chars_before - math.floor(config.context_window * config.context_ratio)
            )

            opts.is_incomplete_before = true
            opts.is_incomplete_after = true
        end
    end

    -- Work out which buffer lines the truncated strings already cover so
    -- extra context chunks overlapping them can be dropped.
    local covered_start = 0
    if opts.is_incomplete_before then
        local removed = vim.fn.strcharpart(full_before, 0, n_chars_before - vim.fn.strchars(lines_before))
        covered_start = select(2, removed:gsub('\n', ''))
    end

    local covered_end_exclusive
    if opts.is_incomplete_after then
        covered_end_exclusive = cursor.line + 1 + select(2, lines_after:gsub('\n', ''))
    end

    return {
        lines_before = lines_before,
        lines_after = lines_after,
        opts = opts,
        covered_lines = { start = covered_start, end_exclusive = covered_end_exclusive },
    }
end

return CursorCapture
