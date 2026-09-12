--- Context manager: owns the cursor capture and the background context
--- sources, and composes their cached chunks into a backend-neutral `extra`
--- list. The sources are ordered from most stable to most volatile so the
--- server-side prompt prefix cache survives typing.
local ContextItem = require 'harmonize.context.item'
local CursorCapture = require 'harmonize.context.cursor'

---@class harmonize.Context
local Context = {}
Context.__index = Context

--- Sources in emission order: treesitter -> jumplist -> recent_edits.
local source_order = { 'treesitter', 'jumplist', 'recent_edits' }

---@param config table merged harmonize config
---@param deps table? shared dependencies
function Context.new(config, deps)
    local self = setmetatable({
        options = config.context_sources or {},
        cursor = CursorCapture.new(config),
        sources = {},
        notify = deps and deps.notify,
        augroup = nil,
    }, Context)

    local source_paths = {
        treesitter = 'harmonize.context.source.treesitter',
        jumplist = 'harmonize.context.source.jumplist',
        recent_edits = 'harmonize.context.source.recent_edits',
    }

    for _, name in ipairs(source_order) do
        local Source = require(source_paths[name])
        local source_options = self.options[name] or {}
        self.sources[name] = Source.new(source_options)
    end

    return self
end

--- Register the context augroup and start every enabled source.
function Context:start()
    if self.augroup then
        return
    end

    self.augroup = vim.api.nvim_create_augroup('harmonize-context', { clear = true })

    for _, name in ipairs(source_order) do
        local source_options = self.options[name] or {}
        if source_options.enabled ~= false then
            self.sources[name]:start(self.augroup)
        end
    end
end

--- Drop all source resources: timers, buffer attachments, autocmds.
function Context:close()
    for _, name in ipairs(source_order) do
        self.sources[name]:close()
    end

    if self.augroup then
        vim.api.nvim_del_augroup_by_id(self.augroup)
        self.augroup = nil
    end
end

--- Deterministic composition of one source's chunks: give every chunk a
--- stable filename key, keep the first occurrence of each range, drop lines
--- the cursor context covers, merge contiguous ranges, then fit the result
--- into the global character budget.
---@param source_chunks table<string, harmonize.ContextItem[]>
---@param covered { start: integer, end_exclusive: integer? } lines the cursor context already sent
---@param current_bufnr integer buffer the completion runs in
---@return table[]? extra { filename, text } entries, nil when empty
function Context:compose(source_chunks, covered, current_bufnr)
    local global_max = self.options.max_chars or 8192
    local total = 0
    local extra = {}

    for _, source in ipairs(source_order) do
        local chunks = source_chunks[source]
        if chunks and #chunks > 0 then
            for _, chunk in ipairs(chunks) do
                chunk.filename = chunk.filename
                    or (chunk.bufnr and vim.api.nvim_buf_get_name(chunk.bufnr) or '')
                if chunk.filename == '' then
                    chunk.filename = '[buffer]'
                end
                chunk.filename = vim.fn.fnamemodify(chunk.filename, ':.')
                chunk.bufnr = chunk.bufnr or current_bufnr
            end

            table.sort(chunks, function(a, b)
                if a.filename ~= b.filename then
                    return a.filename < b.filename
                end
                return a.start_row < b.start_row
            end)

            -- Drop duplicate ranges, trim what the cursor context covers, and
            -- merge contiguous ranges from the same loaded buffer.
            local unique = {}
            local seen = {}
            for _, chunk in ipairs(chunks) do
                local key = chunk.filename .. ':' .. chunk.start_row .. ':' .. chunk.end_row
                if not seen[key] then
                    seen[key] = true
                    if chunk.bufnr == current_bufnr then
                        vim.list_extend(unique, chunk:trim_covered(covered))
                    else
                        unique[#unique + 1] = chunk
                    end
                end
            end

            chunks = self:merge_overlaps(unique)

            for _, chunk in ipairs(chunks) do
                local chars = chunk:char_count()
                if chars > 0 and total + chars <= global_max then
                    total = total + chars
                    extra[#extra + 1] = {
                        filename = chunk.filename,
                        text = table.concat(chunk.lines, '\n'),
                    }
                end
            end
        end
    end

    if #extra == 0 then
        return nil
    end

    return extra
end

--- Merge chunks from the same loaded buffer when their ranges overlap,
--- re-reading the lines so the merged chunk is contiguous. Chunks arrive
--- sorted by (filename, start_row), so the result order is deterministic.
---@param chunks harmonize.ContextItem[]
---@return harmonize.ContextItem[]
function Context:merge_overlaps(chunks)
    local merged = {}

    for _, chunk in ipairs(chunks) do
        local last = merged[#merged]

        if
            last
            and last.filename == chunk.filename
            and last.end_row >= chunk.start_row
            and last.bufnr
            and chunk.bufnr
            and last.bufnr == chunk.bufnr
            and vim.api.nvim_buf_is_loaded(chunk.bufnr)
        then
            local end_row = math.max(last.end_row, chunk.end_row)
            last.lines = vim.api.nvim_buf_get_lines(chunk.bufnr, last.start_row, end_row, true)
            last.end_row = end_row
        else
            merged[#merged + 1] = chunk
        end
    end

    return merged
end

--- Full snapshot for a completion request: the cursor context plus the
--- composed extra context. Reads cached state and buffer lines only.
---@param bufnr integer
---@param blink_context? table
---@return table snapshot
function Context:capture(bufnr, blink_context)
    local snapshot = self.cursor:context(bufnr, blink_context)
    snapshot.extra = self:snapshot_extra(bufnr, snapshot.covered_lines)
    return snapshot
end

--- Capture context from temporary buffer contents without changing the editor.
---@param bufnr integer original buffer used for cached background context
---@param lines string[] synthetic buffer contents
---@param cursor integer[] one-based row and zero-based byte column
---@return table snapshot
function Context:capture_synthetic(bufnr, lines, cursor)
    local snapshot = self.cursor:context(bufnr, {
        line = lines[cursor[1]],
        cursor = cursor,
    }, lines)
    snapshot.extra = self:snapshot_extra(bufnr, snapshot.covered_lines)
    return snapshot
end

---@param bufnr integer
---@param covered { start: integer, end_exclusive: integer? }
---@return table[]?
function Context:snapshot_extra(bufnr, covered)
    local source_chunks = {}

    for _, name in ipairs(source_order) do
        local source = self.sources[name]
        local ok, result = pcall(source.snapshot, source, bufnr)
        if ok then
            source_chunks[name] = result
        else
            source_chunks[name] = {}
            if self.notify then
                self.notify.notify(
                    string.format('context source %s failed: %s', name, tostring(result)),
                    'debug',
                    vim.log.levels.DEBUG
                )
            end
        end
    end

    return self:compose(source_chunks, covered or { start = 0, end_exclusive = nil }, bufnr)
end

--- Test hook: drop all cached source state without touching resources.
function Context:reset()
    for _, name in ipairs(source_order) do
        self.sources[name]:reset()
    end
end

return Context
