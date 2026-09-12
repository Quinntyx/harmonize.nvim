local helpers = require 'tests.helpers'
local Matching = require 'harmonize.completion.matching'

return {
    {
        name = 'current-line matching requires the complete existing suffix',
        run = function()
            helpers.expect_equal(Matching.current_line('bar)', ')'), {
                prefix = 'bar',
                suffix = ')',
            })
            helpers.expect_falsy(Matching.current_line('bar)', ') trailing'))
            helpers.expect_falsy(Matching.current_line('bar) trailing', ')'))
        end,
    },
    {
        name = 'next-line matching requires an exact complete line',
        run = function()
            helpers.expect_equal(Matching.next_line('\n    }', '    }'), '    }')
            helpers.expect_falsy(Matching.next_line('\n    }', '  }'))
            helpers.expect_falsy(Matching.next_line('\n    } trailing', '    }'))
        end,
    },
    {
        name = 'synthetic acceptance preserves matching suffixes and next lines',
        run = function()
            local lines, cursor = Matching.apply_completion(
                { 'call)', '    }', 'after' },
                { 1, 4 },
                'bar)\n    }',
                { allow_post_newline_chars = '' },
                true
            )

            helpers.expect_equal(lines, { 'callbar)', '    }', 'after' })
            helpers.expect_equal(cursor, { 2, 5 })
        end,
    },
}
