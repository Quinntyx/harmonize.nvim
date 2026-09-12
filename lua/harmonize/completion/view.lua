--- Ghost text rendering: owns the namespace, inline extmark, and below-line
--- floating preview. Renders suggestions without knowing about requests.
local Session = require 'harmonize.completion.session'

local api = vim.api
local newline_indicator = ' ↵'

---@class harmonize.GhostTextView
local View = {}
View.__index = View

---@param config table merged harmonize config
function View.new(config)
    local ns_id = api.nvim_create_namespace 'harmonize.virtualtext'

    if vim.tbl_isempty(api.nvim_get_hl(0, { name = 'HarmonizeVirtualText' })) then
        api.nvim_set_hl(0, 'HarmonizeVirtualText', { link = 'Comment' })
    end
    api.nvim_set_hl(0, 'HarmonizeVirtualTextBackground', { bg = 'NONE', default = true })

    return setmetatable({
        config = config,
        ns_id = ns_id,
        extmark_id = 1,
        rendered_bufnr = nil,
        float_bufnr = nil,
        float_winid = nil,
    }, View)
end

function View:clear_extmark()
    local bufnr = self.rendered_bufnr
    self.rendered_bufnr = nil
    if bufnr and api.nvim_buf_is_valid(bufnr) then
        pcall(api.nvim_buf_del_extmark, bufnr, self.ns_id, self.extmark_id)
    end
end

function View:clear_float()
    if self.float_winid and api.nvim_win_is_valid(self.float_winid) then
        pcall(api.nvim_win_close, self.float_winid, true)
    end
    if self.float_bufnr and api.nvim_buf_is_valid(self.float_bufnr) then
        pcall(api.nvim_buf_delete, self.float_bufnr, { force = true })
    end
    self.float_winid = nil
    self.float_bufnr = nil
end

function View:clear()
    self:clear_extmark()
    self:clear_float()
end

--- Whether a ghost text is currently rendered in the current buffer.
function View:is_visible()
    if self.float_winid and api.nvim_win_is_valid(self.float_winid) then
        return true
    end
    return not not api.nvim_buf_get_extmark_by_id(0, self.ns_id, self.extmark_id, { details = false })[1]
end

---@param mode 'below' | 'line'
---@return string highlight_group
function View:next_chunk_highlight(mode)
    local options = self.config.display_options and self.config.display_options[mode]
    local accent = options and options.next_chunk_highlight
    if type(accent) ~= 'string' or accent == '' then
        return 'HarmonizeVirtualText'
    end

    local attributes = api.nvim_get_hl(0, { name = 'HarmonizeVirtualText', link = false })
    local hex = accent:match '^#(%x%x%x%x%x%x)$'
    if hex then
        attributes.fg = tonumber(hex, 16)
    else
        local ok, highlight = pcall(api.nvim_get_hl, 0, { name = accent, link = false })
        if not ok or not highlight.fg then
            return 'HarmonizeVirtualText'
        end
        attributes.fg = highlight.fg
    end

    local group = mode == 'below' and 'HarmonizeNextChunkBelow' or 'HarmonizeNextChunkLine'
    api.nvim_set_hl(0, group, attributes)
    return group
end

---@param text string single display line
---@param mode 'below' | 'line' | 'chunk'
---@param accepted_prefix? string visible part accepted by the next chunk
---@return table[] virt_text
function View:display_chunks(text, mode, accepted_prefix)
    if mode == 'chunk' then
        return { { text, 'HarmonizeVirtualText' } }
    end

    accepted_prefix = accepted_prefix or Session.split_chunk(text)
    if accepted_prefix == '' or text:sub(1, #accepted_prefix) ~= accepted_prefix then
        return { { text, 'HarmonizeVirtualText' } }
    end

    local highlight = self:next_chunk_highlight(mode)
    if highlight == 'HarmonizeVirtualText' or #accepted_prefix == #text then
        return { { text, highlight } }
    end
    return {
        { accepted_prefix, highlight },
        { text:sub(#accepted_prefix + 1), 'HarmonizeVirtualText' },
    }
end

---@param chunks table[] virt_text chunks
function View:render_below(chunks)
    self:clear_extmark()

    local text_parts = {}
    for _, chunk in ipairs(chunks) do
        text_parts[#text_parts + 1] = chunk[1]
    end
    local text = table.concat(text_parts)
    if text == '' then
        self:clear_float()
        return
    end

    local width = math.max(1, math.min(vim.fn.strdisplaywidth(text), api.nvim_win_get_width(0) - vim.fn.wincol() + 1))
    local bufnr = self.float_bufnr
    if not bufnr or not api.nvim_buf_is_valid(bufnr) then
        bufnr = api.nvim_create_buf(false, true)
        self.float_bufnr = bufnr
        api.nvim_set_option_value('bufhidden', 'wipe', { buf = bufnr })
    end

    api.nvim_set_option_value('modifiable', true, { buf = bufnr })
    api.nvim_buf_set_lines(bufnr, 0, -1, false, { text })
    api.nvim_buf_clear_namespace(bufnr, self.ns_id, 0, -1)
    local col = 0
    for _, chunk in ipairs(chunks) do
        api.nvim_buf_add_highlight(bufnr, self.ns_id, chunk[2], 0, col, col + #chunk[1])
        col = col + #chunk[1]
    end
    api.nvim_set_option_value('modifiable', false, { buf = bufnr })

    local window_config = {
        relative = 'cursor',
        row = 1,
        col = 0,
        width = width,
        height = 1,
        anchor = 'NW',
        style = 'minimal',
        focusable = false,
        fixed = true,
        noautocmd = true,
        zindex = 50,
    }
    if self.float_winid and api.nvim_win_is_valid(self.float_winid) then
        api.nvim_win_set_config(self.float_winid, window_config)
    else
        self.float_winid = api.nvim_open_win(bufnr, false, window_config)
    end

    api.nvim_set_option_value('wrap', false, { win = self.float_winid })
    api.nvim_set_option_value('winblend', 0, { win = self.float_winid })
    api.nvim_set_option_value(
        'winhl',
        'Normal:HarmonizeVirtualTextBackground,NormalNC:HarmonizeVirtualTextBackground',
        { win = self.float_winid }
    )
end

---@param chunks table[] virt_text chunks
function View:render_inline(chunks)
    self:clear_float()
    local bufnr = api.nvim_get_current_buf()
    if self.rendered_bufnr and self.rendered_bufnr ~= bufnr then
        self:clear_extmark()
    end
    api.nvim_buf_set_extmark(bufnr, self.ns_id, vim.fn.line '.' - 1, vim.fn.col '.' - 1, {
        id = self.extmark_id,
        virt_text = chunks,
        virt_text_pos = 'overlay',
        virt_text_hide = true,
        hl_mode = 'replace',
    })
    self.rendered_bufnr = bufnr
end

---@param chunks table[] virt_text chunks
---@param indicator_highlight string
function View:render_next_line(chunks, indicator_highlight)
    self:clear_float()
    local bufnr = api.nvim_get_current_buf()
    if self.rendered_bufnr and self.rendered_bufnr ~= bufnr then
        self:clear_extmark()
    end
    api.nvim_buf_set_extmark(bufnr, self.ns_id, vim.fn.line '.' - 1, vim.fn.col '.' - 1, {
        id = self.extmark_id,
        virt_text = { { newline_indicator, indicator_highlight } },
        virt_text_pos = 'overlay',
        virt_text_hide = true,
        virt_lines = { chunks },
        hl_mode = 'replace',
    })
    self.rendered_bufnr = bufnr
end

--- Redraw the ghost text for the session's current suggestion.
---@param session harmonize.CompletionSession
function View:update(session)
    local suggestion = session.suggestion
    if not suggestion or suggestion == '' then
        self:clear()
        return
    end

    local mode = self.config.display
    local next_chunk = Session.split_chunk(suggestion)
    local display_lines = vim.split(suggestion, '\n', { plain = true })
    local text
    local accepted_prefix
    local next_line = false
    if mode == 'chunk' then
        text = next_chunk:gsub('\n', newline_indicator)
    elseif display_lines[1] ~= '' then
        text = display_lines[1]
        accepted_prefix = next_chunk
    else
        text = display_lines[2]
        accepted_prefix = next_chunk:sub(2)
        next_line = true
    end

    if not text then
        self:clear()
        return
    end

    local chunks = text == '' and { { ' ', 'HarmonizeVirtualText' } }
        or self:display_chunks(text, mode, accepted_prefix)
    if next_line then
        self:render_next_line(chunks, self:next_chunk_highlight(mode))
    elseif mode == 'below' then
        self:render_below(chunks)
    else
        self:render_inline(chunks)
    end

    session.shown = true
    session.last_pos = api.nvim_win_get_cursor(0)
end

--- Whether a completion menu (the builtin popup menu, or a menu from
--- nvim-cmp or blink-cmp used for other sources) is currently visible.
function View:menu_visible()
    local has_cmp = pcall(require, 'cmp')
    local cmp_visible = false

    local has_blink = pcall(require, 'blink-cmp')
    local blink_visible = false

    if has_cmp then
        local ok, visible = pcall(function()
            return require('cmp').core.view:visible()
        end)
        if ok then
            cmp_visible = visible
        end
    end

    if has_blink then
        local ok, visible = pcall(function()
            return require('blink-cmp').is_visible()
        end)
        if ok then
            blink_visible = visible
        end
    end

    return vim.fn.pumvisible() == 1 or cmp_visible or blink_visible
end

return View
