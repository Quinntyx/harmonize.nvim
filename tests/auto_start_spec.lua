local helpers = require 'tests.helpers'

return {
    {
        name = 'auto_start is nil by default and its defaults live on the module',
        run = function()
            local config = helpers.merged_config()

            helpers.expect_falsy(config.auto_start, 'a blank config must not start a server')

            local auto = require('harmonize.config').default_auto_start
            helpers.expect_equal(auto.cmd, 'llama serve')
            helpers.expect_equal(auto.model, 'ggml-org/Qwen2.5-Coder-1.5B-Q8_0-GGUF')
            helpers.expect_equal(auto.extra_args, {})
            helpers.expect_falsy(auto.kill_on_exit)
            helpers.expect_equal(auto.host, '127.0.0.1')
            helpers.expect_equal(auto.port, 8012)
        end,
    },
    {
        name = 'the llama_cpp backend merges a partial auto_start table over the injected defaults',
        run = function()
            local original_server = package.loaded['harmonize.backend.llama_server']
            local captured
            package.loaded['harmonize.backend.llama_server'] = {
                new = function(opts, deps)
                    captured = { opts = opts, deps = deps }
                    return { ensure = function() end }
                end,
            }

            local ok, err = xpcall(function()
                local config = helpers.merged_config {
                    auto_start = { model = '/models/qwen.gguf' },
                }
                local backend = require('harmonize.backend.llama_cpp').new('llama_cpp', config, {
                    notify = require 'harmonize.notify',
                    events = require 'harmonize.events',
                    secret = require 'harmonize.secret',
                    transport = nil,
                    default_auto_start = require('harmonize.config').default_auto_start,
                })
                backend:start()

                helpers.expect_equal(captured.opts.cmd, 'llama serve')
                helpers.expect_equal(captured.opts.model, '/models/qwen.gguf')
                helpers.expect_equal(captured.opts.host, '127.0.0.1')
                helpers.expect_equal(captured.opts.port, 8012)
                helpers.expect_equal(captured.opts.kill_on_exit, false)
            end, debug.traceback)

            package.loaded['harmonize.backend.llama_server'] = original_server

            if not ok then
                error(err, 0)
            end
        end,
    },
    {
        name = 'llama_cpp provider options default to the /infill endpoint on port 8012',
        run = function()
            local config = helpers.merged_config()

            local opts = config.provider_options.llama_cpp
            helpers.expect_equal(opts.end_point, 'http://127.0.0.1:8012/infill')
            helpers.expect_falsy(opts.api_key)
            helpers.expect_equal(opts.stream, true)
        end,
    },
    {
        name = 'server command builds the llama serve invocation with the extra arguments',
        run = function()
            local install = helpers.reload 'harmonize.backend.llama_install'
            local original_executable = vim.fn.executable
            vim.fn.executable = function(name)
                return name == 'llama' and 1 or 0
            end

            local ok, err = xpcall(function()
                local cmd = install.server_cmd({
                    cmd = 'llama serve',
                    model = 'ggml-org/Qwen2.5-Coder-1.5B-Q8_0-GGUF',
                    extra_args = { '-ngl', '99', '--ctx-size', '8192' },
                }, '127.0.0.1', 8012)
                helpers.expect_equal(cmd, {
                    'llama',
                    'serve',
                    '-hf',
                    'ggml-org/Qwen2.5-Coder-1.5B-Q8_0-GGUF',
                    '--host', '127.0.0.1',
                    '--port', '8012',
                    '-ngl', '99',
                    '--ctx-size', '8192',
                })

                -- A relative local model file is passed with --model instead
                -- of -hf, and extra_args may be a function returning a list.
                cmd = install.server_cmd({
                    cmd = 'llama serve',
                    model = 'models/qwen.gguf',
                    extra_args = function()
                        return { '-fa' }
                    end,
                }, '127.0.0.1', 8012)
                helpers.expect_equal(cmd, {
                    'llama',
                    'serve',
                    '--model',
                    'models/qwen.gguf',
                    '--host', '127.0.0.1',
                    '--port', '8012',
                    '-fa',
                })

                -- An explicit llama-server binary has no `serve` subcommand.
                vim.fn.executable = function(name)
                    return name == 'llama-server' and 1 or 0
                end
                cmd = install.server_cmd({
                    cmd = 'llama-server',
                    model = 'ggml-org/Qwen2.5-Coder-1.5B-Q8_0-GGUF',
                    extra_args = {},
                }, '127.0.0.1', 8012)
                helpers.expect_equal(cmd, {
                    'llama-server',
                    '-hf',
                    'ggml-org/Qwen2.5-Coder-1.5B-Q8_0-GGUF',
                    '--host', '127.0.0.1',
                    '--port', '8012',
                })
            end, debug.traceback)

            vim.fn.executable = original_executable
            if not ok then
                error(err, 0)
            end
        end,
    },
    {
        name = 'server command gives up when no llama.cpp binary can be resolved',
        run = function()
            local install = helpers.reload 'harmonize.backend.llama_install'
            local original_executable = vim.fn.executable
            vim.fn.executable = function()
                return 0
            end

            local ok, err = xpcall(function()
                local cmd = install.server_cmd({
                    cmd = 'llama serve',
                    model = 'ggml-org/Qwen2.5-Coder-1.5B-Q8_0-GGUF',
                    extra_args = {},
                }, '127.0.0.1', 8012)
                helpers.expect_falsy(cmd, 'no binary found, so there must be no command')
            end, debug.traceback)

            vim.fn.executable = original_executable
            if not ok then
                error(err, 0)
            end
        end,
    },
    {
        name = 'binary resolution chooses one newest downloaded release path',
        run = function()
            local install = helpers.reload 'harmonize.backend.llama_install'
            local original_executable = vim.fn.executable
            local original_glob = vim.fn.glob
            local base = install.data_dir .. '/llama.cpp/'

            local ok, err = xpcall(function()
                vim.fn.executable = function(name)
                    if name == 'llama' or name == 'llama-server' then
                        return 0
                    end
                    return 1
                end
                vim.fn.glob = function(pattern)
                    if pattern:match('/bin/llama$') then
                        return {
                            base .. 'b900/bin/llama',
                            base .. 'b1200/bin/llama',
                        }
                    end
                    return {}
                end

                helpers.expect_equal(install.resolve_binary(), base .. 'b1200/bin/llama')
            end, debug.traceback)

            vim.fn.executable = original_executable
            vim.fn.glob = original_glob
            if not ok then
                error(err, 0)
            end
        end,
    },
}
