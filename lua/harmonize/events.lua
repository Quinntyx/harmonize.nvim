--- Fires nvim User autocmd events other modules can subscribe to.
local M = {}

---@param event string the event pattern, e.g. 'HarmonizeRequestStarted'
---@param opts table? event data
function M.run(event, opts)
    vim.api.nvim_exec_autocmds('User', { pattern = event, data = opts or {} })
end

return M
