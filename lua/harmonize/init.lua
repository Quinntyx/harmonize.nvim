--- Public facade. Keeps the require('harmonize') entry point and the
--- setup / change_model / change_provider / change_preset API stable; all
--- real work happens in the App object it owns.
local M = {}

---@type harmonize.App?
local app

function M.setup(config)
    -- Repeated setups replace the previous app instead of stacking state.
    if app then
        app:close()
    end

    app = require('harmonize.app').new(config or {})
    app:start()

    M.config = app.config
    M.presets = app.presets
    require('harmonize.command').set_app(app)
end

---@return boolean
function M.is_visible()
    return app ~= nil and app.controller:is_visible()
end

function M.accept()
    if app then
        app.controller:accept()
    end
end

function M.change_model(provider_model)
    if not app then
        vim.notify 'Harmonize config is not set up yet, please call the setup function firstly.'
        return
    end
    app:change_model(provider_model)
end

function M.change_provider(provider)
    if not app then
        vim.notify 'Harmonize config is not set up yet, please call the setup function firstly.'
        return
    end
    app:change_provider(provider)
end

function M.change_preset(preset)
    if not app then
        vim.notify 'Harmonize config is not set up yet, please call the setup function firstly.'
        return
    end
    app:change_preset(preset)
end

require('harmonize.command').register()

return M
