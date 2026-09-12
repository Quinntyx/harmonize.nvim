local helpers = require 'tests.helpers'
local Context = require 'harmonize.context'
local ContextItem = require 'harmonize.context.item'
local CursorCapture = require 'harmonize.context.cursor'

local function chunk(source, bufnr, start_row, end_row, lines, filename)
    return ContextItem.new(source, {
        bufnr = bufnr,
        filename = filename,
        start_row = start_row,
        end_row = end_row,
        lines = lines,
    })
end

local function make_context(config_overrides)
    return Context.new(helpers.merged_config(config_overrides), {})
end

return {
    {
        name = 'context.compose emits nothing when no source has chunks',
        run = function()
            local context = make_context()
            helpers.expect_falsy(context:compose({}, { start = 0 }, 1))
        end,
    },
    {
        name = 'context.compose orders sources from most to least stable',
        run = function()
            local context = make_context()
            local input_extra = context:compose({
                recent_edits = { chunk('recent_edits', 1, 50, 52, { 'edited' }, 'b.lua') },
                jumplist = { chunk('jumplist', 2, 10, 12, { 'jumped' }, 'b.lua') },
                treesitter = { chunk('treesitter', 1, 0, 1, { 'import' }, 'b.lua') },
            }, { start = 1000 }, 1)

            helpers.expect_equal(vim.tbl_map(function(entry)
                return entry.text
            end, input_extra), { 'import', 'jumped', 'edited' })
        end,
    },
    {
        name = 'context.compose drops chunks overlapping the cursor context',
        run = function()
            local context = make_context()
            -- The cursor context covers lines 10 through 19 (0-based).
            local covered = { start = 10, end_exclusive = 20 }

            local input_extra = context:compose({
                treesitter = {
                    -- Fully covered: dropped.
                    chunk('treesitter', 1, 12, 14, { 'a' }, 'b.lua'),
                    -- Outside: kept.
                    chunk('treesitter', 1, 30, 32, { 'b' }, 'b.lua'),
                    -- Straddles the start: trimmed to the larger side.
                    chunk('treesitter', 1, 5, 15, { 'c1', 'c2', 'c3', 'c4', 'c5', 'c6', 'c7', 'c8', 'c9' }, 'b.lua'),
                },
            }, covered, 1)

            local texts = vim.tbl_map(function(entry)
                return entry.text
            end, input_extra)
            -- The straddling chunk keeps lines 5-9 (5 lines) over lines 10-14 (5
            -- lines); ties keep the before side.
            helpers.expect_equal(texts, { 'c1\nc2\nc3\nc4\nc5', 'b' })
        end,
    },
    {
        name = 'context.compose enforces the global character budget',
        run = function()
            local context = make_context {
                context_sources = { max_chars = 12 },
            }
            local input_extra = context:compose({
                treesitter = {
                    chunk('treesitter', 1, 0, 1, { '1234567890' }, 'b.lua'),
                    chunk('treesitter', 1, 2, 3, { 'abc' }, 'b.lua'),
                },
            }, { start = 1000 }, 1)

            -- The first chunk uses 11 characters, so the second does not fit.
            helpers.expect_equal(vim.tbl_map(function(entry)
                return entry.text
            end, input_extra), { '1234567890' })
        end,
    },
    {
        name = 'context.compose merges overlapping chunks from the same loaded buffer',
        run = function()
            local bufnr = helpers.create_buffer({ 'one', 'two', 'three', 'four' })
            local context = make_context()

            local input_extra = context:compose({
                treesitter = {
                    chunk('treesitter', bufnr, 0, 2, { 'one', 'two' }),
                    chunk('treesitter', bufnr, 1, 4, { 'two', 'three', 'four' }),
                },
            }, { start = 100 }, bufnr)

            helpers.expect_equal(#input_extra, 1)
            helpers.expect_equal(input_extra[1].text, 'one\ntwo\nthree\nfour')
            helpers.delete_buffer(bufnr)
        end,
    },
    {
        name = 'cursor context reports the covered line range',
        run = function()
            local cursor = CursorCapture.new(helpers.merged_config { context_window = 100000 })
            local bufnr = helpers.create_buffer({ 'one', 'two', 'three', 'four', 'five' })

            local context = cursor:context(bufnr, {
                cursor = { row = 3, col = 1, line = 2 },
                cursor_before_line = 'th',
                cursor_after_line = 'ree',
            })

            helpers.expect_equal(context.covered_lines.start, 0)
            helpers.expect_falsy(context.covered_lines.end_exclusive)
            helpers.expect_equal(context.lines_before, 'one\ntwo\nth')
            helpers.delete_buffer(bufnr)
        end,
    },
    {
        name = 'cursor context can read a synthetic buffer without changing the real one',
        run = function()
            local cursor = CursorCapture.new(helpers.merged_config { context_window = 100000 })
            local bufnr = helpers.create_buffer({ 'real buffer' })
            local synthetic = { 'one', 'twoX', 'three' }

            local context = cursor:context(bufnr, {
                line = synthetic[2],
                cursor = { 2, 4 },
            }, synthetic)

            helpers.expect_equal(context.lines_before, 'one\ntwoX')
            helpers.expect_equal(context.lines_after, '\nthree')
            helpers.expect_equal(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), { 'real buffer' })
            helpers.delete_buffer(bufnr)
        end,
    },
    {
        name = 'cursor context reports truncation in the covered range',
        run = function()
            local cursor = CursorCapture.new(helpers.merged_config {
                context_window = 10,
                context_ratio = 0.5,
            })
            local bufnr = helpers.create_buffer()
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'aaaaa', 'bbbbb', 'ccccc', 'ddddd', 'eeeee' })

            -- Cursor on the last line; the before-context must truncate.
            local context = cursor:context(bufnr, {
                cursor = { row = 5, col = 1, line = 4 },
                cursor_before_line = 'd',
                cursor_after_line = '',
            })

            helpers.expect_truthy(context.opts.is_incomplete_before)
            helpers.expect_truthy(context.covered_lines.start > 0)
            helpers.expect_falsy(context.covered_lines.end_exclusive)
            helpers.delete_buffer(bufnr)
        end,
    },
}
