local helpers = require 'tests.helpers'

return {
    {
        name = 'transport writes the exact JSON body in the nvim temp directory',
        run = function()
            local transport = helpers.reload('harmonize.transport').new(helpers.merged_config(), {
                notify = require 'harmonize.notify',
                value = require 'harmonize.value',
            })
            local content = {
                message = 'hello',
                count = 2,
            }
            local expected = vim.json.encode(content)
            local data_file = transport:write_body_file(content)

            helpers.expect_truthy(data_file)
            helpers.expect_equal(
                vim.fs.dirname(data_file),
                vim.fs.dirname(vim.fn.tempname()),
                "request files must use Neovim's private temp directory"
            )

            local file = assert(io.open(data_file, 'rb'))
            local actual = file:read '*a'
            file:close()
            vim.uv.fs_unlink(data_file)

            helpers.expect_equal(actual, expected)
        end,
    },
    {
        name = 'text.trim_completion_items skips whitespace-only completion items',
        run = function()
            local text = helpers.reload 'harmonize.text'

            helpers.expect_equal(text.trim_completion_items { '  foo  ', '   ', '\n\t', ' bar' }, { 'foo', 'bar' })
        end,
    },
    {
        name = 'text.filter_text keeps leading newline while matching duplicated context',
        run = function()
            local text = helpers.reload 'harmonize.text'

            helpers.expect_equal(text.filter_text('\nfoo', 'foo', '', 2, 0), '\nfoo')
        end,
    },
    {
        name = 'response.no_stream_decode ignores non-string extracted text',
        run = function()
            local response = helpers.reload 'harmonize.backend.response'
            local data_file = vim.fn.tempname()
            vim.fn.writefile({ '{}' }, data_file)

            local result = response.no_stream_decode(
                {
                    code = 0,
                    stdout = vim.json.encode {
                        choices = {
                            { text = { 'not a string' } },
                        },
                    },
                },
                data_file,
                'TestProvider',
                function(json)
                    return json.choices[1].text
                end
            )

            helpers.expect_falsy(result)
            helpers.expect_falsy(vim.uv.fs_stat(data_file))
        end,
    },
    {
        name = 'chat.make_system_prompt expands placeholders and drops unresolved ones',
        run = function()
            local chat = helpers.reload 'harmonize.chat'

            local system_prompt = chat.make_system_prompt({
                template = '{{{prompt}}} | {{{guidelines}}} | {{{n_completion_template}}} | {{{x}}} mid {{{y}}} end',
                prompt = 'the prompt',
                guidelines = function()
                    return 'the guidelines'
                end,
                n_completion_template = 'give %d completions',
            }, 3)

            helpers.expect_equal(
                system_prompt,
                'the prompt | the guidelines | give 3 completions |  mid  end',
                'text between two unresolved placeholders must survive'
            )
        end,
    },
    {
        name = 'chat.make_system_prompt drops n_completion_template when n_completion is nil',
        run = function()
            local chat = helpers.reload 'harmonize.chat'

            local system_prompt = chat.make_system_prompt({
                template = '{{{prompt}}}{{{n_completion_template}}}',
                prompt = 'p',
                n_completion_template = 'give %d completions',
            }, nil)

            helpers.expect_equal(system_prompt, 'p')
        end,
    },
    {
        name = 'chat.make_chat_llm_shot renders each template with context-aware values',
        run = function()
            local chat = helpers.reload 'harmonize.chat'

            local shots = chat.make_chat_llm_shot({
                lines_before = 'above',
                lines_after = 'below',
                opts = { language = 'lua' },
            }, {
                template = { '{{{before}}}<cursor>{{{after}}}{{{missing}}}', 'lang: {{{language}}}' },
                before = function(before, _, _)
                    return before
                end,
                after = function(_, after, _)
                    return after
                end,
                language = function(_, _, opts)
                    return opts.language
                end,
            })

            helpers.expect_equal(shots, { 'above<cursor>below', 'lang: lua' })
        end,
    },
    {
        name = 'chat.make_chat_llm_shot accepts plain string values',
        run = function()
            local chat = helpers.reload 'harmonize.chat'

            local shots = chat.make_chat_llm_shot({}, {
                template = '{{{static}}}',
                static = 'fixed text',
            })

            helpers.expect_equal(shots, { 'fixed text' })
        end,
    },
    {
        name = 'chat.expand_template keeps substituted values literal',
        run = function()
            local chat = helpers.reload 'harmonize.chat'

            local rendered = chat.expand_template('{{{a}}}', {
                a = '{{{b}}}',
                b = 'must not appear',
            }, chat.get_or_eval)

            helpers.expect_equal(rendered, '{{{b}}}', 'inserted values must not be rescanned or stripped')
        end,
    },
    {
        name = 'chat prompt builders can reuse the same template tables',
        run = function()
            local chat = helpers.reload 'harmonize.chat'
            local system = {
                template = '{{{prompt}}} {{{n_completion_template}}}',
                prompt = 'complete',
                n_completion_template = 'up to %d',
            }
            local input = {
                template = '{{{before}}}<cursor>',
                before = function(before)
                    return before
                end,
            }

            helpers.expect_equal(chat.make_system_prompt(system, 1), 'complete up to 1')
            helpers.expect_equal(chat.make_system_prompt(system, 2), 'complete up to 2')
            helpers.expect_equal(chat.make_chat_llm_shot({ lines_before = 'a', opts = {} }, input), { 'a<cursor>' })
            helpers.expect_equal(chat.make_chat_llm_shot({ lines_before = 'b', opts = {} }, input), { 'b<cursor>' })
            helpers.expect_truthy(system.template)
            helpers.expect_truthy(input.template)
        end,
    },
    {
        name = 'transport request cancellation is idempotent and removes the active job',
        run = function()
            local original_system = vim.system
            local data_file
            local kills = 0
            local transport = helpers.reload('harmonize.transport').new(helpers.merged_config(), {
                notify = require 'harmonize.notify',
                value = require 'harmonize.value',
            })

            local ok, err = xpcall(function()
                vim.system = function(cmd)
                    for _, arg in ipairs(cmd) do
                        if type(arg) == 'string' and arg:sub(1, 1) == '@' then
                            data_file = arg:sub(2)
                        end
                    end
                    return {
                        kill = function()
                            kills = kills + 1
                        end,
                    }
                end

                local request = transport:post('http://localhost', {}, {}, {
                    on_exit = function() end,
                })
                request:cancel()
                request:cancel()
                transport:close()

                helpers.expect_equal(kills, 1)
                helpers.expect_equal(#transport.active, 0)
            end, debug.traceback)

            vim.system = original_system
            if data_file then
                vim.uv.fs_unlink(data_file)
            end
            if not ok then
                error(err, 0)
            end
        end,
    },
}
