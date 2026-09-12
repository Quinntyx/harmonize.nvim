--- Backend registry. This is the only place that knows provider names: it
--- maps a name to a backend class and returns the DisabledBackend used when
--- no provider is configured. Everything above this layer only talks to the
--- Backend interface.
local M = {}

---@class harmonize.BackendCallbacks
---@field on_finish fun(items: string[])
---@field on_update fun(text: string)

---@class harmonize.Request
---@field cancel fun()

---@class harmonize.Backend
---@field new fun(provider: string, config: table, deps: table): harmonize.Backend
---@field start fun(self)
---@field complete fun(self, snapshot: table, callbacks: harmonize.BackendCallbacks): harmonize.Request?
---@field close fun(self)

--- Trivial backend used when no provider is configured. The completion
--- controller never branches on the provider: it just gets an inert request.
local DisabledBackend = {}
DisabledBackend.__index = DisabledBackend

function DisabledBackend.new(_provider, _config, deps)
    return setmetatable({
        deps = deps,
        notified = false,
    }, DisabledBackend)
end

function DisabledBackend:start() end

function DisabledBackend:complete(_snapshot, callbacks)
    -- 'on_type' fires on every keystroke, so notify only once per session.
    if not self.notified then
        self.notified = true
        self.deps.notify.notify(
            'No provider is configured: set provider in the harmonize setup to enable completions',
            'warn',
            vim.log.levels.WARN
        )
    end
    callbacks.on_finish({})
    return nil
end

function DisabledBackend:close() end

-- Providers that still work but are not tested by the suite. Unsupported
-- names map to these constructors so old configs keep functioning.
local fim_providers = {
    openai_fim_compatible = true,
    codestral = true,
}

local chat_providers = {
    openai = true,
    openai_compatible = true,
    claude = true,
    gemini = true,
}

---@param provider string? the configured provider name
---@param config table merged harmonize config
---@param deps table shared dependencies (transport, notify, events, secret, value, text)
---@return harmonize.Backend
function M.create(provider, config, deps)
    if not provider or provider == '' then
        return DisabledBackend.new(nil, config, deps)
    end

    if provider == 'llama_cpp' then
        return require('harmonize.backend.llama_cpp').new(provider, config, deps)
    end

    if fim_providers[provider] then
        return require('harmonize.backend.openai_fim').new(provider, config, deps)
    end

    if chat_providers[provider] then
        return require('harmonize.backend.legacy').new(provider, config, deps)
    end

    -- Unknown names behave like no provider; the setup warning tells the
    -- user which providers actually exist.
    return DisabledBackend.new(provider, config, deps)
end

return M
