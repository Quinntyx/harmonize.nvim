local helpers = require 'tests.helpers'

return {
    {
        name = 'a preset keeps shared config references current and rebuilds config-bound components',
        run = function()
            local app = helpers.new_app {
                keymap = { trigger = '<M-z>' },
                debounce = 20,
                display = 'line',
                presets = {
                    fast = {
                        keymap = { trigger = '<M-x>' },
                        debounce = 5,
                        display = 'chunk',
                        context_sources = {
                            treesitter = { enabled = false },
                        },
                    },
                },
            }
            local config = app.config
            local old_context = app.context

            local ok, err = xpcall(function()
                app:start()
                app:start()
                helpers.expect_equal(#app.bindings.bound_keys, 1, 'start must be idempotent')

                app:change_preset 'fast'

                helpers.expect_truthy(app.config == config, 'the app must preserve config table identity')
                helpers.expect_truthy(app.deps.config == config)
                helpers.expect_truthy(app.controller.config == config)
                helpers.expect_truthy(app.view.config == config)
                helpers.expect_truthy(app.bindings.config == config)
                helpers.expect_truthy(app.deps.transport.config == config)
                helpers.expect_equal(config.debounce, 5)
                helpers.expect_equal(config.display, 'chunk')

                helpers.expect_truthy(app.context ~= old_context, 'the context object must be rebuilt')
                helpers.expect_truthy(app.controller.context == app.context)
                helpers.expect_equal(app.context.options.treesitter.enabled, false)

                helpers.expect_equal(vim.fn.maparg('<M-z>', 'i'), '', 'the old preset keymap must be removed')
                helpers.expect_truthy(vim.fn.maparg('<M-x>', 'i') ~= '', 'the new preset keymap must be installed')
            end, debug.traceback)

            app:close()
            if not ok then
                error(err, 0)
            end
        end,
    },
    {
        name = 'changing the model leaves the module defaults untouched',
        run = function()
            -- No module reset here: the two apps must share the loaded config
            -- module for the check to mean anything.
            local App = require 'harmonize.app'
            local defaults = require 'harmonize.config'
            local notify = require 'harmonize.notify'
            local original_model = defaults.provider_options.openai_fim_compatible.model
            local stub_backend = { start = function() end, close = function() end }

            local app = App.new({ provider = 'openai_fim_compatible', notify = false }, { backend = stub_backend })
            local ok, err = xpcall(function()
                app:start()
                app:change_model 'openai_fim_compatible:review-test-model'

                helpers.expect_equal(
                    defaults.provider_options.openai_fim_compatible.model,
                    original_model,
                    'change_model must not write into the module defaults'
                )

                local second = App.new { provider = 'openai_fim_compatible', notify = false }
                helpers.expect_equal(second.config.provider_options.openai_fim_compatible.model, original_model)
                second:close()
            end, debug.traceback)

            app:close()
            -- Undo a leak so the failure does not cascade into the other specs.
            defaults.provider_options.openai_fim_compatible.model = original_model
            notify.set_level 'warn'

            if not ok then
                error(err, 0)
            end
        end,
    },
    {
        name = 'changing a llama_cpp model reports that the server must restart',
        run = function()
            local App = require 'harmonize.app'
            local close_count = 0
            local stub_backend = {
                start = function() end,
                close = function()
                    close_count = close_count + 1
                end,
            }
            local app = App.new({ provider = 'llama_cpp', notify = false }, { backend = stub_backend })
            local original_notify = vim.notify
            local message

            local ok, err = xpcall(function()
                vim.notify = function(value)
                    message = value
                end
                app:change_model 'llama_cpp:models/other.gguf'

                helpers.expect_truthy(
                    message and message:match 'cannot restart',
                    'the error must explain the limitation'
                )
                helpers.expect_falsy(
                    app.config.provider_options.llama_cpp.model,
                    'the unused model option must stay unset'
                )
                helpers.expect_equal(close_count, 0, 'rejecting the model must not rebuild the app')
            end, debug.traceback)

            vim.notify = original_notify
            app:close()
            require('harmonize.notify').set_level 'warn'

            if not ok then
                error(err, 0)
            end
        end,
    },
}
