# socle.nvim

A Neovim plugin for [Socle](https://github.com/socless/socle), the Chisel IDE
language server. In a Chisel project built with Mill, it adds a **View design**
and a **Simulate** code lens above every ChiselSim test:

- **View design** elaborates that test's design and shows it in a live panel in
  your browser. Saving a `.scala` file refreshes the panel, the panel follows
  your cursor, and a click on a box in the panel jumps to its source.
- **Simulate** runs the test with waveforms on and shows the trace in Surfer,
  following the panel's selection.

The plugin downloads the Socle server release it is tested against, checks
its sha256, and starts it next to Metals. Your tests and build are never
modified. The server itself is described in Socle's
[Neovim guide](https://github.com/socless/socle/blob/main/docs/ide-neovim.md).

## Private repository

Both repositories (socless/socle and socless/socle.nvim) are private for now:

- **Installing the plugin** needs git access to socless/socle.nvim: an SSH key
  or git credentials for GitHub. Use the `git@github.com:` URL shown with each
  snippet below.
- **The server jar download** fails anonymously (curl gets a 404). The plugin
  then tries `gh release download`, which works with a logged-in
  [gh](https://cli.github.com/) (`gh auth login`) that can read socless/socle.
  Otherwise, set `server_jar` to a jar you got some other way.

`:checkhealth socle` reports whether gh is installed and logged in.

## Requirements

- Neovim 0.12 or later.
- Java 21 or later: the `java` option, else `$JAVA_HOME/bin/java`, else `java`
  on `PATH`.
- A Mill project, with a `build.mill` at its root and `./mill` there (or
  `mill` on `PATH`). The client does not start for a Scala file outside a Mill
  project (sbt, a lone file).
- To download the server: curl, and `sha256sum` or `shasum` (macOS). While the
  repository is private, a logged-in `gh` too (see above).
- For Simulate only: Verilator on `PATH`, and the
  [Surfer](https://surfer-project.org/) app unless `wave_viewer` is
  `"surfer-panel"`.
- Linux and macOS. Windows is not tested, and the download needs `sha256sum`
  or `shasum` there too: without them, set `server_jar`.

## Install

Every snippet calls `require("socle").setup()`: nothing happens before it.
The server starts with the first Scala buffer of a Mill project. The first
start downloads the jar, so it takes a few seconds once ("Socle: downloading
server ...", then "Socle: server ... ready").

### lazy.nvim and LazyVim

```lua
{
  "socless/socle.nvim",
  -- while the repository is private:
  -- url = "git@github.com:socless/socle.nvim.git",
  ft = "scala",
  cmd = "Socle",
  -- the options and the settings, flat (see Options)
  opts = { wave_viewer = "surfer-panel" },
  keys = {
    { "<leader>cV", "<cmd>Socle view<cr>", ft = "scala", desc = "Socle: view design" },
    { "<leader>cX", "<cmd>Socle simulate<cr>", ft = "scala", desc = "Socle: simulate" },
    { "<leader>cP", "<cmd>Socle panel<cr>", ft = "scala", desc = "Socle: open the panel" },
  },
}
```

With `opts`, lazy.nvim calls `require("socle").setup(opts)` for you. In
LazyVim, put the spec in a file under `lua/plugins/`. Pick keys that are free
in your config.

### vim.pack (Neovim 0.12)

```lua
vim.pack.add({ "https://github.com/socless/socle.nvim" })
-- while the repository is private:
-- vim.pack.add({ "git@github.com:socless/socle.nvim.git" })
require("socle").setup()
```

### mini.deps

```lua
MiniDeps.add({ source = "socless/socle.nvim" })
-- while the repository is private:
-- MiniDeps.add({ source = "git@github.com:socless/socle.nvim.git" })
require("socle").setup()
```

### packer.nvim

packer.nvim is unmaintained, but this still works:

```lua
use({
  "socless/socle.nvim",
  -- while the repository is private: "git@github.com:socless/socle.nvim.git"
  config = function() require("socle").setup() end,
})
```

### vim-plug

```vim
call plug#begin()
Plug 'socless/socle.nvim'
" while the repository is private:
" Plug 'git@github.com:socless/socle.nvim.git'
call plug#end()

lua require("socle").setup()
```

## Options

The defaults:

```lua
require("socle").setup({
  version = "0.23.0",   -- the server release to download (the pin, see below)
  server_jar = nil,     -- a local jar: overrides version and the download
  java = nil,           -- nil: $JAVA_HOME/bin/java, else "java"
  codelens = true,      -- show the View design and Simulate lenses
  follow_cursor = true, -- the panel lights the class under the cursor (on CursorHold)
  open_panel = nil,     -- nil: vim.ui.open(url); a list: a command, the url appended;
                        -- or a function(url)
  notify_status = true, -- "design ready" and "simulating" notifications
  settings = {},        -- sent to the server, see below
})
```

The settings below are the server's Simulate, waveform and schematic settings. They go
directly in the options (flat, as in `wave_viewer = "surfer-panel"`), or under
`settings`; when a key is in both places, the one under `settings` wins. A
setting left out is not sent, so the server keeps its own default (shown
here). An unknown option or setting gets a warning and is ignored.

| Setting | Server default | Meaning |
|---------|----------------|---------|
| `wave_flag` | `"emitVcd"` | ChiselSim option that turns waves on for Simulate, passed as `-D<flag>=1`. |
| `surfer_command` | `"surfer"` | The Surfer app's executable. |
| `wave_viewer` | `"surfer"` | `"surfer"` (the app), `"surfer-panel"` (Surfer in the browser panel) or `"custom"`. |
| `wave_viewer_command` | empty | Command for `"custom"`, split on whitespace; `{file}` is the trace path, e.g. `"gtkwave {file}"`. Empty: `<surfer_command> <trace>`. |
| `waves_follow_selection` | `true` | Surfer viewers only: the selected module decides which signals Surfer shows. |
| `waves_show_clock_reset` | `false` | Surfer viewers only: clock and reset lead the list. |
| `waves_fold_bundles` | `false` | `"surfer-panel"` only: bundle sub-groups start folded. |
| `waves_show_wires` | `true` | Surfer viewers only: include the Wires group. |
| `waves_color_by_direction` | `true` | Surfer viewers only: inputs blue, outputs green. |
| `waves_follow_delay_ms` | `150` | Surfer viewers only: delay before Surfer follows a selection change. |
| `schematic_colorize_components` | `false` | The panel colours the boxes by kind. |
| `schematic_colorize_wires` | `false` | The panel colours the wires by bundle type. |
| `schematic_density` | `"comfortable"` | `"compact"`, `"comfortable"` or `"comfy"` panel chrome. |
| `schematic_label_size` | `"normal"` | `"normal"`, `"large"` or `"xl"` port labels and box names. |
| `schematic_auto_optimize` | `true` | Lay every view out with the optimize pass. |
| `schematic_hint_bar` | `true` | The hint bar under the schematic. |
| `schematic_show_layers` | `false` | Draw verification layers. |
| `schematic_hide` | `{}` | Node kinds to leave out: `"op"`, `"reg"`, `"const"`, `"mem"`, `"fsm"`, `"block"`. |

`wave_flag` and `surfer_command` need server 0.16.0 or later, the other wave
settings 0.17.0, the `schematic_*` settings 0.18.0. With an older `version`,
`setup` warns once per such setting.

The `schematic_*` settings are the panel's defaults: it applies them when it
opens and when one changes, and its settings popover changes the view until
then. `follow_cursor = false` also stops the panel lighting the class under
the cursor (its **focus** chip's × stops it until the cursor moves to
another class).

Example:

```lua
require("socle").setup({
  open_panel = { "firefox", "--new-window" },
  wave_flag = "emitFst",
  wave_viewer = "surfer-panel",
})
```

Calling `setup` again with new options applies them by restarting the server
("Socle: restarted with the new options"): the open Scala buffers attach to
the new one.

## Commands

`:Socle {subcommand}`, with completion:

| Command | What it does |
|---------|--------------|
| `:Socle view` | Runs the View design lens of the test at or above the cursor (else the first one in the file). |
| `:Socle simulate` | The same with the Simulate lens. |
| `:Socle panel` | Opens the last view's panel again. |
| `:Socle update` | Downloads the jar again and restarts the server on it (or starts one). The jar on disk is only replaced once the new one verified, so a failed update keeps it. |
| `:Socle log` | Opens the LSP log (`vim.lsp.log.get_filename()`), which holds the server's stderr, in a new tab. |
| `:Socle health` | Runs `:checkhealth socle`. |

The lenses also run with Neovim's own `grx` mapping or
`vim.lsp.codelens.run()`. The browser opens once per panel URL: a later view
updates the open tab, and `:Socle panel` opens it again.

## Health

`:checkhealth socle` (or `:Socle health`) checks:

- Neovim 0.12 or later, and that `setup()` was called;
- the java the server runs with, and that it is Java 21 or later (an ERROR
  otherwise);
- the jar: the pinned one, hashed again and compared with `PINNED_SHA256` (an
  ERROR when it differs), a `version` you set (checked against `SHA256SUMS`
  when it was downloaded), or `server_jar` (an ERROR when it is missing);
- the download tools: curl, `sha256sum` or `shasum`, and whether gh is
  installed and logged in (`gh auth status`). These only WARN when the jar
  still has to be downloaded;
- `./mill` (or `mill` on `PATH`) at the root of the open Scala buffers' Mill
  project, else of the working directory;
- for Simulate: `verilator`, and `surfer_command` when `wave_viewer` is
  `"surfer"` (or `"custom"` with no command).

## With Metals

socle.nvim runs next to Metals or nvim-metals: both clients attach to the
same Scala buffers. The Socle server offers only its lenses, its commands,
save handling and cursor following: no diagnostics, completion, hover or
definition. The plugin enables code lenses for the `socle` client only, so
Metals' lenses stay as Metals configures them.

## The server version

Each plugin release pins the server release it is tested against
(`require("socle.versions").PINNED`, now 0.23.0). The jar goes to
`stdpath("data")/socle/socle-lsp-<version>.jar` and is downloaded once,
from `https://github.com/socless/socle/releases/download/v<version>/`. The
pin includes the jar's sha256 (`require("socle.versions").PINNED_SHA256`):
the pinned jar must match it, so a release asset replaced after the plugin
release is refused. The release's `SHA256SUMS` is only used for a `version`
you set. A download that fails, or whose checksum does not match, leaves
nothing behind. It is not retried for each new Scala buffer, only on the next
`setup` or `:Socle update`. Updating the plugin moves the pin, and the new
jar is downloaded on the next start.

To override the pin:

- `version = "0.16.0"` downloads and runs that release instead, checked
  against its `SHA256SUMS`. Settings it does not know get a warning.
- `server_jar = "~/socle/out/socle-lsp/assembly.dest/out.jar"` runs a
  local jar, such as one built from Socle with `./mill socle-lsp.assembly`.
  Nothing is downloaded, and no version check applies.

`:Socle update` downloads the jar again.

To bump the pin (a plugin release):

1. Get the new release's checksums:
   `gh release download v<new> --repo socless/socle --pattern SHA256SUMS`.
2. In `lua/socle/versions.lua`, set `PINNED` to `<new>` and `PINNED_SHA256`
   to the `socle-lsp-<new>.jar` line's hash.
3. Update the version this README and `doc/socle.txt` name (the unit
   specs check them), and run the specs and the integration spec.

## Development

```sh
nvim --headless -u NONE -l tests/run.lua            # all the specs
nvim --headless -u NONE -l tests/run.lua health     # those whose path matches a Lua pattern
```

The unit specs need neither network nor Java. The specs under
`tests/integration/` run the real server on Socle's `example/` project. They
need two variables, and are skipped (not failed) without them:

- `SOCLE_ROOT`: a Socle checkout. View design runs `./mill` there and
  writes its `out/` directory, so use a scratch clone, not one you work in
  (`git clone --branch v0.23.0 ~/dev/socle /tmp/socle`);
- `SOCLE_JAR`: its server jar, `socle-lsp-<version>.jar`.

```sh
SOCLE_ROOT=/tmp/socle SOCLE_JAR=/path/to/socle-lsp-0.23.0.jar \
  nvim --headless -u NONE -l tests/run.lua integration
```

CI (`.github/workflows/ci.yml`) has two jobs:

- **unit** runs the specs on every push to main and every pull request, on
  Neovim 0.12.6.
- **integration** runs only when started by hand (Actions, "Run workflow"),
  because socless/socle is private. It checks out Socle at the pinned
  version (read from `versions.PINNED`), downloads
  and checks its release jar, and runs `tests/integration` (Java 21, no
  Verilator: View design does not simulate). It needs a repository secret,
  `SOCLE_TOKEN`: a fine-grained personal access token with read access to
  the contents of socless/socle (Settings, Secrets and variables, Actions).

## License

Copyright (C) 2026 Iban Guinebert. Licensed under the GNU AGPL-3.0-only, like Socle: see
[LICENSE](LICENSE) and Socle's [LICENSING.md](https://github.com/socless/socle/blob/main/LICENSING.md),
which also covers the commercial licence. Contributions are accepted under Socle's
[Contributor License Agreement](https://github.com/socless/socle/blob/main/CLA.md).
