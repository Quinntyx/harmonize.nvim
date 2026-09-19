--- FIM-style backend for the OpenAI-compatible `/completions` endpoint,
--- used by openai_fim_compatible and codestral. The server fills the prompt
--- and suffix template around the cursor context and streams tokens.
local filter = require 'harmonize.backend.filter'
local response = require 'harmonize.backend.response'
local value = require 'harmonize.value'

---@class harmonize.OpenAiFimBackend
local OpenAiFimBackend = {}
OpenAiFimBackend.__index = OpenAiFimBackend

---@param provider string
---@param config table merged harmonize config
---@param deps table shared dependencies
function OpenAiFimBackend.new(provider, config, deps)
    local options = vim.deepcopy(config.provider_options[provider])

    -- The codestral provider is only a name difference at this endpoint.
    if provider == 'codestral' then
        options.name = 'Codestral'
    end

    local self = setmetatable({
        provider = provider,
        config = config,
        deps = deps,
        options = options,
        request = nil,
        notified_on_chat_endpoint = false,
    }, OpenAiFimBackend)

    self:notify_availability()
    return self
end

function OpenAiFimBackend:notify_availability()
    local options = self.options
    local notify = self.deps.notify

    if options.end_point == '' or options.api_key == '' or options.name == '' then
        return
    end

    if not self.notified_on_chat_endpoint and options.end_point:find 'chat' then
        self.notified_on_chat_endpoint = true
        notify.notify(
            'You are using the `/chat/completions` endpoint, which is likely not designed for FIM code completion. Please use the `/completions` endpoint instead.',
            'warn',
            vim.log.levels.WARN
        )
    end

    if not self.deps.secret.get_api_key(options.api_key) then
        notify.notify(
            self.provider == 'codestral' and 'Codestral API key is not set'
                or [[The API key has not been provided as an environment variable, or the specified API key environment variable does not exist.
Or the api-key function doesn't return the value.
If you are using Ollama, you can simply set it to 'TERM'.]],
            'error',
            vim.log.levels.ERROR
        )
    end
end

local function get_text_fn_no_stream(json)
    return json.choices[1].message.content
end

local function get_text_fn_stream(json)
    return json.choices[1].delta.content
end

OpenAiFimBackend.get_text_fn = function(json)
    return json.choices[1].text
end

function OpenAiFimBackend:resolve_get_text_fn()
    local options = self.options
    if options.get_text_fn.stream and options.stream then
        return options.get_text_fn.stream
    elseif options.get_text_fn.no_stream and not options.stream then
        return options.get_text_fn.no_stream
    end

    if self.provider == 'codestral' then
        return options.stream and get_text_fn_stream or get_text_fn_no_stream
    end

    return self.get_text_fn
end

function OpenAiFimBackend:filter_lengths()
    return value.get_or_eval(self.config.before_cursor_filter_length) or 0,
        value.get_or_eval(self.config.after_cursor_filter_length) or 0
end

--- Cancel any request this backend is still running.
function OpenAiFimBackend:close_request()
    if self.request then
        self.request:cancel()
        self.request = nil
    end
end

function OpenAiFimBackend:start() end

---@param snapshot table completed context snapshot
---@param callbacks harmonize.BackendCallbacks
---@return harmonize.Request?
function OpenAiFimBackend:complete(snapshot, callbacks)
    local events = self.deps.events
    local options = self.options
    local timestamp = os.time()
    local n_completions = 1

    self:close_request()

    local data = {
        model = options.model,
        stream = options.stream,
    }
    data = vim.tbl_deep_extend('force', data, options.optional or {})

    data.prompt = options.template.prompt(snapshot.lines_before, snapshot.lines_after, snapshot.opts)
    data.suffix = options.template.suffix and options.template.suffix(snapshot.lines_before, snapshot.lines_after, snapshot.opts)
        or nil

    local headers = {
        ['Content-Type'] = 'application/json',
        ['Accept'] = 'application/json',
    }
    local api_key = self.deps.secret.get_api_key(options.api_key)
    if api_key then
        headers.Authorization = 'Bearer ' .. api_key
    end

    local transformed_data = filter.apply_transforms(options.transform, options.end_point, headers, data)

    events.run('HarmonizeRequestStartedPre', {
        provider = self.provider,
        name = options.name,
        model = options.model,
        n_requests = n_completions,
        timestamp = timestamp,
    })

    -- The raw text accumulated from the stream so far. Each update sends
    -- the complete snapshot so rendering does not depend on how curl splits
    -- stdout into chunks.
    local accumulated = ''
    local raw_buffer = ''
    local received_tokens = false
    local get_text_fn = self:resolve_get_text_fn()

    local function consume_line(line)
        line = line:gsub('\r$', '')
        local stripped = line:match('^data:%s*(.*)$') or line
        if stripped == '' or stripped == '[DONE]' then
            return
        end

        local success, json = pcall(vim.json.decode, stripped)
        if success and json and json.choices and json.choices[1] then
            local ok, text = pcall(get_text_fn, json)
            if ok and type(text) == 'string' and text ~= '' then
                accumulated = accumulated .. text
                if callbacks.on_update then
                    callbacks.on_update(accumulated)
                end
            end
        end
    end

    -- A single completion candidate: virtual text can only show one at a time.
    local items = {}

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
                n_requests = n_completions,
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
                result = response.stream_decode(out, data_file, options.name, get_text_fn)
            else
                result = response.no_stream_decode(out, data_file, options.name, get_text_fn)
            end

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
                n_requests = n_completions,
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
        n_requests = n_completions,
        request_idx = 1,
        timestamp = timestamp,
    })

    self.request = request
    return request
end

function OpenAiFimBackend:close()
    self:close_request()
end

return OpenAiFimBackend
