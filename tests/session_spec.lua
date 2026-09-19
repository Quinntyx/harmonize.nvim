local helpers = require 'tests.helpers'
local Session = require 'harmonize.completion.session'

return {
    {
        name = 'chunk splitting stops after horizontal whitespace',
        run = function()
            local chunk, remaining = Session.split_chunk 'data_ == other'
            helpers.expect_equal(chunk, 'data_ ')
            helpers.expect_equal(remaining, '== other')

            chunk, remaining = Session.split_chunk(remaining)
            helpers.expect_equal(chunk, '== ')
            helpers.expect_equal(remaining, 'other')
        end,
    },
    {
        name = 'chunk splitting keeps punctuation before terminating whitespace',
        run = function()
            local chunk, remaining = Session.split_chunk 'foo,   bar'
            helpers.expect_equal(chunk, 'foo,   ')
            helpers.expect_equal(remaining, 'bar')
        end,
    },
    {
        name = 'newline chunks contain only indentation by default',
        run = function()
            local chunk, remaining = Session.split_chunk '\n    .method()'
            helpers.expect_equal(chunk, '\n    ')
            helpers.expect_equal(remaining, '.method()')
        end,
    },
    {
        name = 'newline chunks can include configured punctuation',
        run = function()
            local chunk, remaining = Session.split_chunk('\n    .method()', {
                allow_post_newline_chars = '.',
            })
            helpers.expect_equal(chunk, '\n    .')
            helpers.expect_equal(remaining, 'method()')
        end,
    },
    {
        name = 'an extension can refill a completion after its cached text is consumed',
        run = function()
            local session = Session.new()
            session.suggestion = 'one'
            local stream, base = session:start_extension()

            local chunk, remaining = session:take_chunk()
            helpers.expect_equal(chunk, 'one')
            helpers.expect_equal(remaining, '')
            helpers.expect_equal(session.suggestion, '')

            helpers.expect_truthy(session:update_extension(stream, base, ' two\nthree'))
            helpers.expect_equal(session.suggestion, ' two\nthree')
            helpers.expect_equal(session:complete_line_count(), 1)
        end,
    },
}
