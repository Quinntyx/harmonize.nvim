--- Recent-edits context source: recently edited regions across the project.
--- Each buffer is attached with on_lines; every edit is tracked with an
--- extmark so later line insertions and deletions move the region with the
--- text. Merging two adjacent regions keeps their union, so a typing burst
--- never shrinks the tracked area. snapshot() reads the extmark positions
--- and extracts whole lines around each region.
local api = vim.api
local ContextItem = require 'harmonize.context.item'

---@class harmonize.RecentEditsSource
local RecentEditsSource = {}
RecentEditsSource.__index = RecentEditsSource

local ns_seq = 0

--- Regions whose new edit starts within this many lines of an existing entry
--- are merged, so one typing burst stays a single region.
local merge_gap_lines = 3

---@param options table context_sources.recent_edits options
function RecentEditsSource.new(options)
    ns_seq = ns_seq + 1
    return setmetatable({
        options = options or {},
        namespace = api.nvim_create_namespace('harmonize-recent-edits-' .. ns_seq),
        -- Entries across all tracked buffers, ordered oldest first:
        -- { bufnr, extmark_id, timestamp }.
        entries = {},
        attached = {},
    }, RecentEditsSource)
end

local function is_trackable(bufnr)
    if not api.nvim_buf_is_valid(bufnr) then
        return false
    end
    local bo = vim.bo[bufnr]
    return bo.buftype == '' and bo.buflisted
end

---@return { row: integer, end_row: integer }? region 0-based, end exclusive
function RecentEditsSource:entry_region(entry)
    local ok, pos = pcall(api.nvim_buf_get_extmark_by_id, entry.bufnr, self.namespace, entry.extmark_id, {
        details = true,
    })
    if not ok or type(pos) ~= 'table' or not pos[3] then
        return nil
    end

    local end_row = pos[3].end_row or pos[1]
    if end_row < pos[1] then
        end_row = pos[1]
    end
    return { row = pos[1], end_row = math.max(end_row, pos[1] + 1) }
end

function RecentEditsSource:prune()
    local max_edits = self.options.max_edits
    while #self.entries > max_edits do
        local oldest = table.remove(self.entries, 1)
        pcall(api.nvim_buf_del_extmark, oldest.bufnr, self.namespace, oldest.extmark_id)
    end
end

--- Replace the extmark of a region with one covering the union of the old
--- and new ranges.
function RecentEditsSource:regrow(bufnr, entry, start_row, end_row)
    pcall(api.nvim_buf_del_extmark, bufnr, self.namespace, entry.extmark_id)
    entry.extmark_id = api.nvim_buf_set_extmark(bufnr, self.namespace, start_row, 0, {
        end_row = end_row,
        right_gravity = false,
        end_right_gravity = true,
    })
end

function RecentEditsSource:handle_lines(_event, bufnr, _changedtick, firstline, _lastline_old, lastline_new, _bytecount)
    if not is_trackable(bufnr) then
        return
    end

    -- Find an entry close enough to merge into.
    local target
    for _, entry in ipairs(self.entries) do
        if entry.bufnr == bufnr then
            local region = self:entry_region(entry)
            if region and firstline <= region.end_row + merge_gap_lines and region.row - merge_gap_lines <= lastline_new then
                target = entry
                break
            end
        end
    end

    local now = vim.uv.now()
    if target then
        -- Grow the region to the union of both ranges.
        local region = self:entry_region(target)
        local start_row = math.min(firstline, region.row)
        local end_row = math.max(lastline_new, region.end_row)
        self:regrow(bufnr, target, start_row, end_row)
        target.timestamp = now
        -- Keep entries ordered oldest first.
        table.sort(self.entries, function(a, b)
            return a.timestamp < b.timestamp
        end)
    else
        self.entries[#self.entries + 1] = {
            bufnr = bufnr,
            extmark_id = api.nvim_buf_set_extmark(bufnr, self.namespace, firstline, 0, {
                end_row = math.max(lastline_new, firstline + 1),
                right_gravity = false,
                end_right_gravity = true,
            }),
            timestamp = now,
        }
    end

    self:prune()
end

---@param bufnr integer
function RecentEditsSource:attach(bufnr)
    if self.attached[bufnr] or not is_trackable(bufnr) then
        return
    end

    local ok = api.nvim_buf_attach(bufnr, false, {
        on_lines = function(...)
            self:handle_lines(...)
        end,
        on_reload = function()
            -- A reloaded buffer invalidates extmark positions; start fresh.
            for i = #self.entries, 1, -1 do
                if self.entries[i].bufnr == bufnr then
                    table.remove(self.entries, i)
                end
            end
        end,
        on_detach = function()
            self.attached[bufnr] = nil
            for i = #self.entries, 1, -1 do
                if self.entries[i].bufnr == bufnr then
                    table.remove(self.entries, i)
                end
            end
        end,
    })
    self.attached[bufnr] = ok or false
end

---@param augroup integer
function RecentEditsSource:start(augroup)
    for _, bufnr in ipairs(api.nvim_list_bufs()) do
        if api.nvim_buf_is_loaded(bufnr) then
            self:attach(bufnr)
        end
    end

    local group = { group = augroup }

    api.nvim_create_autocmd({ 'BufReadPost', 'BufNew' }, vim.tbl_extend('force', group, {
        callback = function(args)
            self:attach(args.buf)
        end,
        desc = 'harmonize recent edits attach buffer',
    }))

    api.nvim_create_autocmd('BufWipeout', vim.tbl_extend('force', group, {
        callback = function(args)
            self.attached[args.buf] = nil
            for i = #self.entries, 1, -1 do
                if self.entries[i].bufnr == args.buf then
                    table.remove(self.entries, i)
                end
            end
        end,
        desc = 'harmonize recent edits cleanup buffer',
    }))
end

--- Whole lines around each recent edit region, bounded by the configured
--- character budgets.
---@param _bufnr integer the buffer the completion is for
---@return harmonize.ContextItem[]
function RecentEditsSource:snapshot(_bufnr)
    local options = self.options
    local chunks = {}

    for _, entry in ipairs(self.entries) do
        local region = self:entry_region(entry)
        if region and api.nvim_buf_is_loaded(entry.bufnr) then
            local line_count = api.nvim_buf_line_count(entry.bufnr)
            local start_row = region.row
            local end_row = region.end_row
            local chars_before = 0
            local chars_after = 0

            -- Expand upwards from the region start within the before budget.
            while start_row > 0 do
                local line = api.nvim_buf_get_lines(entry.bufnr, start_row - 1, start_row, true)[1] or ''
                if chars_before + #line + 1 > options.chars_before then
                    break
                end
                chars_before = chars_before + #line + 1
                start_row = start_row - 1
            end

            -- Expand downwards from the region end within the after budget.
            while end_row < line_count do
                local line = api.nvim_buf_get_lines(entry.bufnr, end_row, end_row + 1, true)[1] or ''
                if chars_after + #line + 1 > options.chars_after then
                    break
                end
                chars_after = chars_after + #line + 1
                end_row = end_row + 1
            end

            chunks[#chunks + 1] = ContextItem.new('recent_edits', {
                bufnr = entry.bufnr,
                start_row = start_row,
                end_row = end_row,
                lines = api.nvim_buf_get_lines(entry.bufnr, start_row, end_row, true),
            })
        end
    end

    return chunks
end

--- Detach from every tracked buffer and drop all state.
function RecentEditsSource:close()
    local attached_buffers = self.attached
    self.attached = {}
    for bufnr, attached in pairs(attached_buffers) do
        if attached then
            pcall(api.nvim_buf_detach, bufnr)
        end
    end
    self.entries = {}
end

--- Test hook: drop all tracked state without detaching.
function RecentEditsSource:reset()
    self.entries = {}
end

return RecentEditsSource
