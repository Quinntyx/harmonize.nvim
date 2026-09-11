--- Chat-style backend for the untested providers (openai, openai_compatible,
--- claude, gemini). Each one sends a chat-style request with prompt
--- templates from the config; the request shape differs per API.
local chat = require 'harmonize.chat'
local filter = require 'harmonize.backend.filter'
local response = require 'harmonize.backend.response'
local value = require 'harmonize.value'

---@class harmonize.LegacyChatBackend
local LegacyChatBackend = {}
LegacyChatBackend.__index = LegacyChatBackend

---@param provider string
---@param config table merged harmonize config
---@param deps table shared dependencies
function LegacyChatBackend.new(provider, config, deps)
    local options = vim.deepcopy(config.provider_options[provider])

    local name = options.name
    if not name then
        name = provider == 'openai' and 'OpenAI' or provider
    end
    options.name = name

    local self = setmetatable({
        provider = provider,
        config = config,
        deps = deps,
        options = options,
        notified_on_chat_endpoint = false,
    }, LegacyChatBackend)

    self:notify_availability()
    return self
end

function LegacyChatBackend:notify_availability()
    local notify = self.deps.notify
    local options = self.options

    -- No placeholder teardown: README documents these are untested.
    if self.provider == 'openai' or self.provider == 'openai_compatible' then
        if options.end_point == '' or options.api_key == '' or options.name == '' then
            return
        end

        if not self.notified_on_chat_endpoint and not options.end_point:find 'chat' then
            self.notified_on_chat_endpoint = true
            notify.notify('Please make sure your endpoint supports `/chat/completion`', 'warn', vim.log.levels.WARN)
        end
    end

    local key = self.provider
    if not self.deps.secret.get_api_key(options.api_key) then
        local messages = {
            openai = 'OpenAI API key is not set',
            openai_compatible = [[The API key has not been provided as an environment variable, or the specified API key environment variable does not exist.
Or the api-key function doesn't return the value.
If you are using Ollama, you can simply set it to 'TERM'.]],
            claude = 'Anthropic API key is not set',
            gemini = 'Gemini API key is not set',
        }
        notify.notify(messages[key], 'error', vim.log.levels.ERROR)
    end
end

function LegacyChatBackend:filter_lengths()
    local config = self.config
    -- Chat providers trim a little duplicated context by default.
    return value.get_or_eval(config.before_cursor_filter_length) or 2,
        value.get_or_eval(config.after_cursor_filter_length) or 15
end

--- Cancel any request this backend is still running.
function LegacyChatBackend:close_request()
    if self.request then
        self.request:cancel()
        self.request = nil
    end
end

function LegacyChatBackend:start() end

--- Finish a request common to all chat providers: decode, split, filter,
--- trim, then deliver.
function LegacyChatBackend:finish(out, data_file, snapshot, callbacks, get_text_fn, provider_label)
    self.request = nil

    local options = self.options

    local items_raw
    if options.stream then
        items_raw = response.stream_decode(out, data_file, provider_label, get_text_fn)
    else
        items_raw = response.no_stream_decode(out, data_file, provider_label, get_text_fn)
    end

    if not items_raw then
        callbacks.on_finish({})
        return
    end

    local items = filter.parse_completion_items(items_raw, provider_label)
    local before_length, after_length = self:filter_lengths()
    items = filter.filter_against_context(items, snapshot, before_length, after_length)
    items = self.deps.text.trim_completion_items(items)

    callbacks.on_finish(items)
end

-- The openai providers deliver text in choices[1].message.content.
local function openai_get_text_fn_no_stream(json)
    return json.choices[1].message.content
end

local function openai_get_text_fn_stream(json)
    return json.choices[1].delta.content
end

-- Anthropic returns content as a list of blocks.
local function claude_get_text_fn_no_stream(json)
    return json.content[1].text
end

local function claude_get_text_fn_stream(json)
    return json.delta.text
end

local function gemini_get_text_fn(json)
    return json.candidates[1].content.parts[1].text
end

---@param snapshot table completed context snapshot
---@param callbacks harmonize.BackendCallbacks
---@return harmonize.Request?
function LegacyChatBackend:complete(snapshot, callbacks)
    local events = self.deps.events
    local options = self.options
    local timestamp = os.time()
    local provider_label = options.name or self.provider

    self:close_request()

    local data, headers, end_point
    local get_text_fn

    if self.provider == 'claude' then
        data = {
            system = chat.make_system_prompt(options.system, 1),
            max_tokens = options.max_tokens,
            model = options.model,
            stream = options.stream,
        }
        data = vim.tbl_deep_extend('force', data, options.optional or {})

        local ctx = chat.make_chat_llm_shot(snapshot, options.chat_input)
        ctx = filter.create_chat_messages_from_list(ctx)

        local few_shots = vim.deepcopy(value.get_or_eval(options.few_shots))
        vim.list_extend(few_shots, ctx)
        data.messages = few_shots

        headers = {
            ['Content-Type'] = 'application/json',
            ['x-api-key'] = self.deps.secret.get_api_key(options.api_key),
            ['anthropic-version'] = '2023-06-01',
        }
        end_point = options.end_point
        get_text_fn = options.stream and claude_get_text_fn_stream or claude_get_text_fn_no_stream
    elseif self.provider == 'gemini' then
        local ctx = chat.make_chat_llm_shot(snapshot, options.chat_input)
        ctx = filter.create_chat_messages_from_list(ctx)
        ctx = self:transform_openai_chat_to_gemini_chat(ctx)

        local few_shots = self:transform_openai_chat_to_gemini_chat(value.get_or_eval(options.few_shots))

        data = {
            system_instruction = {
                parts = {
                    text = chat.make_system_prompt(options.system, 1),
                },
            },
            contents = few_shots,
        }
        data = vim.tbl_deep_extend('force', data, options.optional or {})
        vim.list_extend(data.contents, ctx)

        end_point = string.format(
            '%s/%s:%s',
            options.end_point,
            options.model,
            options.stream and 'streamGenerateContent?alt=sse' or 'generateContent'
        )
        headers = {
            ['Content-Type'] = 'application/json',
            ['x-goog-api-key'] = self.deps.secret.get_api_key(options.api_key),
        }
        get_text_fn = gemini_get_text_fn
    else
        -- openai and openai_compatible.
        local ctx = chat.make_chat_llm_shot(snapshot, options.chat_input)
        ctx = filter.create_chat_messages_from_list(ctx)

        local few_shots = vim.deepcopy(value.get_or_eval(options.few_shots))

        local system = chat.make_system_prompt(options.system, 1)
        table.insert(few_shots, 1, { role = 'system', content = system })
        vim.list_extend(few_shots, ctx)

        data = {
            model = options.model,
            messages = few_shots,
            stream = options.stream,
        }
        data = vim.tbl_deep_extend('force', data, options.optional or {})

        headers = {
            ['Content-Type'] = 'application/json',
        }
        local api_key = self.deps.secret.get_api_key(options.api_key)
        if api_key then
            headers.Authorization = 'Bearer ' .. api_key
        end
        end_point = options.end_point
        get_text_fn = options.stream and openai_get_text_fn_stream or openai_get_text_fn_no_stream
    end

    local transformed_data = filter.apply_transforms(options.transform, end_point, headers, data)

    events.run('HarmonizeRequestStartedPre', {
        provider = self.provider,
        name = options.name,
        model = options.model,
        n_requests = 1,
        timestamp = timestamp,
    })

    local request = self.deps.transport:post(transformed_data.end_point, transformed_data.headers, transformed_data.body, {
        on_exit = function(out, data_file)
            events.run('HarmonizeRequestFinished', {
                provider = self.provider,
                name = options.name,
                model = options.model,
                n_requests = 1,
                request_idx = 1,
                timestamp = timestamp,
            })

            self:finish(out, data_file, snapshot, callbacks, get_text_fn, provider_label)
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

---@param chat table[] openai-style messages
---@return table[] gemini-style contents
function LegacyChatBackend:transform_openai_chat_to_gemini_chat(chat)
    local new_chat = {}

    for _, message in ipairs(chat) do
        local gemini_message
        if message.role == 'user' then
            gemini_message = {
                role = 'user',
                parts = {
                    { text = message.content },
                },
            }
        elseif message.role == 'assistant' then
            gemini_message = {
                role = 'model',
                parts = {
                    { text = message.content },
                },
            }
        end

        if gemini_message then
            table.insert(new_chat, gemini_message)
        end
    end

    return new_chat
end

function LegacyChatBackend:close()
    self:close_request()
end

return LegacyChatBackend
