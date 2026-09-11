--- App: the composition root. Assembles the merged config, transport,
--- backend, context, view, controller, and bindings; wires them together;
--- and owns their lifecycle. This is the only place the parts meet.
---@class harmonize.App
local App = {}
App.__index = App

--- Untested providers kept for compatibility; warn once unless the user opts
--- out (see config.allow_unsupported_providers).
local untested_providers = {
    codestral = true,
    openai = true,
    claude = true,
    openai_compatible = true,
    gemini = true,
}

---@param user_config table? the user's setup table
---@param overrides? table test injection point: transport/backend/context/view/controller
---@return harmonize.App
function App.new(user_config, overrides)
    -- Work on a copy: vim.tbl_deep_extend shares nested tables with its
    -- inputs, and the app writes to provider options when the model changes.
    local defaults = vim.deepcopy(require 'harmonize.config')
    local config = vim.tbl_deep_extend('force', defaults, user_config or {})

    if config.enabled then
        vim.deprecate('harmonize.config.enabled', 'harmonize.config.enable_predicates', 'next release', 'harmonize', false)
        config.enable_predicates = config.enable_predicates or config.enabled
    end
    config.presets = nil

    local presets = {}
    if user_config and user_config.presets then
        for key, value in pairs(user_config.presets) do
            presets[key] = value
        end
    end
    presets.original = user_config

    local deps = {
        config = config,
        notify = require 'harmonize.notify',
        events = require 'harmonize.events',
        secret = require 'harmonize.secret',
        value = require 'harmonize.value',
        text = require 'harmonize.text',
        -- Handed to the auto-start feature so the llama_cpp backend can merge
        -- the user's partial auto_start table over these without reading the
        -- config module itself.
        default_auto_start = defaults.default_auto_start,
    }
    deps.notify.set_level(config.notify)
    deps.transport = (overrides and overrides.transport) or require('harmonize.transport').new(config, deps)
    deps.backend = (overrides and overrides.backend)
        or require('harmonize.backend').create(config.provider, config, deps)
    deps.context = (overrides and overrides.context) or require('harmonize.context').new(config, deps)
    deps.view = (overrides and overrides.view) or require('harmonize.completion.view').new(config)
    deps.controller = (overrides and overrides.controller) or require('harmonize.completion.controller').new(deps)

    local self = setmetatable({
        config = config,
        deps = deps,
        backend = deps.backend,
        context = deps.context,
        view = deps.view,
        controller = deps.controller,
        bindings = (overrides and overrides.bindings) or require('harmonize.completion.bindings').new(deps),
        presets = presets,
        overrides = overrides,
        started = false,
    }, App)

    return self
end

--- Register resources: warn about untested providers, start the context
--- sources and the backend's server, and bind the editor events.
function App:start()
    if self.started then
        return
    end

    local provider = self.config.provider
    if not self.config.allow_unsupported_providers and untested_providers[provider] then
        self.deps.notify.notify(
            string.format(
                'Provider %q is not tested: harmonize is only maintained for llama_cpp and openai_fim_compatible. '
                    .. 'The other providers need paid API keys that are not available for testing. '
                    .. 'Set allow_unsupported_providers = true to silence this warning.',
                provider
            ),
            'warn',
            vim.log.levels.WARN
        )
    end

    if provider and provider ~= '' then
        self.context:start()
    end
    self.backend:start()
    self.bindings:setup()
    self.started = true
end

--- Tear down every resource. Idempotent.
function App:close()
    self.started = false

    -- One failing component must not stop the others from releasing resources.
    local components = { self.controller, self.bindings, self.context, self.backend, self.deps.transport }
    for _, component in ipairs(components) do
        local ok, err = pcall(component.close, component)
        if not ok then
            self.deps.notify.notify('teardown failed: ' .. tostring(err), 'warn', vim.log.levels.WARN)
        end
    end
end

--- Yield the current snapshot for the buffer, as the controller consumes it.
--- Used by the tests and by integrations that want a peek.
---@param bufnr integer
function App:capture(bufnr)
    return self.context:capture(bufnr)
end

--- Rebuild the backend and context after a config change. Bindings are reset
--- too, so a preset can change keymaps and automatic trigger filetypes.
function App:rebuild()
    local was_started = self.started
    self.controller:close_request()
    self.bindings:close()

    if self.backend then
        self.backend:close()
    end
    self.context:close()

    local overrides = self.overrides
    self.deps.backend = (overrides and overrides.backend)
        or require('harmonize.backend').create(self.config.provider, self.config, self.deps)
    self.backend = self.deps.backend
    self.controller:set_backend(self.backend)

    self.deps.context = (overrides and overrides.context)
        or require('harmonize.context').new(self.config, self.deps)
    self.context = self.deps.context
    self.controller:set_context(self.context)

    if was_started then
        if self.config.provider and self.config.provider ~= '' then
            self.context:start()
        end
        self.backend:start()
        self.bindings:setup()
    end
end

---@param provider_model string "provider:model"
function App:change_model(provider_model)
    local config = self.config

    if not provider_model then
        local Command = require 'harmonize.command'
        local choices = Command.model_choices(config)
        vim.ui.select(choices, {
            prompt = 'Select a model:',
            format_item = function(item)
                return item
            end,
        }, function(choice)
            if choice then
                self:change_model(choice)
            end
        end)
        return
    end

    local provider, model = provider_model:match '([^:]+):(.+)'
    if not provider or not model then
        vim.notify('Invalid format. Use format provider:model (e.g., openai:gpt-4o)', vim.log.levels.ERROR)
        return
    end

    if not config.provider_options[provider] then
        vim.notify(
            'The provider is not supported, please refer to harmonize.nvim document for more information.',
            vim.log.levels.ERROR
        )
        return
    end

    if provider == 'llama_cpp' then
        vim.notify(
            'change_model cannot restart a llama.cpp server; restart it with the desired model instead.',
            vim.log.levels.ERROR
        )
        return
    end

    config.provider = provider
    config.provider_options[provider].model = model
    self:rebuild()
    vim.notify(string.format('Harmonize model changed to: %s (%s)', model, provider), vim.log.levels.INFO)
end

---@param provider string? an existing provider name
function App:change_provider(provider)
    if not self.config.provider_options[provider] then
        vim.notify(
            'The provider is not supported, please refer to harmonize.nvim document for more information.',
            vim.log.levels.ERROR
        )
        return
    end

    self.config.provider = provider
    self:rebuild()
    vim.notify('Harmonize Provider changed to: ' .. provider, vim.log.levels.INFO)
end

---@param preset string? the name of a user-defined preset
function App:change_preset(preset)
    local preset_config = self.presets[preset]
    if not preset_config then
        vim.notify('The preset is not supported.', vim.log.levels.ERROR)
        return
    end

    -- Keep the config table identity stable: transport, controller, view,
    -- bindings, the public facade, and deps all hold this same table.
    local merged = vim.tbl_deep_extend('force', {}, self.config, preset_config)
    for key in pairs(self.config) do
        self.config[key] = nil
    end
    for key, value in pairs(merged) do
        self.config[key] = value
    end
    self.config.presets = nil
    self.deps.notify.set_level(self.config.notify)
    self:rebuild()
    vim.notify('Harmonize Preset changed to: ' .. preset, vim.log.levels.INFO)
end

return App
