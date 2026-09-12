# Version 0.11.0 (unreleased)

## Features

- Virtual Text: The new `display` option picks what the ghost text shows.
  The default `'below'` mode overlays same-line continuations beneath the cursor
  without moving buffer lines. Newline-leading continuations use an in-place
  virtual line so they appear where accepting them will put them and shift
  following screen text down. A `↵` at the cursor indicates that the next
  accepted chunk starts with a newline. `'line'` overlays the current line, and
  `'chunk'` shows exactly what the `accept` keymap completes. Below-line floats
  remain fixed at the cursor when clipped instead of shifting left.
- Virtual Text: `accept` is now the accept action, taking the completion one
  chunk at a time. Spaces and tabs terminate a chunk after the whitespace run,
  so `data_ == other` is accepted as `data_ `, `== `, and `other`. A leading
  newline is its own chunk with its indentation. Characters listed in
  `chunk_options.allow_post_newline_chars`, such as `.`, may be included after
  that indentation.
- Virtual Text: A `toggle` keymap switches automatic completion on and off
  for the current buffer.
- The next chunk accepted by Tab uses the theme's `Special` color by default,
  while the rest of the suggestion keeps the normal ghost-text color. The
  `display_options.below.next_chunk_highlight` and
  `display_options.line.next_chunk_highlight` settings accept a highlight group
  name or a direct `#RRGGBB` color. Below previews use the `Pmenu` background by
  default so they remain distinct from the code underneath. The
  `display_options.below.background_highlight` setting accepts the same forms.
  Chunk display needs no extra styling.
- Strict existing-text matching can reuse a predicted closing suffix or an
  exact predicted next line instead of inserting a duplicate. Below mode shifts
  the existing suffix to show its predicted position. Set
  `match_existing_text = false` for insert-only behavior.
- Below previews redraw after scrolling, acceptance keeps the old preview until
  its cached tail is ready, and newline-only suggestions no longer add an empty
  virtual line.
- Cached completions extend in the background when fewer than two complete
  newline-terminated lines remain. Extension requests capture context at the
  predicted endpoint after applying strict existing-text matching, and streamed
  extension text is appended without replacing the stable tail. Configure the
  threshold or disable this through `extension_options`.
- Harmonize remains active while another completion menu is visible by
  default. The menu draws above its preview, and
  `show_with_completion_menu = false` restores suppression.
- Providers other than `llama_cpp` and `openai_fim_compatible` are
  untested; using one shows a warning on setup unless
  `allow_unsupported_providers = true`.
- The llama_cpp provider sends extra context in the request's `input_extra`
  field. Three background sources feed it, configured with `context_sources`:
  treesitter captures the file's imports and the headers of the declarations
  enclosing the cursor, recent edits keeps the last few edited regions across
  the project, and the jumplist source keeps snippets around recently visited
  locations. Every source caches its result, so building a request adds no
  parsing or file reads, and chunks that repeat the cursor context are
  dropped. The sources start only when a provider is configured.

## Renamed

- The plugin is now called harmonize.nvim: the module is
  `require('harmonize')`, the user command is `:Harmonize`, and the
  `HarmonizeVirtualText` highlight group and `HarmonizeRequest*` events use
  the new prefix. The repository is renamed to `Quinntyx/harmonize.nvim`
  and `v2` is merged into `main`.
- The virtual text options moved to the top level of the config:
  `virtualtext.trigger_on_typing` became `completion_trigger` (`'on_type'` or
  `'on_insert'`), `virtualtext.display_singleline` became `display`
  (`'below'`, `'line'`, or `'chunk'`), and the remaining virtual text options
  lost their prefix.
- `chunk_fade` was replaced by mode-specific `display_options`. The `below` and
  `line` modes can accent only the next accepted chunk; `chunk` needs no
  boundary setting because it does not show the remaining completion.
- The `quick_start` option became the `llama_cpp` provider plus the
  `auto_start` namespace. The provider talks to llama.cpp's native
  `/infill` endpoint, where the server constructs the FIM prompt with the
  model's own tokens, so the per-model template hack is gone.
  `auto_start` (nil by default, so a blank config never downloads a model
  or loads it into VRAM) starts a llama.cpp server when none is running at
  its host and port; a partial table merges over `default_auto_start`, and
  the full table takes the base command, the model, `extra_args` in the
  style of `curl_extra_args`, and `kill_on_exit`.
- Suggestion choice cycling was removed along with the `next`/`prev` actions
  and keymaps; the first completion suggestion is used. The manual invoke
  that shared the `next` key moved to a dedicated `trigger` action, bindable
  through `keymap.trigger`.
- Accepting the whole completion and `accept_n_lines` are gone: `accept` now
  takes one chunk, and accepting a chunk counts as taking it from the stream,
  so the next chunk follows and repeated accepts never re-insert text.
- The `show_on_completion_menu` option was replaced by
  `show_with_completion_menu`, which defaults to showing both completions.

## Defaults

- Installing changes nothing by default: no keys are bound, no ghost text
  is shown, and no provider is configured. Other defaults (below-line
  display, typing-only trigger, throttle and debounce) still apply. The
  README's install snippet turns everything on: the `llama_cpp` provider,
  Tab bound to accept chunks, ghost text in every filetype, and an
  auto-started llama.cpp server.

## Streaming

- Streamed completions are rendered token by token as they arrive, so a
  longer `max_tokens` no longer means a longer wait for the first chunk.
  The completion is a character stream: the model keeps appending to the
  back up to the `max_tokens` cap while Tab or typing takes from the front,
  and the remaining text is re-rendered on every token within the one-line
  viewport rules.

## Removed

- The nvim-cmp and blink-cmp frontends are gone; virtual text is now the only
  completion frontend, alongside the built-in LSP sources. The `cmp` and
  `blink` config keys, `make_cmp_map`/`make_blink_map`, the `Minuet cmp` /
  `Minuet blink` commands, and `lsp.completion.warn_on_blink_or_cmp` were
  removed with them.
- The `n_completions` option is gone: virtual text can only show one
  completion at a time, so exactly one candidate is always generated.
- The duet (next-edit prediction) feature is gone, including its backends,
  preview, edits tracking, `Minuet duet` commands, and events.
- The in-process LSP server is gone: built-in and inline LSP completion, the
  `Minuet lsp` commands, the `lsp` config, and `add_single_line_entry` were
  removed. Virtual text is now the only completion frontend.
- The lualine statusline component and the unused deprecation-notice module
  are gone.

## Fixes

- Changing the model with `change_model` no longer changes the configuration
  defaults for the rest of the session: the next `setup()` still starts from
  the documented defaults.
- The ghost-text keymap descriptions now read `[harmonize]` instead of
  `[harmonize.virtualtext]`.
- An unknown `notify` level warns and falls back to `'warn'` instead of
  failing the next time a message is logged.
- Relative `.gguf` paths such as `models/qwen.gguf` are passed to llama.cpp as
  local files instead of being mistaken for Hugging Face repository IDs.
- `change_model` now reports that it cannot restart a llama.cpp server instead
  of claiming that its model changed.
- A context source that fails is logged at the debug level instead of failing
  silently, and a failing teardown step no longer stops the other resources
  from being released.

# Version 0.10.0 (2026-07-31)

## Features

- Duet can now use recent edits to provide more relevant next-edit predictions.
- Inline completion with the OpenAI-compatible provider now uses prefix-first
  prompts by default.
- Updated the default models for OpenAI-compatible completions and Duet.

## Improvements

- Improved support for custom request configurations and AWS
  Bedrock-compatible services.

## Fixes

- Improved whitespace handling for FIM completions.

# Version 0.9.0 (2026-04-26)

## Breaking Changes

- LSP configuration restructure: The LSP configuration has been reorganized into
  separate `completion` and `inline_completion` sections:

## Features

- Duet (Next Edit Prediction): Introduced a new experimental feature for
  next-edit prediction. Duet analyzes the context around the cursor and suggests
  edits within an editable region. This feature is still highly experimental and
  remains a WIP.
- LSP inline completion: Added support for Neovim's built-in
  `vim.lsp.inline_completion` interface (Neovim 0.12+). Enable via
  `config.lsp.inline_completion.enable`.
- New configuration options:
  - `config.curl_cmd`: Customize the curl command used for HTTP requests.
  - `config.curl_extra_args`: Pass additional arguments to curl.
- Provider updates:
  - Change default `openai_fim_compatible` model from `deepseek-chat` to
    `deepseek-v4-flash`.
  - Change OpenAI default model to `gpt-5.4-nano` with prefix-first prompt
    strategy.
- Similar to the `openai_fim_compatible` provider, the `openai`, `claude`,
  `openai_compatible`, and `gemini` providers now support customizing the
  endpoint, headers, and request body via the `transform` option.
- Remove dependency on `plenary.nvim`. Minuet now uses the built-in
  `vim.system` API for HTTP requests.

# Version 0.8.0 (2025-12-13)

## Breaking Change

- Rename `config.enabled` to `config.enable_predicates`

## Features

- Virtual Text:
  - Continuous Line-by-Line Acceptance: The `accept_line` command now preserves
    partial accepted suggestion state. This allows users to accept multi-line
    suggestions incrementally by invoking the command repeatedly.
  - Preserved Suggestions During Multi-line Typing: Prefix-matched suggestions
    persist even while the user is typing multi-line text, to avoid unnecessary
    LLM requests and conserving resources.

# Version 0.7.0 (2025-12-09)

## Features

- defaults: set default `before_cursor_filter_length` to 2.
- claude: change default model to claude-haiku-4.5
- claude: change default `max_tokens` to 256
- add option `enabled` for dynamic enable at runtime
- virtualtext: preserve completion items when user input matches existing completion items (#90)

# Version 0.6.0 (2025-08-11)

## Breaking Change

- Improve completion filtering with before/after context:
  - Refactors the completion filtering logic to be based on the longest common
    match.
  - Add a new `before-cursor-filter-length` config option to trim duplicated
    prefixes from completions based on the text before the cursor.
- Change default few-shot example: The default few-shot example has been
  updated to require the AI to combine information from before and after the
  cursor to generate the correct logic.
- Update default system prompt: The system prompt is refined to be more concise
  and provide clearer instructions to the AI on handling various completion
  scenarios like code, comments, and strings.

## Features

- Make endpoint configurable for Gemini and Claude: Users can now
  specify custom API endpoints for Gemini and Claude providers.

## Fixes

- Handle empty string for non-stream requests : Ensures that empty string
  responses from the API are handled correctly for non-streaming requests.

## Other

- Refactor Gemini requests : Updated Gemini requests to use the
  `x-goog-api-key` header to align with upstream changes.
- Use lower case string instead of numbers to send signals, as recommended by
  luv manual.

# Version 0.5.2 (2025-05-11)

## Features

- lsp: add option `adjust_indentation` for completion items.
- lualine: display provider and model name.
- chat input template can be a list of strings.

## Fixes

- Cursor Position: Put cursor at correct position when accepting single-line
  virtual text completion.

# Version 0.5.1 (2025-04-08)

## Features

- Added `transform` option for OpenAI-FIM-compatible providers.

  This feature enables support for non-OpenAI-FIM-compatible APIs with
  OpenAI-FIM-compatible provider, such as the DeepInfra FIM API. Example
  configurations are available in [recipes.md](./recipes.md).

# Version 0.5.0 (2025-03-28)

## Breaking Changes

- Modified the Gemini provider's default prompt strategy to use the new
  **Prefix First** structure.
- Other providers will continue to use their previous default prompt
  configurations.

## Features

- lsp: always `prepend_to_complete_word` without checking `TriggerCharacter`
- Add a new "Prefix-First" prompt structure for chat LLMs.

# Version 0.4.2 (2025-03-21)

## Breaking Change

- change multi-lines indicators to unicode character `⏎`.

## Features

- **lsp**: change multi lines indicators to unicode character `⏎`.
- Lualine integration: add spinner component.
- **lsp**: add detail field to show provider name.
- **Minuet Event**: add three user events during its request workflow.

## Fixes

- **lsp**: handle request where params.context is not provided (for mini.completion).

# Version 0.4.1 (2025-03-19)

## Breaking Change

- **lsp**: Don't explicitly disable auto trigger for filetypes not in `enabled_auto_trigger_ft`.

## Fixes

- **lsp**: Fix cursor column position when trying to get current line content.
- **lsp**: Early return on throttle.

# Version 0.4.0 (2025-03-18)

## Features

- Introduced in-process LSP support for built-in completion.
- For `blink-cmp`, the completion item's `kind_name` now reflects the LLM provider name.
- Improve error handling for both stream and non-stream JSON decoding, providing more informative messages.

# Version 0.3.3 (2025-02-18)

## Documentation

- Added recipes for llama.cpp
- Added recipes for integration with VectorCode

# Version 0.3.2 (2025-02-10)

- Add luarocks release

# Version 0.3.1 (2025-02-10)

## Features

- `Minuet change_model` now supports `vim.ui.select`

# Version 0.3 (2025-02-09)

## Breaking Changes

- Remove Hugging Face provider
- Remove deprecated commands (`MinuetToggle*`, `MinuetChange*`)

## Features

- Add option to show suggestion when completion menu is visible
- Support api_key as a function

# Version 0.2 (2025-02-05)

## Breaking Changes

- Update default gemini model to gemini-2.0-flash

## Features

- Add command `Minuet change_preset`
- Add option to show suggestion when completion menu is visible

## Documentation

- Add RAG experimental feature doc with vectorcode

# Version 0.1 (2025-02-02)

- Initial release
