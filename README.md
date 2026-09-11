# harmonize.nvim

Streaming AI tab completion for Neovim, rewritten from
[minuet-ai.nvim](https://github.com/milanglacier/minuet-ai.nvim). Point it at
an endpoint and Tab completes in chunks, with a one-line preview updated as
the model generates tokens.

## Features

- Stable below-line preview: suggestions overlay the screen line below the
  cursor without moving buffer lines, and refresh on every streaming token.
  Long lines are clipped at the window edge instead of wrapping.
- Chunk-wise acceptance: Tab accepts one cached chunk at a time (the current
  identifier plus the special characters that follow it), so long completions
  arrive in reviewable steps without starting another request.
- Confidence fade: each successive chunk is 10% less opaque by default, making
  chunk boundaries visible while keeping the next chunk most prominent.
- Completion-menu coexistence: LSP, nvim-cmp, and blink menus are drawn above
  the Harmonize preview while both remain available.
- Token streaming: the completion is a character stream — the model appends
  to the back while typing and Tab take from the front, so the first chunk
  appears quickly even on slow local models.
- Typing sync: when typed text matches the start of the suggestion, the
  suggestion advances instead of being discarded and re-requested.
- `llama_cpp` provider for llama.cpp's native `/infill` endpoint, with
  optional automatic server startup, and `openai_fim_compatible` for any
  OpenAI FIM-compatible service. Other providers inherited from
  minuet-ai.nvim are present but untested.

## Benchmarks

Work in progress: time-to-first-token and time-to-first-line measurements for
local llama.cpp setups will live here.

## Requirements

- Neovim 0.10+
- `curl`
- A completion backend: a llama.cpp server (the `llama_cpp` provider can
  start one for you) or an OpenAI FIM-compatible endpoint

## Installation

Installing the plugin alone changes nothing: no keys are bound, no ghost
text appears, and no provider is configured. The snippet below is what turns
it on — note that it binds `<Tab>` to accept one chunk, so pasting it is a
deliberate change to your Tab key:

```lua
{
    'Quinntyx/harmonize.nvim',
    config = function()
        require('harmonize').setup {
            provider = 'llama_cpp',
            -- ghost text in every filetype
            auto_trigger_ft = { '*' },
            keymap = {
                accept = '<Tab>', -- binds <Tab>: accept one chunk
            },
            provider_options = {
                llama_cpp = {
                    end_point = 'http://localhost:8012/infill',
                    optional = {
                        n_predict = 256,
                        top_p = 0.9,
                    },
                },
            },
            auto_start = {
                model = 'ggml-org/Qwen2.5-Coder-1.5B-Q8_0-GGUF',
                host = '127.0.0.1',
                port = 8012,
                extra_args = { '-ngl', '99', '--ctx-size', '8192' },
            },
        }
    end,
}
```

## Quick Start

The installation snippet above is a working setup: the `llama_cpp` provider
talks to llama.cpp's native `/infill` endpoint, `auto_trigger_ft` shows the
ghost text everywhere, `keymap.accept` binds Tab, and the `auto_start` table
has harmonize start the server for you — it downloads a llama.cpp binary if
needed, runs `llama serve` with the model (pulled from HuggingFace on the
first start), and leaves the server running when nvim exits so the next
launch reuses it without reloading the model.

Notes on `auto_start`:

- It is nil by default, so a blank config never downloads a model or loads it
  into VRAM. Setting it to a table opts in; a partial table merges over
  `default_auto_start`, so `{ model = '...' }` alone is a complete setup.
- If `llama` or `llama-server` is already on PATH it is used as is; otherwise
  one is downloaded. The first start downloads the model, so the first
  request may fail until it is ready.
- Set `kill_on_exit = true` to stop the server when nvim exits — but with
  several nvim instances sharing one server, the first one to exit would kill
  it for everyone.
- Keep `provider_options.llama_cpp.end_point` in sync with the host and port.

Prefer to manage the server yourself? Leave `auto_start` unset and point the
provider at your server — you still get the native `/infill` endpoint, which
constructs the FIM prompt from the model's own tokens (no per-model template
needed):

```lua
require('harmonize').setup {
    provider = 'llama_cpp',
    provider_options = {
        llama_cpp = {
            end_point = 'http://localhost:8012/infill',
            optional = {
                n_predict = 256, -- the stream cap; the first chunk arrives fast anyway
                top_p = 0.9,
            },
        },
    },
}
```

Tab accepts the next chunk out of the box; see the keymap defaults below.
For cloud providers, see [Providers](#providers) and [API keys](#api-keys).

## Sample config

A complete llama.cpp setup that turns everything on. Every field is filled
in, so edit the values rather than starting from scratch — harmonize
deep-merges your config over its defaults, so omitting a field keeps the
default (and a blank config does nothing at all).

```lua
require('harmonize').setup {
    provider = 'llama_cpp',

    -- 'below' overlays the first completion line directly below the cursor;
    -- 'line' overlays the current line; 'chunk' shows the next accepted chunk.
    display = 'below',
    chunk_fade = {
        enabled = true,
        opacity_step = 0.1,
        minimum_opacity = 0.1,
    },
    -- When requests fire: 'on_type' only after a character is typed,
    -- 'on_insert' on any pause except after backspace.
    completion_trigger = 'on_type',
    -- Keep Harmonize visible below another completion menu.
    show_with_completion_menu = true,
    -- Filetypes where auto-completion fires; use { '*' } for all. Manual
    -- completion (keymap.trigger) works everywhere either way.
    auto_trigger_ft = { 'lua', 'python', 'rust' },
    -- Filetypes to skip when auto_trigger_ft contains '*'.
    auto_trigger_ignore_ft = {},

    keymap = {
        accept = '<Tab>',      -- accept one chunk
        accept_line = '<M-a>', -- accept the visible line
        dismiss = '<M-e>',     -- dismiss the ghost text
        trigger = '<M-]>',     -- request a completion now
        toggle = '<M-c>',      -- toggle auto-completion on and off
    },

    -- Server startup for the llama_cpp provider (nil by default — this
    -- table opts in): when nothing answers at host:port, harmonize runs the
    -- command below with the model and leaves the server running when nvim
    -- exits. Drop this table to run the server yourself and keep
    -- provider_options.llama_cpp.end_point pointed at it.
    auto_start = {
        cmd = 'llama serve', -- binary looked up on PATH; downloaded when missing
        model = 'ggml-org/Qwen2.5-Coder-1.5B-Q8_0-GGUF', -- HF repo or local .gguf path
        extra_args = { '-ngl', '99', '--ctx-size', '8192' },
        kill_on_exit = false,
        host = '127.0.0.1', -- keep end_point in sync with these two
        port = 8012,
    },

    provider_options = {
        llama_cpp = {
            end_point = 'http://127.0.0.1:8012/infill',
            -- api_key = 'LLAMA_API_KEY', -- only for servers run with --api-key
            name = 'llama.cpp',
            stream = true,
            -- Extra JSON fields for the /infill request body.
            optional = { n_predict = 256, top_p = 0.9 },
            transform = {},
        },
    },

    -- Maximum characters of context before and after the cursor
    -- (~4000 tokens at 16000 characters).
    context_window = 16000,
    -- When the context exceeds the window, the share kept before the cursor
    -- (0.75 means a 3:1 before/after split).
    context_ratio = 0.75,
    -- Extra context from treesitter structure, recent edits, and the
    -- jumplist; see the Configuration section. Enabled with these defaults
    -- for the llama_cpp provider.
    context_sources = {
        max_chars = 8192,
        treesitter = { enabled = true, max_chars = 2048 },
        recent_edits = { enabled = true, max_edits = 4, chars_before = 384, chars_after = 384 },
        jumplist = { enabled = true, max_jumps = 4, chars_before = 384, chars_after = 384, project_only = true },
    },
    throttle = 0,
    -- Milliseconds to wait after typing stops before requesting; 0 disables.
    debounce = 200,
    -- Request timeout in seconds. With streaming, a timeout cut keeps the
    -- partial text generated so far.
    request_timeout = 3,
    -- false, "debug", "verbose", "warn", or "error".
    notify = 'warn',
    curl_cmd = 'curl',
    curl_extra_args = {},
    -- A proxy URL passed to curl as --proxy, or nil.
    proxy = nil,
    -- Auto-completion fires only while every predicate returns true.
    enable_predicates = {},
    -- llama_cpp and openai_fim_compatible are the tested providers; others
    -- warn on setup unless this is true.
    allow_unsupported_providers = false,
}
```

## Usage

The completion is a character stream: the model keeps appending tokens to the
back while you take from the front. The visible suggestion is always the part
you have not taken yet, and it is redrawn on every token.

- **Tab** (`accept`) accepts one chunk. A chunk walk consumes
  alphanumeric characters and underscores; the first special character
  switches to terminating mode, in which the next alphanumeric character ends
  the chunk. A newline ends the chunk unless it is the first character (the
  case in which the line below is shown). So `b)\n.c()` is accepted as `b)`,
  then `\n.`, then `c()`.
- By default, requests fire only after you actually type a character:
  arrow-key moves and scrolling only dismiss a stale suggestion, and entering
  insert mode alone does not trigger a request. Set
  `completion_trigger = 'on_insert'` to request on any pause instead.
- `display = 'below'` overlays the first completion line directly below the
  cursor without adding a buffer line. `display = 'line'` overlays the current
  line, and `display = 'chunk'` shows exactly what the next accept completes.
- Typing the same characters keeps the remaining suggestion in sync; typing
  something different dismisses it and starts a fresh request.
- When a chunk would cross a newline in the middle, it stops first — you never
  accept text the view did not show.
- `accept_line` takes the whole visible line.
- A `toggle` keymap switches automatic completion on and off (same as
  `:Harmonize virtualtext toggle`).
- The `trigger` keymap requests a completion on demand — useful in `'on_type'`
  mode after navigating somewhere.

### Keymaps

Nothing is bound by default — a blank config changes no keybinds. The
actions are wired through `keymap`: `accept` (accept one chunk — the install
snippet and sample config bind this to `<Tab>`), `accept_line` (accept the
visible line), `dismiss`, `trigger` (manually request a completion), and
`toggle` (toggle auto-completion).

## Configuration

```lua
default_config = {
    -- Filetypes for automatic ghost-text completion. Manual completion
    -- still works in any filetype.
    auto_trigger_ft = {},
    -- Filetypes to exclude when auto_trigger_ft = { '*' }
    auto_trigger_ignore_ft = {},
    keymap = {
        -- accept one chunk: the current identifier plus the special
        -- characters that follow it. Nothing is bound by default.
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
    -- 'below' overlays the first completion line directly below the cursor;
    -- 'line' overlays the current line; 'chunk' shows the next accepted chunk.
    display = 'below',
    -- Fade successive chunks linearly. 0.1 means ten percentage points per
    -- chunk; the minimum keeps the rest readable.
    chunk_fade = {
        enabled = true,
        opacity_step = 0.1,
        minimum_opacity = 0.1,
    },
    -- When requests fire: 'on_type' only after a character was typed,
    -- 'on_insert' on any pause in insert mode except after backspace.
    completion_trigger = 'on_type',
    -- Keep harmonize active while another completion menu is open. The menu
    -- is drawn above the ghost text when they overlap.
    show_with_completion_menu = true,
    -- No provider by default: a blank config does nothing until you set
    -- this. The provider options below still have defaults.
    provider = nil,
    -- Only llama_cpp and openai_fim_compatible are tested. Other
    -- providers warn on setup unless this is true.
    allow_unsupported_providers = false,
    -- Maximum characters of context before and after the cursor (~4 tokens
    -- per 100 chars for most LLMs).
    context_window = 16000,
    -- When the context exceeds the window, the ratio kept before the cursor.
    context_ratio = 0.75,
    -- Extra context sent to the llama_cpp provider alongside the cursor
    -- context. Each source is collected in the background and cached, so
    -- building a request never parses or reads files. Chunks that overlap
    -- the cursor context are dropped, and the total is capped by max_chars.
    context_sources = {
        max_chars = 8192,
        -- Imports and the headers of the declarations enclosing the cursor,
        -- from the treesitter syntax tree. Needs a parser for the filetype;
        -- without one this source sends nothing.
        treesitter = { enabled = true, max_chars = 2048 },
        -- Recently edited regions across the project, expanded by whole
        -- lines around each edit.
        recent_edits = { enabled = true, max_edits = 4, chars_before = 384, chars_after = 384 },
        -- Recently visited jumplist locations, expanded by whole lines
        -- around each jump.
        jumplist = { enabled = true, max_jumps = 4, chars_before = 384, chars_after = 384, project_only = true },
    },
    throttle = 0, -- only request every x ms; 0 disables
    debounce = 200, -- debounce requests by x ms; 0 disables
    -- false, "debug", "verbose", "warn", or "error"
    notify = 'warn',
    -- Request timeout in seconds. With streaming, a timeout cut keeps the
    -- partial text generated so far.
    request_timeout = 3,
    curl_cmd = 'curl',
    curl_extra_args = {},
    -- Trim completion prefixes/suffixes that duplicate the surrounding text.
    -- Left unset, each provider picks its own numbers (before / after): 0 / 0
    -- for openai_fim_compatible, whose models emit intentional whitespace, and
    -- 2 / 15 for llama_cpp and the chat providers. Either value may be a
    -- function returning the number.
    after_cursor_filter_length = nil,
    before_cursor_filter_length = nil,
    proxy = nil,
    -- A list of predicates; auto-completion fires only while all return true.
    enable_predicates = {},
    -- Opt in to harmonize starting (or reusing) a llama.cpp server for the
    -- llama_cpp provider; see the Quick Start section. Nil by default, so a
    -- blank config never downloads a model or loads it into VRAM.
    auto_start = nil,
    provider_options = {
        -- see the Quick Start section for llama_cpp and the Providers
        -- section for the other providers' defaults
        llama_cpp = { ... },
    },
    -- Prompt specs for chat models; see the Prompt section.
    default_system = { ... },
    default_system_prefix_first = { ... },
    default_fim_template = { ... },
    default_few_shots = { ... },
    default_chat_input = { ... },
    default_few_shots_prefix_first = { ... },
    default_chat_input_prefix_first = { ... },
    -- Config sets for the `Harmonize change_preset` command
    presets = {},
}
```

## API keys

Set the environment variable named in each provider's `api_key` field:

- `OPENAI_API_KEY` for OpenAI
- `GEMINI_API_KEY` for Gemini
- `ANTHROPIC_API_KEY` for Claude
- `CODESTRAL_API_KEY` for Codestral
- A custom variable for OpenAI-compatible services (as configured)

Pass harmonize the **name** of the environment variable, not the value, or a
function returning the key:

```lua
require('harmonize').setup {
    provider_options = {
        openai_compatible = {
            api_key = 'FIREWORKS_API_KEY', -- reads the environment variable
            -- api_key = function() return 'sk-xxxx' end,
        },
    },
}
```

With Ollama, assign any non-null environment variable (e.g. `TERM`) as a
placeholder. The `llama_cpp` provider needs no API key; set `api_key` only
when your server runs with `--api-key`.

## Prompt

See [prompt](./prompt.md) for the default prompts and how to customize them.
Harmonize uses two prompt systems: one for chat-based LLMs (OpenAI,
OpenAI-compatible, Claude, Gemini) and one for fill-in-the-middle models
(Codestral, OpenAI-FIM-compatible).

For chat models there are two construction styles: prefix-first (context
before the cursor first) and suffix-first. The defaults use prefix-first for
OpenAI, Gemini, and OpenAI-compatible, and suffix-first for Claude:

```lua
local config = require 'harmonize.config'

require('harmonize').setup {
    provider_options = {
        openai_compatible = {
            system = config.default_system_prefix_first,
            chat_input = config.default_chat_input_prefix_first,
            few_shots = config.default_few_shots_prefix_first,
        },
    },
}
```

## Providers

Set `provider` in the config; the default is `openai_fim_compatible`.

Only `llama_cpp` (see [Quick Start](#quick-start)) and
`openai_fim_compatible` are tested and maintained. The providers below are
kept for compatibility with minuet-ai.nvim configs but are untested, because
their paid APIs are not available for testing; using one shows a warning on
setup unless `allow_unsupported_providers = true`.

<details>
<summary>OpenAI</summary>

```lua
provider_options = {
    openai = {
        model = 'gpt-5.6-luna',
        end_point = 'https://api.openai.com/v1/chat/completions',
        stream = true,
        api_key = 'OPENAI_API_KEY',
        optional = {},
        transform = {}, -- functions rewriting the endpoint, headers, and body
    },
}
```

For GPT-5-series models, use `max_completion_tokens` (not `max_tokens`), the
models do not support `top_p`/`temperature`, and disable thinking with
`reasoning_effort = 'none'` (or `'minimal'`).

</details>

<details>
<summary>Claude</summary>

```lua
provider_options = {
    claude = {
        model = 'claude-haiku-4.5',
        end_point = 'https://api.anthropic.com/v1/messages',
        stream = true,
        api_key = 'ANTHROPIC_API_KEY',
        optional = {},
        transform = {},
    },
}
```

</details>

<details>
<summary>Codestral</summary>

Codestral is a completion model, not a chat model, so system prompts and
few-shot examples do not apply. Use `CODESTRAL_API_KEY` (not
`MISTRAL_API_KEY`); to use the Mistral endpoint, change `end_point` and
`api_key` accordingly.

```lua
provider_options = {
    codestral = {
        model = 'codestral-latest',
        end_point = 'https://codestral.mistral.ai/v1/fim/completions',
        api_key = 'CODESTRAL_API_KEY',
        stream = true,
        template = {
            prompt = "See [Prompt] section",
            suffix = "See [Prompt] section",
        },
        optional = {},
    },
}
```

</details>

<details>
<summary>Gemini</summary>

Register via Google AI Studio and get an API key from the [Google API
page](https://makersuite.google.com/app/apikey). Prefer `gemini-2.0-flash`
over the 2.5 series: similar output at significantly lower cost, without the
thinking mode that adds latency for no completion value.

```lua
provider_options = {
    gemini = {
        model = 'gemini-2.0-flash',
        end_point = 'https://generativelanguage.googleapis.com/v1beta/models',
        stream = true,
        api_key = 'GEMINI_API_KEY',
        optional = {},
        transform = {},
    },
}
```

To keep output small and disable thinking on 2.5/3.x models:

```lua
provider_options = {
    gemini = {
        optional = {
            generationConfig = {
                maxOutputTokens = 256,
                thinkingConfig = {
                    thinkingBudget = 0, -- 2.5 models
                    thinkingLevel = 'minimal', -- 3.x models
                },
            },
        },
    },
}
```

</details>

<details>
<summary>OpenAI-compatible</summary>

Any provider compatible with the OpenAI chat-completions API, e.g. Ollama at
`http://localhost:11434/v1/chat/completions`. If your service does not support
streaming, set `stream = false`.

```lua
provider_options = {
    openai_compatible = {
        model = 'deepseek/deepseek-v4-flash',
        end_point = 'https://openrouter.ai/api/v1/chat/completions',
        api_key = 'OPENROUTER_API_KEY',
        name = 'Openrouter',
        stream = true,
        optional = {},
        transform = {},
    },
}
```

Disabling thinking for reasoning models:

| Provider         | Configuration                                              |
| ---------------- | ---------------------------------------------------------- |
| **OpenRouter**   | `reasoning = { effort = 'none' }` (or `'minimal'`)         |
| **DeepSeek API** | `thinking = { type = 'disabled' }`                         |
| **Various**      | `reasoning_effort = 'none'`                                |

</details>

<details>
<summary>OpenAI-FIM-compatible</summary>

Any provider compatible with the OpenAI text `/completions` endpoint (not
`/chat/completions`), so system prompts and few-shot examples do not apply.
Examples: Ollama at `http://localhost:11434/v1/completions`, DeepSeek's beta
completions endpoint. For llama.cpp prefer the native `llama_cpp` provider
(see [Quick Start](#quick-start)), which uses the `/infill` endpoint.

For Ollama, verify the model template supports FIM: `qwen2.5-coder` does;
`deepseek-coder` does not — use `deepseek-coder-v2` instead.

```lua
provider_options = {
    openai_fim_compatible = {
        model = 'deepseek-v4-flash',
        end_point = 'https://api.deepseek.com/beta/completions',
        api_key = 'DEEPSEEK_API_KEY',
        name = 'Deepseek',
        stream = true,
        template = {
            prompt = "See [Prompt] section for the default value",
            suffix = "See [Prompt] section for the default value",
        },
        transform = {},
        optional = {},
    },
}
```

Special FIM tokens vary by model; the llama.cpp example at the top of this
README uses the Qwen2.5-Coder tokens. For llama.cpp launch scripts tuned to
your hardware, and for FIM providers that are not OpenAI-compatible (such as
DeepInfra), see [recipes.md](./recipes.md).

</details>

## Selecting a provider or model

`gemini-2.0-flash` and `codestral` give high-quality output with free, fast
processing; `deepseek-v4-flash` on the FIM provider is cheap and fast for
remote APIs. Locally, `qwen-2.5-coder` (via Ollama or llama.cpp) is a good
default. Avoid thinking models — the extra latency hurts completion even on
fast models.

Latency beats quality for completion: harmonize completes incrementally, so
a fast first token on a smaller model is worth more than a slow one on a
better one. Aim for a time to first token of 50–100 ms — streaming from a
local llama.cpp server is the default setup for exactly this reason.
Throughput still matters, but only for how quickly the rest of the
suggestion arrives after the first chunk. For local models, the `llama_cpp`
provider uses llama.cpp's native `/infill` endpoint.

## Commands

- `Harmonize change_provider <name>` — switch the active provider.
- `Harmonize change_model [provider:model]` — with no argument, opens
  `vim.ui.select` over the models in `modelcard`; otherwise sets
  `provider:model` directly. This cannot switch the model loaded by a
  llama.cpp server; restart that server with the desired model instead.
- `Harmonize change_preset <preset>` — merge a preset defined at setup into
  the current config.
- `Harmonize virtualtext enable|disable|toggle` — control automatic ghost-text
  completion in the current buffer.

## API

### Actions

Bind the editor actions through the `keymap` table at setup:

```lua
{
    keymap = {
        accept = '<Tab>', -- accept one chunk
        accept_line = '<S-Tab>', -- accept the visible line
        dismiss = '<C-e>', -- dismiss the ghost text
        trigger = '<M-y>', -- manually request a completion
        toggle = '<M-t>', -- toggle auto-completion
    },
}
```

### Events

Harmonize fires `User` events before/after each completion request; statusline
integrations can subscribe to them:

- **HarmonizeRequestStartedPre** — before a request is initiated.
- **HarmonizeRequestStarted** — after a request is dispatched.
- **HarmonizeRequestFinished** — when the request completes.

Each event carries a `data` field with `provider`, `name`, `model`,
`n_requests`, `request_idx` (optional), and `timestamp`.

## FAQ

### Integration with lazyvim

Harmonize's virtual text needs no integration with lazyvim's completion setup:
add the plugin, call `require('harmonize').setup { ... }`, and the ghost text
works alongside lazyvim as-is.

### RAG (experimental)

You can enrich the context sent to the LLM with RAG via the
[VectorCode](https://github.com/Davidyz/VectorCode) package — see
[recipes.md](./recipes.md) for chat (Gemini) and FIM (Qwen-2.5-Coder)
examples.

## Troubleshooting

Most failures come from two things:

1. A misconfigured API key — see [API keys](#api-keys).
2. A model or context window too slow for the request to finish — start with a
   small context window (e.g. `context_window = 768`), a smaller model, and a
   longer `request_timeout` (e.g. 5), then raise them as you measure inference
   speed.

Set `config.notify = "debug"` to diagnose.

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## Acknowledgement

- [continue.dev](https://www.continue.dev): not a neovim plugin, but a great source of LLM models.
- [copilot.lua](https://github.com/zbirenbaum/copilot.lua): reference for the virtual text frontend.
- [llama.vim](https://github.com/ggml-org/llama.vim): reference for CLI parameters used to launch the llama-cpp server.
