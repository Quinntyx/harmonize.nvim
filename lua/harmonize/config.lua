local default_prompt_prefix_first = [[
You are an AI code completion engine. Provide contextually appropriate completions:
- Code completions in code context
- Comment/documentation text in comments
- String content in string literals
- Prose in markdown/documentation files

Input markers:
- `<contextAfterCursor>`: Context after cursor
- `<cursorPosition>`: Current cursor location
- `<contextBeforeCursor>`: Context before cursor
]]

local default_prompt = default_prompt_prefix_first
    .. [[

Note that the user input will be provided in **reverse** order: first the
context after cursor, followed by the context before cursor.
]]

local default_guidelines = [[
Guidelines:
1. Offer completions after the `<cursorPosition>` marker.
2. Make sure you have maintained the user's existing whitespace and indentation.
   This is REALLY IMPORTANT!
3. Provide multiple completion options when possible.
4. Return completions separated by the marker <endCompletion>.
5. The returned message will be further parsed and processed. DO NOT include
   additional comments or markdown code block fences. Return the result directly.
6. Keep each completion option concise, limiting it to a single line or a few lines.
7. Create entirely new code completion that DO NOT REPEAT OR COPY any user's existing code around <cursorPosition>.]]

local default_few_shots = {
    {
        role = 'user',
        content = [[
# language: javascript
<contextAfterCursor>
    return result;
}

const processedData = transformData(rawData, {
    uppercase: true,
    removeSpaces: false
});
<contextBeforeCursor>
function transformData(data, options) {
    const result = [];
    for (let item of data) {
        <cursorPosition>]],
    },
    {
        role = 'assistant',
        content = [[
let processed = item;
        if (options.uppercase) {
            processed = processed.toUpperCase();
        }
        if (options.removeSpaces) {
            processed = processed.replace(/\s+/g, '');
        }
        result.push(processed);
    }
<endCompletion>
if (typeof item === 'string') {
            let processed = item;
            if (options.uppercase) {
                processed = processed.toUpperCase();
            }
            if (options.removeSpaces) {
                processed = processed.replace(/\s+/g, '');
            }
            result.push(processed);
        } else {
            result.push(item);
        }
    }
<endCompletion>
]],
    },
}

local default_few_shots_prefix_first = {
    {
        role = 'user',
        content = [[
# language: javascript
<contextBeforeCursor>
function transformData(data, options) {
    const result = [];
    for (let item of data) {
        <cursorPosition>
<contextAfterCursor>
    return result;
}

const processedData = transformData(rawData, {
    uppercase: true,
    removeSpaces: false
});]],
    },
    default_few_shots[2],
}

local n_completion_template = '8. Provide at most %d completion items.'

-- use {{{ and }}} to wrap placeholders, which will be further processesed in other function
local default_system_template = '{{{prompt}}}\n{{{guidelines}}}\n{{{n_completion_template}}}'

local default_fim_prompt = function(context_before_cursor, _, _)
    local comment = require 'harmonize.comment'
    local language = comment.add_language_comment()
    local tab = comment.add_tab_comment()
    context_before_cursor = language .. '\n' .. tab .. '\n' .. context_before_cursor

    return context_before_cursor
end

local default_fim_suffix = function(_, context_after_cursor, _)
    return context_after_cursor
end

---@class harmonize.ChatInputExtraInfo
---@field is_incomplete_before boolean
---@field is_incomplete_after boolean

---@alias harmonize.ChatInputFunction fun(context_before_cursor: string, context_after_cursor: string, opts: harmonize.ChatInputExtraInfo): string
---@alias harmonize.FIMTemplateFunction harmonize.ChatInputFunction

--- Configuration for formatting chat input to the LLM
---@class harmonize.ChatInput
---@field template string Template string with placeholders for context parts
---@field language harmonize.ChatInputFunction function to add language comment based on filetype
---@field tab harmonize.ChatInputFunction function to add indentation style comment
---@field context_before_cursor harmonize.ChatInputFunction function to process text before cursor
---@field context_after_cursor harmonize.ChatInputFunction function to process text after cursor

---@type harmonize.ChatInput
local default_chat_input = {
    template = '{{{language}}}\n{{{tab}}}\n<contextAfterCursor>\n{{{context_after_cursor}}}\n<contextBeforeCursor>\n{{{context_before_cursor}}}<cursorPosition>',
    language = function(_, _, _)
        local comment = require 'harmonize.comment'
        return comment.add_language_comment()
    end,
    tab = function(_, _, _)
        local comment = require 'harmonize.comment'
        return comment.add_tab_comment()
    end,
    context_before_cursor = function(context_before_cursor, _, opts)
        if opts.is_incomplete_before then
            -- Remove first line when context is incomplete at start
            local _, rest = context_before_cursor:match '([^\n]*)\n(.*)'
            return rest or context_before_cursor
        end
        return context_before_cursor
    end,
    context_after_cursor = function(_, context_after_cursor, opts)
        if opts.is_incomplete_after then
            -- Remove last line when context is incomplete at end
            local content = context_after_cursor:match '(.*)[\n][^\n]*$'
            return content or context_after_cursor
        end
        return context_after_cursor
    end,
}

---@type harmonize.ChatInput
local default_chat_input_prefix_first = vim.deepcopy(default_chat_input)
default_chat_input_prefix_first.template =
    '{{{language}}}\n{{{tab}}}\n<contextBeforeCursor>\n{{{context_before_cursor}}}<cursorPosition>\n<contextAfterCursor>\n{{{context_after_cursor}}}'

local M = {
    -- Filetypes where automatic completion is enabled, e.g.
    -- { 'python', 'lua' }. Manual completion still works everywhere.
    auto_trigger_ft = {},
    -- Filetypes where automatic completion stays off, useful when
    -- auto_trigger_ft = { '*' }.
    auto_trigger_ignore_ft = {},
    keymap = {
        -- Nothing is bound by default: a blank config changes no keybinds.
        -- accept takes one chunk: the current identifier plus the special
        -- characters that follow it.
        accept = nil,
        -- accept the visible line
        accept_line = nil,
        -- dismiss the ghost text
        dismiss = nil,
        -- manually request a completion
        trigger = nil,
        -- toggle auto-completion on and off
        toggle = nil,
    },
    -- What the ghost text shows. 'below' overlays same-line completions beneath
    -- the cursor; newline-leading text uses its actual next-line position.
    -- 'line' overlays the current line, and 'chunk' shows what accept takes.
    ---@type 'below' | 'line' | 'chunk'
    display = 'below',
    -- Fade each successive accepted chunk by a linear opacity step. The
    -- minimum keeps long completions readable.
    chunk_fade = {
        enabled = true,
        opacity_step = 0.25,
        minimum_opacity = 0.1,
    },
    -- When requests fire. 'on_type' requests only after a character was
    -- typed: arrow-key moves and scrolling dismiss the ghost text without
    -- requesting, and entering insert mode alone does not trigger either.
    -- 'on_insert' triggers after any pause in insert mode.
    ---@type 'on_type' | 'on_insert'
    completion_trigger = 'on_type',
    -- Keep requesting and rendering while another completion menu is open.
    -- The menu is drawn above harmonize's preview when they overlap.
    show_with_completion_menu = true,
    -- No provider is configured by default: a blank config does nothing
    -- until you set this (see the README's install snippet). The provider
    -- options below still have defaults.
    provider = nil,
    -- Only llama_cpp and openai_fim_compatible are tested. Other
    -- providers are kept for compatibility and warn on setup unless this is
    -- true.
    allow_unsupported_providers = false,
    -- When set to a table, starts a llama.cpp server for the llama_cpp
    -- provider when none is running at the host and port below; fields
    -- merge over harmonize.default_auto_start. Nil by default, so a blank
    -- config never downloads a model or loads it into VRAM: run the server
    -- yourself and point provider_options.llama_cpp.end_point at it.
    ---@type table?
    auto_start = nil,
    -- the maximum total characters of the context before and after the cursor
    -- 16000 characters typically equate to approximately 4,000 tokens for
    -- LLMs.
    context_window = 16000,
    -- when the total characters exceed the context window, the ratio of
    -- context before cursor and after cursor, the larger the ratio the more
    -- context before cursor will be used. This option should be between 0 and
    -- 1, context_ratio = 0.75 means the ratio will be 3:1.
    context_ratio = 0.75,
    -- Extra context sources composed into the llama_cpp provider's
    -- input_extra field. Each source runs in the background and caches its
    -- result, so building the request never waits on parsing or file reads.
    ---@type table
    context_sources = {
        -- Maximum total characters of extra context across all sources.
        max_chars = 8192,
        -- Imports and enclosing declaration headers from the treesitter
        -- syntax tree. Needs a parser for the filetype; without one the
        -- source contributes nothing.
        treesitter = {
            enabled = true,
            max_chars = 2048,
        },
        -- Recently edited regions across the project. Each region expands
        -- by whole lines up to the character budgets.
        recent_edits = {
            enabled = true,
            max_edits = 4,
            chars_before = 384,
            chars_after = 384,
        },
        -- Recently visited jumplist locations. Each location expands by
        -- whole lines up to the character budgets.
        jumplist = {
            enabled = true,
            max_jumps = 4,
            chars_before = 384,
            chars_after = 384,
            -- Ignore jumps to files outside the current project root.
            project_only = true,
        },
    },
    throttle = 0, -- only send the request every x milliseconds, use 0 to disable throttle.
    -- debounce the request in x milliseconds, set to 0 to disable debounce
    debounce = 200,
    -- Control notification display for request status
    -- Notification options:
    -- false: Disable all notifications (use boolean false, not string "false")
    -- "debug": Display all notifications (comprehensive debugging)
    -- "verbose": Display most notifications
    -- "warn": Display warnings and errors only
    -- "error": Display errors only
    notify = 'warn',
    -- The request timeout, measured in seconds. When streaming is enabled
    -- (stream = true), setting a shorter request_timeout allows for faster
    -- retrieval of completion items, albeit potentially incomplete.
    -- Conversely, with streaming disabled (stream = false), a timeout
    -- occurring before the LLM returns results will yield no completion items.
    request_timeout = 3,
    -- Command used to make HTTP requests.
    curl_cmd = 'curl',
    -- Extra arguments passed to curl (list of strings, or a function returning a list of strings).
    ---@type string[] | fun(): string[]
    curl_extra_args = {},
    -- Length of context after cursor used to filter completion text.
    --
    -- This setting helps prevent the language model from generating redundant
    -- text.  When filtering completions, the system compares the suffix of a
    -- completion candidate with the text immediately following the cursor.
    --
    -- If the length of the longest common substring between the end of the
    -- candidate and the beginning of the post-cursor context exceeds this
    -- value, that common portion is trimmed from the candidate.
    --
    -- For example, if the value is 15, and a completion candidate ends with a
    -- 20-character string that exactly matches the 20 characters following the
    -- cursor, the candidate will be truncated by those 20 characters before
    -- being delivered.
    -- Each provider falls back to its own default when this key is not set.
    ---@type integer?
    after_cursor_filter_length = nil,
    -- Similar to after_cursor_filter_length but trim the completion item from
    -- prefix instead of suffix. Each provider falls back to its own default.
    ---@type integer?
    before_cursor_filter_length = nil,
    proxy = nil,
}

M.default_system = {
    template = default_system_template,
    prompt = default_prompt,
    guidelines = default_guidelines,
    n_completion_template = n_completion_template,
}

M.default_system_prefix_first = {
    template = default_system_template,
    prompt = default_prompt_prefix_first,
    guidelines = default_guidelines,
    n_completion_template = n_completion_template,
}

M.default_chat_input = default_chat_input
M.default_chat_input_prefix_first = default_chat_input_prefix_first

M.default_few_shots = default_few_shots
M.default_few_shots_prefix_first = default_few_shots_prefix_first

--- Configuration for FIM template
---@class harmonize.FIMTemplate
---@field prompt harmonize.FIMTemplateFunction
---@field suffix harmonize.FIMTemplateFunction | boolean

---@type harmonize.FIMTemplate
M.default_fim_template = {
    prompt = default_fim_prompt,
    suffix = default_fim_suffix,
}

-- Defaults for the opt-in auto_start table, which starts a llama.cpp server
-- for the llama_cpp provider when none is running at host:port.
M.default_auto_start = {
    -- The base command. The binary is looked up on PATH; a downloaded
    -- llama.cpp release is used when it is missing.
    cmd = 'llama serve',
    -- A Hugging Face GGUF repo or a local model file.
    model = 'ggml-org/Qwen2.5-Coder-1.5B-Q8_0-GGUF',
    -- Extra command-line arguments, in the style of curl_extra_args.
    ---@type string[] | fun(): string[]
    extra_args = {},
    -- Stop the server when nvim exits.
    kill_on_exit = false,
    -- Where the server listens; keep provider_options.llama_cpp.end_point
    -- in sync.
    host = '127.0.0.1',
    port = 8012,
}
M.provider_options = {
    llama_cpp = {
        -- llama.cpp's native fill-in-the-middle endpoint: the server
        -- constructs the FIM prompt with the model's own tokens, so no
        -- per-model template is needed.
        end_point = 'http://127.0.0.1:8012/infill',
        -- Set to the name of an environment variable holding the key when
        -- the server runs with --api-key.
        api_key = nil,
        name = 'llama.cpp',
        stream = true,
        -- Extra JSON body fields for the /infill request, e.g.
        -- { n_predict = 256, cache_reuse = 256 }.
        optional = {},
        -- a list of functions to transform the endpoint, header, and request body
        transform = {},
    },
    codestral = {
        model = 'codestral-latest',
        end_point = 'https://codestral.mistral.ai/v1/fim/completions',
        api_key = 'CODESTRAL_API_KEY',
        stream = true,
        template = M.default_fim_template,
        optional = {
            stop = nil, -- the identifier to stop the completion generation
            max_tokens = nil,
        },
        -- a list of functions to transform the endpoint, header, and request body
        transform = {},
        -- Custom function to extract LLM-generated text from JSON output
        get_text_fn = {},
    },
    openai = {
        model = 'gpt-5.6-luna',
        api_key = 'OPENAI_API_KEY',
        end_point = 'https://api.openai.com/v1/chat/completions',
        system = M.default_system_prefix_first,
        few_shots = M.default_few_shots_prefix_first,
        chat_input = M.default_chat_input_prefix_first,
        stream = true,
        optional = {
            stop = nil,
            max_tokens = nil,
        },
        -- a list of functions to transform the endpoint, header, and request body
        transform = {},
    },
    claude = {
        max_tokens = 256,
        api_key = 'ANTHROPIC_API_KEY',
        model = 'claude-haiku-4-5',
        end_point = 'https://api.anthropic.com/v1/messages',
        system = M.default_system,
        chat_input = M.default_chat_input,
        few_shots = M.default_few_shots,
        stream = true,
        optional = {
            stop_sequences = nil,
        },
        -- a list of functions to transform the endpoint, header, and request body
        transform = {},
    },
    openai_compatible = {
        model = 'deepseek/deepseek-v4-flash',
        system = M.default_system_prefix_first,
        chat_input = M.default_chat_input_prefix_first,
        few_shots = M.default_few_shots_prefix_first,
        end_point = 'https://openrouter.ai/api/v1/chat/completions',
        api_key = 'OPENROUTER_API_KEY',
        name = 'Openrouter',
        stream = true,
        optional = {
            stop = nil,
            max_tokens = nil,
        },
        -- a list of functions to transform the endpoint, header, and request body
        transform = {},
    },
    gemini = {
        model = 'gemini-2.0-flash',
        api_key = 'GEMINI_API_KEY',
        end_point = 'https://generativelanguage.googleapis.com/v1beta/models',
        system = M.default_system_prefix_first,
        chat_input = M.default_chat_input_prefix_first,
        few_shots = M.default_few_shots_prefix_first,
        stream = true,
        optional = {},
        -- a list of functions to transform the endpoint, header, and request body
        transform = {},
    },
    openai_fim_compatible = {
        model = 'deepseek-v4-flash',
        end_point = 'https://api.deepseek.com/beta/completions',
        api_key = 'DEEPSEEK_API_KEY',
        name = 'Deepseek',
        stream = true,
        template = M.default_fim_template,
        optional = {
            stop = nil,
            max_tokens = nil,
        },
        -- a list of functions to transform the endpoint, header, and request body
        transform = {},
        -- Custom function to extract LLM-generated text from JSON output
        get_text_fn = {},
    },
}

M.presets = {}

-- **List** of functions to execute. If any function returns `false`, Harmonize
-- will not trigger auto-completion. Manual completion can still be invoked,
-- even if these functions evaluate to `false`, when using virtual text
-- (excluding LSP).
-- Note that this is called each time Harmonize attempts to trigger
-- auto-completion, so ensure the functions in this list are highly efficient.
---@type (fun(): boolean)[]
M.enable_predicates = {}

return M
