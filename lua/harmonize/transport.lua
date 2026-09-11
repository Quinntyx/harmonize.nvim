--- Curl-based HTTP transport. Owns the temp request files and the list of
--- running jobs, so a backend can cancel its current request and the app can
--- kill everything on teardown.

---@class harmonize.Request
---@field cancel fun()

---@class harmonize.Transport
local Transport = {}
Transport.__index = Transport

---@param config table merged harmonize config
---@param deps table shared dependencies
function Transport.new(config, deps)
    return setmetatable({
        config = config,
        notify = deps.notify,
        value = deps.value,
        active = {},
    }, Transport)
end

--- Whether the configured curl command exists.
function Transport:is_available()
    return vim.fn.executable(self.config.curl_cmd) == 1
end

--- Write a request body to a temp file in nvim's private temp directory.
---@param content table|string
---@return string? tmp file path, or nil (with a notification) on failure
function Transport:write_body_file(content)
    local ok, json = pcall(vim.json.encode, content)
    if not ok then
        self.notify.notify('Failed to encode completion request data', 'error', vim.log.levels.ERROR)
        return nil
    end

    local tmp_file = vim.fn.tempname()
    -- Keep the request body byte-for-byte unchanged and skip fsync for this
    -- short-lived file.
    local write_ok, result = pcall(vim.fn.writefile, { json }, tmp_file, 'bS')
    if not write_ok or result ~= 0 then
        vim.uv.fs_unlink(tmp_file)
        self.notify.notify('Cannot write temporary message file: ' .. tmp_file, 'error', vim.log.levels.ERROR)
        return nil
    end

    return tmp_file
end

--- Build the curl argument list for a POST request.
---@param end_point string
---@param headers table<string, string>
---@param data_file string
---@return string[]
function Transport:curl_args(end_point, headers, data_file)
    local args = {}

    for _, arg in ipairs(self.value.get_or_eval(self.config.curl_extra_args) or {}) do
        table.insert(args, arg)
    end

    table.insert(args, '-L')
    -- Flush each response line as it arrives so streamed tokens can be
    -- rendered without waiting for the whole request to finish.
    table.insert(args, '--no-buffer')

    for k, v in pairs(headers) do
        table.insert(args, '-H')
        table.insert(args, k .. ': ' .. v)
    end

    if self.config.request_timeout > 0 then
        table.insert(args, '--max-time')
        table.insert(args, tostring(self.config.request_timeout))
    end

    table.insert(args, '-d')
    table.insert(args, '@' .. data_file)

    if self.config.proxy then
        table.insert(args, '--proxy')
        table.insert(args, self.config.proxy)
    end

    table.insert(args, end_point)

    return args
end

---@class harmonize.TransportHandlers
---@field on_exit fun(result: vim.SystemCompleted, data_file: string)
---@field on_stdout? fun(err: string|nil, data: string|nil) raw streamed stdout chunks
---@field on_spawn_error? fun()

--- Start a curl job. The body is written to a temp file the backend deletes
--- from its on_exit handler. Returns a request the backend can cancel.
---@param end_point string
---@param headers table<string, string>
---@param body table|string
---@param handlers harmonize.TransportHandlers
---@return harmonize.Request?
function Transport:post(end_point, headers, body, handlers)
    local data_file = self:write_body_file(body)
    if not data_file then
        if handlers.on_spawn_error then
            handlers.on_spawn_error()
        end
        return nil
    end

    local cmd = { self.config.curl_cmd }
    vim.list_extend(cmd, self:curl_args(end_point, headers, data_file))

    local opts = { text = true }
    if handlers.on_stdout then
        opts.stdout = vim.schedule_wrap(function(err, data)
            handlers.on_stdout(err, data)
        end)
    end

    local job
    local done = false
    local cancelled = false
    local ok, result = pcall(
        vim.system,
        cmd,
        opts,
        vim.schedule_wrap(function(out)
            done = true
            for i, active_job in ipairs(self.active) do
                if active_job == job then
                    table.remove(self.active, i)
                    break
                end
            end
            handlers.on_exit(out, data_file)
        end)
    )

    if not ok then
        vim.uv.fs_unlink(data_file)
        self.notify.notify('Failed to start completion job: ' .. result, 'error', vim.log.levels.ERROR)
        if handlers.on_spawn_error then
            handlers.on_spawn_error()
        end
        return nil
    end

    job = result
    self.active[#self.active + 1] = job

    return {
        cancel = function()
            if done or cancelled then
                return
            end
            cancelled = true
            local kill_ok = pcall(job.kill, job, 'sigterm')
            if kill_ok then
                for i, active_job in ipairs(self.active) do
                    if active_job == job then
                        table.remove(self.active, i)
                        break
                    end
                end
            else
                self.notify.notify('Failed to terminate completion job', 'warn', vim.log.levels.WARN)
            end
        end,
    }
end

--- Kill every running job. Used when the app tears down.
function Transport:close()
    for _, job in ipairs(self.active) do
        pcall(job.kill, job, 'sigterm')
    end
    self.active = {}
end

return Transport
