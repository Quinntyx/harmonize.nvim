--- Treesitter context source: imports and the headers of the declarations
--- enclosing the cursor. Parsing happens on buffer events, never while
--- building a completion request; snapshot() only reads cached text. State
--- is per buffer, so a delayed refresh for one buffer can never replace the
--- cached context of another.
local api = vim.api
local ContextItem = require 'harmonize.context.item'

--- Node types whose header is sent as context, per language. Used when the
--- language has no harmonize query file.
local scope_node_types = {
    lua = { 'function_declaration', 'function_definition' },
    rust = {
        'function_item',
        'function_signature_item',
        'impl_item',
        'struct_item',
        'enum_item',
        'trait_item',
        'mod_item',
    },
}

local max_header_chars = 240
local debounce_ms = 250

local function close_timer(timer)
    if timer and not timer:is_closing() then
        timer:stop()
        timer:close()
    end
end

---@class harmonize.TreeSitterSource
local TreeSitterSource = {}
TreeSitterSource.__index = TreeSitterSource

---@param _options table context_sources.treesitter options
function TreeSitterSource.new(_options)
    return setmetatable({
        -- bufnr -> { tree, lang, chunks, scope_ids, cursor_row, debounce_timer }
        buffers = {},
    }, TreeSitterSource)
end

---@param bufnr integer
function TreeSitterSource:state(bufnr)
    local state = self.buffers[bufnr]
    if not state then
        state = {}
        self.buffers[bufnr] = state
    end
    return state
end

---@return boolean true when the buffer is a normal file buffer
local function is_normal_buffer(bufnr)
    return api.nvim_buf_is_valid(bufnr) and vim.bo[bufnr].buftype == ''
end

--- Text between two byte positions, as buffer lines.
---@param bufnr integer
---@param srow integer 0-based start row
---@param scol integer 0-based start column in bytes
---@param erow integer 0-based end row
---@param ecol integer 0-based end column in bytes
---@return string
local function text_between(bufnr, srow, scol, erow, ecol)
    local lines = api.nvim_buf_get_lines(bufnr, srow, erow + 1, true)
    if #lines == 0 then
        return ''
    end
    if srow == erow then
        return (lines[1] or ''):sub(scol + 1, ecol)
    end
    local parts = { (lines[1] or ''):sub(scol + 1) }
    for i = 2, #lines - 1 do
        parts[#parts + 1] = lines[i]
    end
    parts[#parts + 1] = (lines[#lines] or ''):sub(1, ecol)
    return table.concat(parts, '\n')
end

--- Header of a declaration node: everything before its body starts, or the
--- whole node text capped when the grammar has no body field.
---@param node table treesitter node
---@param bufnr integer
---@return string
local function scope_header(node, bufnr)
    local srow, scol = node:start()
    local ok, body = pcall(node.field, node, 'body')
    if ok and body and body[1] then
        local brow, bcol = body[1]:start()
        if brow > srow or bcol > scol then
            local header = text_between(bufnr, srow, scol, brow, bcol):gsub('%s+$', '')
            -- Grammars like Rust's function_item start their body at the
            -- opening brace, which the exclusive cut drops; re-append the
            -- brace so the header reads like the code in the file.
            if not header:find '%{%s*$' then
                local line = api.nvim_buf_get_lines(bufnr, brow, brow + 1, true)[1] or ''
                local pos = bcol + 1
                while pos <= #line and (line:byte(pos) == 0x20 or line:byte(pos) == 0x09) do
                    pos = pos + 1
                end
                if line:byte(pos) == 0x7B then -- '{'
                    header = header .. ' {'
                end
            end
            return header
        end
    end
    return (vim.treesitter.get_node_text(node, bufnr):gsub('%s+$', ''):sub(1, max_header_chars))
end

--- Re-render the cached chunks for `bufnr` from its tree and cursor row.
--- Cheap: no parsing.
function TreeSitterSource:render_scopes(bufnr)
    local state = self.buffers[bufnr]
    if not state or not state.tree then
        return
    end

    local ok, query = pcall(vim.treesitter.query.get, state.lang, 'harmonize')
    local types = scope_node_types[state.lang]
    if (not ok or not query) and not types then
        state.chunks = {}
        state.scope_ids = {}
        return
    end

    -- Collect the declarations enclosing the cursor. Prefer the query file
    -- when present; otherwise fall back to walking the tree.
    local found = {}
    if ok and query then
        for id, node in query:iter_captures(state.tree:root(), bufnr) do
            if query.captures[id] == 'harmonize.scope' then
                local srow, _, erow = node:range()
                if not state.cursor_row or (srow <= state.cursor_row and state.cursor_row <= erow) then
                    found[#found + 1] = node
                end
            end
        end
    else
        local function walk(node)
            local srow, _, erow = node:range()
            if
                state.cursor_row
                and srow <= state.cursor_row
                and state.cursor_row <= erow
                and vim.tbl_contains(types, node:type())
            then
                found[#found + 1] = node
            end
            for child in node:iter_children() do
                walk(child)
            end
        end
        walk(state.tree:root())
    end

    table.sort(found, function(a, b)
        return a:start() < b:start()
    end)

    -- Node ids change when the file is reparsed, so this skips only cursor
    -- movement within one parse generation.
    local ids = {}
    for _, node in ipairs(found) do
        ids[#ids + 1] = tostring(node:id())
    end
    if vim.deep_equal(ids, state.scope_ids) then
        return
    end
    state.scope_ids = ids

    local chunks = {}
    for _, node in ipairs(found) do
        local header = scope_header(node, bufnr)
        if header ~= '' then
            chunks[#chunks + 1] = ContextItem.new('treesitter', {
                bufnr = bufnr,
                start_row = node:start(),
                end_row = node:start() + 1,
                lines = { header },
            })
        end
    end

    -- Imports become one chunk covering the real buffer lines, so the
    -- compositor can drop them when the cursor context already includes them.
    if ok and query then
        local first_row, last_row
        local texts = {}
        for id, node in query:iter_captures(state.tree:root(), bufnr) do
            if query.captures[id] == 'harmonize.import' then
                local srow, _, erow = node:range()
                first_row = math.min(first_row or srow, srow)
                last_row = math.max(last_row or erow, erow)
                texts[vim.treesitter.get_node_text(node, bufnr)] = true
            end
        end
        if first_row and #vim.tbl_keys(texts) > 0 then
            chunks[#chunks + 1] = ContextItem.new('treesitter', {
                bufnr = bufnr,
                start_row = first_row,
                end_row = last_row + 1,
                lines = api.nvim_buf_get_lines(bufnr, first_row, last_row + 1, true),
            })
        end
    end

    state.chunks = chunks
end

--- Parse the buffer and re-render its chunks.
function TreeSitterSource:parse(bufnr)
    local state = self:state(bufnr)

    if not is_normal_buffer(bufnr) then
        self.buffers[bufnr] = { chunks = {} }
        return
    end

    local ok, parser = pcall(vim.treesitter.get_parser, bufnr)
    local parse_ok, trees
    if ok and parser then
        parse_ok, trees = pcall(parser.parse, parser)
    end
    if not ok or not parse_ok or not trees or not trees[1] then
        state.chunks = {}
        state.tree = nil
        return
    end

    state.tree = trees[1]
    state.lang = parser:lang()
    state.scope_ids = nil
    self:render_scopes(bufnr)
end

function TreeSitterSource:refresh(bufnr)
    if bufnr == api.nvim_get_current_buf() then
        local state = self:state(bufnr)
        state.cursor_row = api.nvim_win_get_cursor(0)[1] - 1
    end

    self:parse(bufnr)
end

---@param bufnr integer
function TreeSitterSource:schedule_refresh(bufnr)
    local state = self:state(bufnr)
    close_timer(state.debounce_timer)

    local timer = vim.uv.new_timer()
    state.debounce_timer = timer
    timer:start(debounce_ms, 0, vim.schedule_wrap(function()
        if state.debounce_timer ~= timer then
            return
        end
        state.debounce_timer = nil
        close_timer(timer)
        self:refresh(bufnr)
    end))
end

---@param augroup integer
function TreeSitterSource:start(augroup)
    local group = { group = augroup }

    api.nvim_create_autocmd({ 'BufEnter', 'BufWritePost', 'FileType' }, vim.tbl_extend('force', group, {
        callback = function(args)
            self:refresh(args.buf)
        end,
        desc = 'harmonize treesitter context refresh',
    }))

    api.nvim_create_autocmd({ 'TextChanged', 'TextChangedI' }, vim.tbl_extend('force', group, {
        callback = function(args)
            self:schedule_refresh(args.buf)
        end,
        desc = 'harmonize treesitter context reparse',
    }))

    api.nvim_create_autocmd({ 'CursorMoved', 'CursorMovedI' }, vim.tbl_extend('force', group, {
        callback = function(args)
            local state = self.buffers[args.buf]
            if not state then
                return
            end
            state.cursor_row = api.nvim_win_get_cursor(0)[1] - 1
            self:render_scopes(args.buf)
        end,
        desc = 'harmonize treesitter context scope update',
    }))

    api.nvim_create_autocmd('BufWipeout', vim.tbl_extend('force', group, {
        callback = function(args)
            local state = self.buffers[args.buf]
            if state then
                close_timer(state.debounce_timer)
            end
            self.buffers[args.buf] = nil
        end,
        desc = 'harmonize treesitter context cleanup',
    }))
end

--- Cached chunks for the buffer. Never parses.
---@param bufnr integer
---@return harmonize.ContextItem[]
function TreeSitterSource:snapshot(bufnr)
    local state = self.buffers[bufnr]
    if not state then
        return {}
    end
    return vim.deepcopy(state.chunks or {})
end

function TreeSitterSource:reset()
    for _, state in pairs(self.buffers) do
        close_timer(state.debounce_timer)
    end
    self.buffers = {}
end

function TreeSitterSource:close()
    self:reset()
end

return TreeSitterSource
