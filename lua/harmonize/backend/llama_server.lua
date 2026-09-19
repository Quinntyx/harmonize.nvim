--- Owns the auto-started llama.cpp server process: health checks, spawning,
--- and the kill-on-exit cleanup when nvim leaves.
local install = require 'harmonize.backend.llama_install'

---@class harmonize.ManagedServer
local ManagedServer = {}
ManagedServer.__index = ManagedServer

---@param opts table merged auto_start options
---@param deps table shared dependencies
function ManagedServer.new(opts, deps)
    return setmetatable({
        opts = opts,
        deps = deps,
        handle = nil,
    }, ManagedServer)
end

--- Is a server already answering at host:port?
function ManagedServer:healthy()
    if not install.has_curl() then
        -- Without a probe we assume the server is down and try to start it;
        -- the failure message then tells the user why that could not work.
        return false
    end

    local ok_handle, handle_or_err = pcall(vim.system, {
        'curl',
        '-fsS',
        '--max-time',
        '2',
        ('http://%s:%d/health'):format(self.opts.host, self.opts.port),
    }, { text = true })
    if not ok_handle then
        return false
    end

    local result = handle_or_err:wait(3000)
    -- wait returns nil when the timeout is reached.
    return result ~= nil and result.code == 0
end

function ManagedServer:spawn(cmd)
    local handle_ok, handle = pcall(vim.system, cmd, { detach = true }, vim.schedule_wrap(function(out)
        if out.code ~= 0 and not self:healthy() then
            vim.notify('llama server exited with code ' .. out.code, vim.log.levels.ERROR)
        end
    end))
    if not handle_ok then
        vim.notify('failed to start the llama server: ' .. tostring(handle), vim.log.levels.ERROR)
        return
    end

    self.handle = handle

    if self.opts.kill_on_exit then
        vim.api.nvim_create_autocmd('VimLeavePre', {
            group = vim.api.nvim_create_augroup('HarmonizeAutoStartServer', { clear = true }),
            callback = function()
                self:stop()
            end,
            desc = 'stop the auto-started llama.cpp server',
        })
    end

    vim.notify(
        'starting llama.cpp server on port ' .. self.opts.port .. ' (first start downloads the model)',
        vim.log.levels.INFO
    )
end

--- Make sure the server the llama_cpp provider points at is running, starting
--- it when it is not.
function ManagedServer:ensure()
    if self:healthy() then
        return
    end

    local cmd = install.server_cmd(self.opts, self.opts.host, self.opts.port)

    if not cmd then
        local version = install.latest_release_tag() or install.fallback_release
        install.download_binary(version, function()
            local retry = install.server_cmd(self.opts, self.opts.host, self.opts.port)
            if retry then
                self:spawn(retry)
            end
        end)
        return
    end

    self:spawn(cmd)
end

--- Kill a server this object spawned. The process keeps running when the
--- server was started by an earlier session: that one is reused on purpose
--- unless the user configured kill_on_exit.
function ManagedServer:stop()
    if self.handle then
        pcall(self.handle.kill, self.handle, 'sigterm')
        self.handle = nil
    end
end

return ManagedServer
