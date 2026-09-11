--- Ghost text rendering: owns the namespace and the single preview extmark.
--- Renders whatever suggestion it is handed and knows nothing about HTTP,
--- providers, or the completion state machine.
local Session = require 'harmonize.completion.session'

---@class harmonize.GhostTextView
local View = {}
View.__index = View

---@param config table merged harmonize config
function View.new(config)
    local ns_id = vim.api.nvim_create_namespace 'harmonize.virtualtext'

    if vim.tbl_isempty(vim.api.nvim_get_hl(0, { name = 'HarmonizeVirtualText' })) then
        vim.api.nvim_set_hl(0, 'HarmonizeVirtualText', { link = 'Comment' })
    end

    return setmetatable({
        config = config,
        ns_id = ns_id,
        extmark_id = 1,
        rendered_bufnr = nil,
    }, View)
end

function View:clear()
    local bufnr = self.rendered_bufnr
    self.rendered_bufnr = nil
    if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
        pcall(vim.api.nvim_buf_del_extmark, bufnr, self.ns_id, self.extmark_id)
    end
end

--- Whether a ghost text is currently rendered in the current buffer.
function View:is_visible()
    return not not vim.api.nvim_buf_get_extmark_by_id(0, self.ns_id, self.extmark_id, { details = false })[1]
end

--- Redraw the ghost text for the session's current suggestion.
---@param session harmonize.CompletionSession
function View:update(session)
    local suggestion = session.suggestion

    self:clear()

    if not suggestion or #suggestion == 0 then
        return
    end

    local extmark = {
        id = self.extmark_id,
        virt_text_pos = 'inline',
        hl_mode = 'replace',
    }

    if self.config.display == 'chunk' then
        -- Show exactly what the accept keymap completes next. A chunk
        -- that leads with a newline is only that newline and renders empty.
        extmark.virt_text = { { Session.split_chunk(suggestion):gsub('\n', ''), 'HarmonizeVirtualText' } }
    else
        local display_lines = vim.split(suggestion, '\n', { plain = true })
        if display_lines[1] ~= '' then
            extmark.virt_text = { { display_lines[1], 'HarmonizeVirtualText' } }
        elseif display_lines[2] then
            -- The current line is already complete; show the line below the
            -- cursor instead.
            extmark.virt_text = { { '', 'HarmonizeVirtualText' } }
            extmark.virt_lines = { { { display_lines[2], 'HarmonizeVirtualText' } } }
        else
            return
        end
    end

    local bufnr = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_extmark(bufnr, self.ns_id, vim.fn.line '.' - 1, vim.fn.col '.' - 1, extmark)
    self.rendered_bufnr = bufnr

    session.shown = true
    session.last_pos = vim.api.nvim_win_get_cursor(0)
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
