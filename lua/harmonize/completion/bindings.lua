--- Editor bindings: the autocmds, keymaps, and FileType hooks that drive the
--- completion controller. Owns its augroup and the list of bound keys so a
--- re-setup can remove everything it created.
---@class harmonize.EditorBindings
local Bindings = {}
Bindings.__index = Bindings

local api = vim.api

---@param deps table { config, controller }
function Bindings.new(deps)
    return setmetatable({
        config = deps.config,
        controller = deps.controller,
        augroup = nil,
        bound_keys = {},
    }, Bindings)
end

---@return boolean
function Bindings:should_auto_trigger()
    return vim.b.harmonize_virtual_text_auto_trigger
end

function Bindings:enable_auto_trigger()
    vim.b.harmonize_virtual_text_auto_trigger = true
    vim.notify('Harmonize Virtual Text auto trigger enabled', vim.log.levels.INFO)
end

function Bindings:disable_auto_trigger()
    vim.b.harmonize_virtual_text_auto_trigger = false
    vim.notify('Harmonize Virtual Text auto trigger disabled', vim.log.levels.INFO)
end

function Bindings:toggle_auto_trigger()
    vim.b.harmonize_virtual_text_auto_trigger = not self:should_auto_trigger()
    vim.notify(
        'Harmonize Virtual Text auto trigger ' .. (self:should_auto_trigger() and 'enabled' or 'disabled'),
        vim.log.levels.INFO
    )
end

--- Bind a keymap and remember it so close() can remove it again (repeated
--- setups would otherwise leave duplicate bindings behind).
function Bindings:set_key(mode, lhs, callback, desc)
    vim.keymap.set(mode, lhs, callback, {
        desc = desc,
        silent = true,
    })
    table.insert(self.bound_keys, { mode = mode, lhs = lhs })
end

--- Registers the augroup, autocmds, and keymaps.
function Bindings:setup()
    self.augroup = vim.api.nvim_create_augroup('HarmonizeVirtualText', { clear = true })
    local controller = self.controller
    local group = { group = self.augroup }

    local autocmds = {
        InsertLeave = 'on_insert_leave',
        BufLeave = 'on_buf_leave',
        InsertEnter = 'on_insert_enter',
        BufEnter = 'on_buf_enter',
        CursorMovedI = 'on_cursor_moved_i',
        WinScrolled = 'on_win_scrolled',
        TextChangedI = 'on_text_changed_i',
        TextChangedP = 'on_text_changed_p',
    }

    for event, method in pairs(autocmds) do
        api.nvim_create_autocmd(event, vim.tbl_extend('force', group, {
            callback = function()
                controller[method](controller)
            end,
            desc = '[harmonize] ' .. event,
        }))
    end

    api.nvim_create_autocmd('BufUnload', vim.tbl_extend('force', group, {
        callback = function(info)
            controller:drop_session(info.buf)
        end,
        desc = '[harmonize] buf unload',
    }))

    if #self.config.auto_trigger_ft > 0 then
        api.nvim_create_autocmd('FileType', vim.tbl_extend('force', group, {
            pattern = self.config.auto_trigger_ft,
            callback = function()
                if not vim.tbl_contains(self.config.auto_trigger_ignore_ft, vim.bo.ft) then
                    vim.b.harmonize_virtual_text_auto_trigger = true
                end
            end,
            desc = 'harmonize virtual text filetype auto trigger',
        }))
    end

    local keymap = self.config.keymap
    local actions = {
        accept = { 'accept', '[harmonize] accept suggestion (chunk)' },
        accept_line = { 'accept_line', '[harmonize] accept suggestion (line)' },
        dismiss = { 'dismiss', '[harmonize] dismiss suggestion' },
        trigger = { 'trigger', '[harmonize] manually request a completion' },
        toggle = { 'toggle_auto_trigger', '[harmonize] toggle auto completion' },
    }

    for key, spec in pairs(actions) do
        local lhs = keymap[key]
        if lhs then
            self:set_key('i', lhs, function()
                controller[spec[1]](controller)
            end, spec[2])
        end
    end
end

--- Remove the augroup and every keymap this setup created.
function Bindings:close()
    if self.augroup then
        vim.api.nvim_del_augroup_by_id(self.augroup)
        self.augroup = nil
    end

    for _, key in ipairs(self.bound_keys) do
        pcall(vim.keymap.del, key.mode, key.lhs)
    end
    self.bound_keys = {}
end

return Bindings
