--- The :Harmonize user command: subcommands for changing model, provider, and
--- preset, plus the virtual-text auto-trigger controls. The command is a thin
--- shell over the current App instance.
local M = {}

---@type harmonize.App?
local app

function M.set_app(current)
    app = current
end

---@param config table the merged config
---@return string[] "provider:model" choices from the model card
function M.model_choices(config)
    local modelcard = require 'harmonize.modelcard'
    local choices = {}

    for provider, models in pairs(modelcard.models) do
        if provider == 'openai_compatible' or provider == 'openai_fim_compatible' then
            -- Handle subproviders for compatible APIs
            local subprovider = config.provider_options[provider] and string.lower(config.provider_options[provider].name)
            if subprovider and models[subprovider] then
                for _, model in ipairs(models[subprovider]) do
                    table.insert(choices, provider .. ':' .. model)
                end
            end
        elseif type(models) == 'table' then
            -- Handle regular providers
            for _, model in ipairs(models) do
                table.insert(choices, provider .. ':' .. model)
            end
        end
    end

    return choices
end

---@param arglead string
---@param cmdline string
---@return string[] completion candidates
function M.complete(arglead, cmdline)
    if not app then
        vim.notify 'Harmonize config is not set up yet, please call the setup function firstly.'
        return {}
    end

    local completions = {
        virtualtext = { enable = true, disable = true, toggle = true },
        change_model = function()
            return M.model_choices(app.config)
        end,
        change_provider = function()
            local providers = {}
            for key in pairs(app.config.provider_options) do
                table.insert(providers, key)
            end
            return providers
        end,
        change_preset = function()
            local presets = {}
            for key in pairs(app.presets) do
                table.insert(presets, key)
            end
            return presets
        end,
    }

    cmdline = cmdline or ''
    local parts = vim.split(vim.trim(cmdline), '%s+')

    ---@type table|function
    local node = completions

    -- The current part may be partial, so keep `node` at the parent level
    -- and filter by prefix.
    local n_fully_typed_parts = #parts
    if arglead ~= '' and #parts > 0 then
        n_fully_typed_parts = n_fully_typed_parts - 1
    end

    for i = 2, n_fully_typed_parts do
        local part = parts[i]
        if type(node) ~= 'table' or node[part] == nil then
            return {}
        end
        node = node[part]
    end

    local candidates
    if type(node) == 'function' then
        candidates = node()
    elseif type(node) == 'table' then
        candidates = vim.tbl_keys(node)
    else
        return {}
    end

    table.sort(candidates)
    return vim.tbl_filter(function(item)
        return vim.startswith(item, arglead)
    end, candidates)
end

---@param args { fargs: string[] }
function M.execute(args)
    if not app then
        vim.notify 'Harmonize config is not set up yet, please call the setup function firstly.'
        return
    end

    local fargs = args.fargs

    local actions = {
        virtualtext = {
            enable = function()
                app.bindings:enable_auto_trigger()
            end,
            disable = function()
                app.bindings:disable_auto_trigger()
            end,
            toggle = function()
                app.bindings:toggle_auto_trigger()
            end,
        },
        change_provider = setmetatable({}, {
            __index = function(_, key)
                return function()
                    app:change_provider(key)
                end
            end,
        }),
    }

    local command = fargs[1]

    if command == 'change_model' then
        app:change_model(fargs[2])
    elseif command == 'change_preset' then
        app:change_preset(fargs[2])
    else
        local action_group = actions[command]
        if not action_group then
            vim.notify('Invalid Harmonize command: ' .. tostring(command), vim.log.levels.ERROR)
            return
        end

        -- For nested groups, walk one level deeper when fargs[2] resolves to
        -- a table.
        local action_name = fargs[2]
        if type(action_group[action_name]) == 'table' then
            action_group = action_group[action_name]
            action_name = fargs[3]
        end

        local action_fn = action_group[action_name]
        if not action_fn then
            vim.notify('Harmonize ' .. command .. ' requires a valid action', vim.log.levels.ERROR)
            return
        end

        action_fn()
    end
end

function M.register()
    vim.api.nvim_create_user_command('Harmonize', M.execute, {
        nargs = '+',
        complete = M.complete,
        force = true,
    })
end

return M
