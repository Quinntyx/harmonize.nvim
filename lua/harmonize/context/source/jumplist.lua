--- Jumplist context source: snippets around recently visited locations. The
--- jumplist has no change event, so refresh() compares a cheap signature on
--- navigation events and only rebuilds the cached chunks when it changed.
--- Text for loaded buffers comes straight from the buffer; unloaded files
--- are read once and cached per location.
local api = vim.api
local ContextItem = require 'harmonize.context.item'

---@class harmonize.JumplistSource
local JumplistSource = {}
JumplistSource.__index = JumplistSource

local max_file_cache = 32

---@param options table context_sources.jumplist options
function JumplistSource.new(options)
    return setmetatable({
        options = options or {},
        signature = nil,
        chunks = {},
        -- Extracted snippets for unloaded files, keyed by "filename:lnum".
        file_cache = {},
    }, JumplistSource)
end

--- Whole lines around a 1-based line number, bounded by the character budgets.
---@param get_line fun(row: integer): string? 0-based row accessor
---@param line_count integer
---@param lnum integer 1-based target line
---@param options { chars_before: integer, chars_after: integer }
---@return integer start_row, integer end_row 0-based, end exclusive
local function expand_around(get_line, line_count, lnum, options)
    local row = lnum - 1
    local start_row = row
    local end_row = row + 1
    local chars_before = 0
    local chars_after = 0

    while start_row > 0 do
        local line = get_line(start_row - 1)
        if not line or chars_before + #line + 1 > options.chars_before then
            break
        end
        chars_before = chars_before + #line + 1
        start_row = start_row - 1
    end

    while end_row < line_count do
        local line = get_line(end_row)
        if not line or chars_after + #line + 1 > options.chars_after then
            break
        end
        chars_after = chars_after + #line + 1
        end_row = end_row + 1
    end

    return start_row, end_row
end

function JumplistSource:lines_from_buffer(bufnr, lnum)
    local options = self.options
    local line_count = api.nvim_buf_line_count(bufnr)
    local get_line = function(r)
        return api.nvim_buf_get_lines(bufnr, r, r + 1, true)[1]
    end
    local start_row, end_row = expand_around(get_line, line_count, lnum, options)
    return start_row, end_row, api.nvim_buf_get_lines(bufnr, start_row, end_row, true)
end

function JumplistSource:lines_from_file(filename, lnum)
    local options = self.options
    local key = filename .. ':' .. lnum
    local cached = self.file_cache[key]
    if cached then
        return cached.start_row, cached.end_row, cached.lines
    end

    local ok, lines = pcall(vim.fn.readfile, filename)
    if not ok or type(lines) ~= 'table' then
        return nil
    end

    local get_line = function(r)
        return lines[r + 1]
    end
    local start_row, end_row = expand_around(get_line, #lines, lnum, options)

    local snippet = {}
    for i = start_row, end_row - 1 do
        snippet[#snippet + 1] = lines[i + 1]
    end

    self.file_cache[key] = { start_row = start_row, end_row = end_row, lines = snippet }
    -- Keep the cache bounded; the table is unordered, so drop an arbitrary
    -- stale entry when full.
    local keys = vim.tbl_keys(self.file_cache)
    if #keys > max_file_cache then
        for i = #keys, max_file_cache + 1, -1 do
            self.file_cache[keys[i]] = nil
        end
    end

    return start_row, end_row, snippet
end

--- Select the jumps to include: the most recent entries behind the current
--- position, valid and distinct, optionally limited to the project root.
---@param list table getjumplist entries
---@param position integer current jumplist index (1-based over the list)
---@param current { bufnr: integer, lnum: integer }
---@param overrides? { max_jumps?: integer, project_only?: boolean, root?: string }
---@return table[] selected { bufnr, lnum, filename }
function JumplistSource:select_jumps(list, position, current, overrides)
    local options = self.options
    local max_jumps = (overrides and overrides.max_jumps) or options.max_jumps
    local project_only = (overrides and overrides.project_only ~= nil) and overrides.project_only or options.project_only
    local root = (overrides and overrides.root) or vim.fs.root(0, { '.git' }) or vim.uv.cwd()

    local selected = {}
    local seen = {}
    root = vim.fs.normalize(root)
    local root_prefix = root == '/' and root or root:gsub('/+$', '') .. '/'

    for i = position, 1, -1 do
        local entry = list[i]
        if entry and api.nvim_buf_is_valid(entry.bufnr) then
            local is_current = entry.bufnr == current.bufnr and math.abs(entry.lnum - current.lnum) < 2
            local key = entry.bufnr .. ':' .. entry.lnum
            if not is_current and not seen[key] then
                local raw_name = api.nvim_buf_get_name(entry.bufnr)
                -- fnamemodify('', ':p') returns the working directory, so
                -- unnamed buffers must be skipped before the path is expanded.
                local keep = raw_name ~= ''
                local filename = keep and vim.fs.normalize(vim.fn.fnamemodify(raw_name, ':p')) or ''
                if keep and project_only then
                    keep = filename == root or filename:sub(1, #root_prefix) == root_prefix
                end
                if keep then
                    seen[key] = true
                    selected[#selected + 1] = { bufnr = entry.bufnr, lnum = entry.lnum, filename = filename }
                    if #selected >= max_jumps then
                        break
                    end
                end
            end
        end
    end

    -- Oldest first so the compositor emits a stable order.
    local reversed = {}
    for i = #selected, 1, -1 do
        reversed[#reversed + 1] = selected[i]
    end
    return reversed
end

---@param bufnr integer
function JumplistSource:refresh(bufnr)
    local list, position = unpack(vim.fn.getjumplist(0))
    local cursor = api.nvim_win_get_cursor(0)
    local current = { bufnr = bufnr, lnum = cursor[1] }

    local signature_parts = { tostring(position), tostring(bufnr), tostring(cursor[1]) }
    for i = math.max(1, position - 9), position do
        local entry = list[i]
        if entry then
            signature_parts[#signature_parts + 1] = entry.bufnr .. ':' .. entry.lnum
        end
    end
    local signature = table.concat(signature_parts, ';')

    if signature == self.signature then
        return
    end
    self.signature = signature

    local selected = self:select_jumps(list, position, current)

    local chunks = {}
    for _, jump in ipairs(selected) do
        local start_row, end_row, lines
        if api.nvim_buf_is_loaded(jump.bufnr) and vim.bo[jump.bufnr].buftype == '' then
            start_row, end_row, lines = self:lines_from_buffer(jump.bufnr, jump.lnum)
        else
            start_row, end_row, lines = self:lines_from_file(jump.filename, jump.lnum)
        end
        if lines and #lines > 0 then
            chunks[#chunks + 1] = ContextItem.new('jumplist', {
                bufnr = jump.bufnr,
                start_row = start_row,
                end_row = end_row,
                lines = lines,
                filename = jump.filename,
            })
        end
    end
    self.chunks = chunks
end

---@param augroup integer
function JumplistSource:start(augroup)
    api.nvim_create_autocmd({ 'BufEnter', 'WinEnter', 'CursorMoved', 'CursorMovedI' }, {
        group = augroup,
        callback = function(args)
            self:refresh(args.buf)
        end,
        desc = 'harmonize jumplist context refresh',
    })
end

--- Cached chunks. Never touches the jumplist or the filesystem.
---@return harmonize.ContextItem[]
function JumplistSource:snapshot()
    return vim.deepcopy(self.chunks)
end

--- Test hook: drop all cached state.
function JumplistSource:reset()
    self.signature = nil
    self.chunks = {}
    self.file_cache = {}
end

function JumplistSource:close()
    self:reset()
end

return JumplistSource
