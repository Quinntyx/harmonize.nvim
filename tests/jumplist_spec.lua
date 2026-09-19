local helpers = require 'tests.helpers'
local JumplistSource = require 'harmonize.context.source.jumplist'

local function named_buffer(name, lines)
    local bufnr = helpers.create_buffer(lines or { 'a', 'b', 'c' })
    vim.api.nvim_buf_set_name(bufnr, name)
    return bufnr
end

local function make_source()
    return JumplistSource.new(helpers.merged_config().context_sources.jumplist)
end

return {
    {
        name = 'jumplist.select_jumps picks the most recent distinct jumps, oldest first',
        run = function()
            local jumplist = make_source()

            local buf1 = named_buffer '/proj/one.lua'
            local buf2 = named_buffer '/proj/two.lua'
            local buf3 = named_buffer '/proj/three.lua'

            local list = {
                { bufnr = buf1, lnum = 10 },
                { bufnr = buf2, lnum = 20 },
                { bufnr = buf3, lnum = 30 },
                { bufnr = buf2, lnum = 25 }, -- newest
            }

            local selected = jumplist:select_jumps(list, #list, { bufnr = buf3, lnum = 30 }, {
                max_jumps = 4,
                project_only = false,
                root = '/proj',
            })

            -- Current location and its neighbourhood are skipped; the rest come
            -- back oldest first.
            helpers.expect_equal(vim.tbl_map(function(jump)
                return jump.bufnr .. ':' .. jump.lnum
            end, selected), { buf1 .. ':10', buf2 .. ':20', buf2 .. ':25' })

            helpers.delete_buffer(buf1)
            helpers.delete_buffer(buf2)
            helpers.delete_buffer(buf3)
        end,
    },
    {
        name = 'jumplist.select_jumps respects max_jumps and drops out-of-project files',
        run = function()
            local jumplist = make_source()

            local inside1 = named_buffer '/proj/one.lua'
            local outside = named_buffer '/elsewhere/two.lua'
            local sibling = named_buffer '/proj-other/two.lua'
            local inside2 = named_buffer '/proj/three.lua'

            local list = {
                { bufnr = inside1, lnum = 5 },
                { bufnr = outside, lnum = 6 },
                { bufnr = sibling, lnum = 6 },
                { bufnr = inside2, lnum = 7 },
            }

            local selected = jumplist:select_jumps(list, #list, { bufnr = inside2, lnum = 7 }, {
                max_jumps = 2,
                project_only = true,
                root = '/proj',
            })

            helpers.expect_equal(vim.tbl_map(function(jump)
                return jump.bufnr
            end, selected), { inside1 })

            helpers.delete_buffer(inside1)
            helpers.delete_buffer(outside)
            helpers.delete_buffer(sibling)
            helpers.delete_buffer(inside2)
        end,
    },
    {
        name = 'jumplist.snapshot builds a chunk around the most recent jump',
        run = function()
            local jumplist = make_source()

            local augroup = vim.api.nvim_create_augroup('harmonize-test-jumps', { clear = true })
            jumplist:start(augroup)

            local path = vim.fn.getcwd() .. '/test_jumplist_fixture.lua'
            local bufnr = helpers.create_buffer({ 'l0', 'l1', 'l2', 'l3', 'l4' })
            vim.bo[bufnr].buftype = ''
            vim.api.nvim_buf_set_name(bufnr, path)
            vim.api.nvim_set_current_buf(bufnr)
            vim.api.nvim_win_set_cursor(0, { 1, 0 })

            -- Two real jumps so the jumplist has an entry behind the cursor.
            vim.cmd 'normal! G'
            vim.cmd 'normal! gg'

            jumplist:refresh(bufnr)
            local chunks = jumplist:snapshot()

            helpers.expect_equal(#chunks, 1)
            helpers.expect_equal(chunks[1].bufnr, bufnr)
            helpers.expect_equal(chunks[1].start_row, 0)
            helpers.expect_equal(chunks[1].end_row, 5)
            helpers.expect_equal(chunks[1].lines, { 'l0', 'l1', 'l2', 'l3', 'l4' })
            helpers.expect_equal(chunks[1].filename, path)

            -- A second refresh with an unchanged jumplist keeps the cache.
            jumplist:refresh(bufnr)
            helpers.expect_equal(jumplist:snapshot(), chunks)

            helpers.delete_buffer(bufnr)
        end,
    },
}
