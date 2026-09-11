local helpers = require 'tests.helpers'
local TreeSitterSource = require 'harmonize.context.source.treesitter'

local function refresh(bufnr)
    local treesitter = TreeSitterSource.new(nil)

    local augroup = vim.api.nvim_create_augroup('harmonize-test-treesitter', { clear = true })
    treesitter:start(augroup)
    vim.api.nvim_set_current_buf(bufnr)
    treesitter:refresh(bufnr)
    return treesitter
end

local parser_available = pcall(vim.treesitter.language.add, 'lua')

return {
    {
        name = 'treesitter captures imports and enclosing scope headers',
        run = function()
            if not parser_available then
                return -- skip: no lua parser in this environment
            end

            local bufnr = helpers.create_buffer({
                'local M = {}',
                'local utils = require "harmonize.utils"',
                '',
                'function M.run(a)',
                '  return utils',
                'end',
            })
            vim.bo[bufnr].buftype = ''
            vim.bo[bufnr].ft = 'lua'

            -- Put the cursor inside the function so it counts as enclosing.
            vim.api.nvim_win_set_cursor(0, { 5, 0 })
            local treesitter = refresh(bufnr)
            local chunks = treesitter:snapshot(bufnr)

            local texts = {}
            for _, c in ipairs(chunks) do
                texts[#texts + 1] = table.concat(c.lines, '\n')
            end

            helpers.expect_truthy(
                vim.tbl_contains(texts, 'local utils = require "harmonize.utils"'),
                'the import line must be captured'
            )
            helpers.expect_truthy(
                vim.tbl_contains(texts, 'function M.run(a)'),
                'the enclosing scope header must be captured without its body'
            )
            for _, text in ipairs(texts) do
                helpers.expect_falsy(text:find 'return utils', 'scope headers must not include the body')
            end

            helpers.delete_buffer(bufnr)
        end,
    },
    {
        name = 'treesitter state stays isolated per buffer',
        run = function()
            if not parser_available then
                return -- skip: no lua parser in this environment
            end

            local bufnr = helpers.create_buffer({ 'local x = 1' })
            vim.bo[bufnr].buftype = ''
            vim.bo[bufnr].ft = 'lua'
            local treesitter = refresh(bufnr)
            helpers.expect_equal(#treesitter:snapshot(bufnr), 0)

            -- Another buffer has no cached state of its own.
            local other = helpers.create_buffer({ 'local y = 2' })
            vim.bo[other].buftype = ''
            helpers.expect_equal(treesitter:snapshot(other), {})

            helpers.delete_buffer(bufnr)
            helpers.delete_buffer(other)
        end,
    },
    {
        name = 'treesitter keeps the opening brace on rust function headers',
        run = function()
            if not pcall(vim.treesitter.language.add, 'rust') then
                return -- skip: no rust parser in this environment
            end

            local bufnr = helpers.create_buffer({
                'impl Config {',
                '  pub fn from_env(&self, x: u32) -> u32 {',
                '    x + 1',
                '  }',
                '}',
            })
            vim.bo[bufnr].buftype = ''
            vim.bo[bufnr].ft = 'rust'

            -- Put the cursor inside the function so both declarations enclose it.
            vim.api.nvim_win_set_cursor(0, { 3, 4 })
            local treesitter = refresh(bufnr)

            local texts = {}
            for _, c in ipairs(treesitter:snapshot(bufnr)) do
                texts[#texts + 1] = table.concat(c.lines, '\n')
            end

            helpers.expect_truthy(vim.tbl_contains(texts, 'impl Config {'), 'impl header must keep its brace')
            helpers.expect_truthy(
                vim.tbl_contains(texts, 'pub fn from_env(&self, x: u32) -> u32 {'),
                'fn header must keep its brace'
            )

            helpers.delete_buffer(bufnr)
        end,
    },
    {
        name = 'treesitter debounce replaces and closes pending timers',
        run = function()
            local Source = helpers.reload 'harmonize.context.source.treesitter'
            local source = Source.new {}

            source:schedule_refresh(1)
            local first = source:state(1).debounce_timer
            source:schedule_refresh(1)
            local second = source:state(1).debounce_timer

            helpers.expect_truthy(first ~= second)
            helpers.expect_truthy(first:is_closing(), 'the replaced timer must be closed')
            source:close()
            helpers.expect_truthy(second:is_closing(), 'close must close the pending timer')
        end,
    },
}
