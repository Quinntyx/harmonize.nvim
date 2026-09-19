--- llama.cpp backend: talks to the server's native /infill endpoint, which
--- builds the fill-in-the-middle prompt with the model's own FIM tokens, so
--- no per-model template is needed. The extra context chunks from the
--- background sources are forwarded in the input_extra request field.
local filter = require 'harmonize.backend.filter'
local response = require 'harmonize.backend.response'
local value = require 'harmonize.value'

---@class harmonize.LlamaCppBackend
local LlamaCppBackend = {}
LlamaCppBackend.__index = LlamaCppBackend

---@param provider string
---@param config table merged harmonize config
---@param deps table shared dependencies
function LlamaCppBackend.new(provider, config, deps)
    return setmetatable({
        provider = provider,
        config = config,
        deps = deps,
        options = vim.deepcopy(config.provider_options.llama_cpp),
        server = nil,
        request = nil,
    }, LlamaCppBackend)
end

---@param json table
LlamaCppBackend.get_text_fn = function(json)
    return json.content
end

-- llama.cpp is not one of the FIM providers with zero filtering: like the
-- chat providers it trims a little duplicated context by default.
function LlamaCppBackend:filter_lengths()
    return value.get_or_eval(self.config.before_cursor_filter_length) or 2,
        value.get_or_eval(self.config.after_cursor_filter_length) or 15
end

function LlamaCppBackend:start()
    local auto_start = self.config.auto_start
    if not auto_start then
        return
    end

    local ManagedServer = require 'harmonize.backend.llama_server'
    self.server = ManagedServer.new(
        vim.tbl_deep_extend('force', self.deps.default_auto_start or {}, auto_start),
        self.deps
    )
    self.server:ensure()
end

--- Cancel any request this backend is still running.
function LlamaCppBackend:close_request()
    if self.request then
        self.request:cancel()
        self.request = nil
    end
end

---@param snapshot table completed context snapshot
---@param callbacks harmonize.BackendCallbacks
---@return harmonize.Request?
function LlamaCppBackend:complete(snapshot, callbacks)
    local events = self.deps.events
    local options = self.options
    local timestamp = os.time()

    self:close_request()

    local data = {
        input_prefix = snapshot.lines_before,
        input_suffix = snapshot.lines_after,
        stream = options.stream,
    }
    -- Extra context chunks from the background context sources.
    if snapshot.extra and #snapshot.extra > 0 then
        data.input_extra = snapshot.extra
    end
    data = vim.tbl_deep_extend('force', data, options.optional or {})

    local headers = {
        ['Content-Type'] = 'application/json',
        ['Accept'] = 'application/json',
    }
    local api_key = options.api_key and self.deps.secret.get_api_key(options.api_key) or nil
    if api_key then
        headers.Authorization = 'Bearer ' .. api_key
    end

    local transformed_data = filter.apply_transforms(options.transform, options.end_point, headers, data)

    events.run('HarmonizeRequestStartedPre', {
        provider = self.provider,
        name = options.name,
        model = options.model,
        n_requests = 1,
        timestamp = timestamp,
    })

    -- The raw text accumulated from the stream so far. Each update sends the
    -- complete snapshot so rendering does not depend on how curl splits
    -- stdout into chunks.
    local accumulated = ''
    local raw_buffer = ''
    local received_tokens = false

    local function consume_line(line)
        line = line:gsub('\r$', '')
        local stripped = line:match('^data:%s*(.*)$') or line
        if stripped == '' or stripped == '[DONE]' then
            return
        end

        local success, json = pcall(vim.json.decode, stripped)
        if success and json then
            local ok, text = pcall(self.get_text_fn, json)
            if ok and type(text) == 'string' and text ~= '' then
                accumulated = accumulated .. text
                if callbacks.on_update then
                    callbacks.on_update(accumulated)
                end
            end
        end
    end

    local request = self.deps.transport:post(transformed_data.end_point, transformed_data.headers, transformed_data.body, {
        on_stdout = options.stream and function(_err, data)
            if not data or #data == 0 then
                return
            end
            raw_buffer = raw_buffer .. data
            while true do
                local nl = raw_buffer:find('\n', 1, true)
                if not nl then
                    break
                end
                local line = raw_buffer:sub(1, nl - 1)
                raw_buffer = raw_buffer:sub(nl + 1)
                consume_line(line)
            end
            received_tokens = #accumulated > 0
        end or nil,
        on_exit = function(out, data_file)
            self.request = nil
            events.run('HarmonizeRequestFinished', {
                provider = self.provider,
                name = options.name,
                model = options.model,
                n_requests = 1,
                request_idx = 1,
                timestamp = timestamp,
            })

            -- A trailing line may arrive without a trailing newline.
            if #raw_buffer > 0 then
                consume_line(raw_buffer)
                raw_buffer = ''
            end
            received_tokens = #accumulated > 0

            local result

            if received_tokens then
                -- The stream already delivered the text token by token.
                vim.uv.fs_unlink(data_file)
                result = accumulated
            elseif options.stream then
                result = response.stream_decode(out, data_file, options.name, self.get_text_fn)
            else
                result = response.no_stream_decode(out, data_file, options.name, self.get_text_fn)
            end

            local items = {}
            if result then
                items[#items + 1] = result
            end

            local before_length, after_length = self:filter_lengths()
            items = filter.filter_against_context(items, snapshot, before_length, after_length)

            callbacks.on_finish(items)
        end,
        on_spawn_error = function()
            self.request = nil
            events.run('HarmonizeRequestFinished', {
                provider = self.provider,
                name = options.name,
                model = options.model,
                n_requests = 1,
                request_idx = 1,
                timestamp = timestamp,
            })
            callbacks.on_finish({})
        end,
    })
    if not request then
        return nil
    end

    events.run('HarmonizeRequestStarted', {
        provider = self.provider,
        name = options.name,
        model = options.model,
        n_requests = 1,
        request_idx = 1,
        timestamp = timestamp,
    })

    self.request = request
    return request
end

function LlamaCppBackend:close()
    self:close_request()
end

return LlamaCppBackend
