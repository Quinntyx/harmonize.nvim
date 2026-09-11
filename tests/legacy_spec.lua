-- Covers the chat backends (openai, openai_compatible, claude, gemini),
local helpers = require 'tests.helpers'

local function chat_options(overrides)
    return vim.tbl_deep_extend('force', {
        model = 'test-model',
        name = 'Test',
        stream = false,
        max_tokens = 4096,
        optional = {},
        transform = {},
        few_shots = {},
        end_point = 'http://127.0.0.1/v1/chat/completions',
        api_key = function()
            return 'test-key'
        end,
        chat_input = {
            template = { '{{{before}}}<cursor>{{{after}}}' },
            before = function(before, _, _)
                return before
            end,
            after = function(_, after, _)
                return after
            end,
        },
    }, overrides or {})
end

-- Covers the chat backends (openai, openai_compatible, claude, gemini),
-- which the original suite never exercised: request shaping per API, the
-- shared finish path (decode, <endCompletion> split, context filtering,
-- trimming), and the filter-length defaults that differ per backend.
local function with_mocked_job(run)
    local captured

    local deps = {
        notify = require 'harmonize.notify',
        events = require 'harmonize.events',
        secret = require 'harmonize.secret',
        text = require 'harmonize.text',
        transport = {
            post = function(_, endpoint, _headers, body, handlers)
                local data_file = vim.fn.tempname()
                vim.fn.writefile({ vim.json.encode(body) }, data_file)
                captured = {
                    end_point = endpoint,
                    headers = _headers,
                    body = body,
                    handlers = handlers,
                    data_file = data_file,
                }
                return { cancel = function() end }
            end,
        },
    }
    deps.notify.set_level(false)

    local ok, err = xpcall(function()
        run({
            backend = function(provider, overrides)
                local config = helpers.merged_config {
                    notify = false,
                    provider_options = {
                        [provider] = chat_options(overrides or {}),
                    },
                }
                return require('harmonize.backend.legacy').new(provider, config, {
                    notify = deps.notify,
                    events = deps.events,
                    secret = deps.secret,
                    transport = deps.transport,
                    text = deps.text,
                })
            end,
            get = function()
                return captured
            end,
        })
    end, debug.traceback)

    if captured and captured.data_file and vim.uv.fs_stat(captured.data_file) then
        vim.uv.fs_unlink(captured.data_file)
    end

    if not ok then
        error(err, 0)
    end
end

local snapshot = {
    lines_before = 'before',
    lines_after = 'after',
    opts = {},
}

return {
    {
        name = 'each backend falls back to its own filter lengths by default',
        run = function()
            helpers.reset_harmonize_modules()

            local config = helpers.merged_config()
            local deps = {
                notify = require 'harmonize.notify',
                events = require 'harmonize.events',
                secret = require 'harmonize.secret',
                transport = nil,
            }
            deps.notify.set_level(false)

            local legacy = require('harmonize.backend.legacy').new('openai', config, deps)
            helpers.expect_equal({ legacy:filter_lengths() }, { 2, 15 }, 'chat providers trim 2/15 by default')

            local llama = require('harmonize.backend.llama_cpp').new('llama_cpp', config, deps)
            helpers.expect_equal({ llama:filter_lengths() }, { 2, 15 }, 'llama_cpp trims 2/15 like the chat providers')

            local fim = require('harmonize.backend.openai_fim').new(
                'openai_fim_compatible',
                config,
                deps
            )
            helpers.expect_equal({ fim:filter_lengths() }, { 0, 0 }, 'FIM providers do not trim')
        end,
    },
    {
        name = 'openai chat sends the system prompt and context messages and finishes the stream',
        run = function()
            with_mocked_job(function(ctx)
                local backend = ctx.backend('openai')
                local result

                backend:complete(snapshot, {
                    on_finish = function(items)
                        result = items
                    end,
                })

                local captured = ctx.get()
                helpers.expect_equal(captured.headers.Authorization, 'Bearer test-key')
                helpers.expect_equal(#captured.body.messages, 2)
                helpers.expect_equal(captured.body.messages[1].role, 'system')
                helpers.expect_truthy(captured.body.messages[1].content:find 'You are an AI code completion engine')
                helpers.expect_equal(captured.body.messages[2], {
                    role = 'user',
                    content = 'before<cursor>after',
                })

                -- The shared finish path splits on <endCompletion>, filters the
                -- duplicated context (nothing matches here), and trims.
                captured.handlers.on_exit({
                    code = 0,
                    stdout = '{"choices":[{"message":{"content":"    a = 1\\n<endCompletion>\\n\\n    b = 2"}}]}',
                }, captured.data_file)

                helpers.expect_equal(result, { 'a = 1', 'b = 2' })
            end)
        end,
    },
    {
        name = 'openai streaming finishes the streamed text the same way',
        run = function()
            with_mocked_job(function(ctx)
                local backend = ctx.backend('openai', { stream = true })
                local result

                backend:complete(snapshot, {
                    on_finish = function(items)
                        result = items
                    end,
                })

                local captured = ctx.get()
                captured.handlers.on_exit({
                    code = 0,
                    stdout = table.concat {
                        'data: {"choices":[{"delta":{"content":"    a = 1"}}]}\n',
                        'data: {"choices":[{"delta":{"content":"\\n<endCompletion>\\n\\n"}}]}\n',
                        'data: {"choices":[{"delta":{"content":"    b = 2"}}]}\n',
                        'data: [DONE]\n',
                    },
                }, captured.data_file)

                helpers.expect_equal(result, { 'a = 1', 'b = 2' })
            end)
        end,
    },
    {
        name = 'gemini chat transforms openai-style messages into contents with parts',
        run = function()
            with_mocked_job(function(ctx)
                local backend = ctx.backend('gemini', {
                    end_point = 'https://generativelanguage.googleapis.com/v1beta/models',
                    model = 'gemini-2.0-flash',
                    few_shots = {
                        { role = 'user', content = 'a' },
                        { role = 'assistant', content = 'b' },
                    },
                })
                local result

                backend:complete(snapshot, {
                    on_finish = function(items)
                        result = items
                    end,
                })

                local captured = ctx.get()
                helpers.expect_equal(captured.headers['x-goog-api-key'], 'test-key')
                helpers.expect_equal(captured.end_point, 'https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash:generateContent')
                helpers.expect_equal(captured.body.contents, {
                    { role = 'user', parts = { { text = 'a' } } },
                    { role = 'model', parts = { { text = 'b' } } },
                    { role = 'user', parts = { { text = 'before<cursor>after' } } },
                })
                helpers.expect_truthy(captured.body.system_instruction.parts.text:find 'You are an')
            end)
        end,
    },
    {
        name = 'claude chat uses the anthropic headers and a system string',
        run = function()
            with_mocked_job(function(ctx)
                local backend = ctx.backend('claude')
                local result

                backend:complete(snapshot, {
                    on_finish = function(items)
                        result = items
                    end,
                })

                local captured = ctx.get()
                helpers.expect_equal(captured.headers['x-api-key'], 'test-key')
                helpers.expect_equal(captured.headers['anthropic-version'], '2023-06-01')
                helpers.expect_equal(type(captured.body.system), 'string')
                helpers.expect_equal(captured.body.max_tokens, 4096)
                helpers.expect_equal(#captured.body.messages, 1)
                helpers.expect_equal(captured.body.messages[1].content, 'before<cursor>after')
            end)
        end,
    },
}
