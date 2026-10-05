# inlineview.nvim

View images and PDFs **inside Neovim**, as actual pixels.

```
nvim diagram.png      # just shows the picture
nvim report.pdf       # paged, zoomable, pannable
```

In markdown, `![alt](path)` links render beneath the link.

Part of [ismael-su/kickstart.nvim](https://github.com/ismael-su/kickstart.nvim),
living in `local/inlineview.nvim/`. It has no plugin dependencies.

## Why another one

Most image plugins target the Kitty graphics protocol and treat iTerm2 as an
afterthought, or shell out to ImageMagick for everything. This one:

- Speaks **iTerm2's OSC 1337 protocol natively**, and detects iTerm2 **through
  SSH** via `LC_TERMINAL`.
- Needs **no external tools to display an image**. Dimensions are parsed from
  file headers in pure Lua (PNG, JPEG, GIF, BMP, WebP, TIFF, AVIF, ICO), and
  iTerm2 decodes the bytes itself.
- **Zooms PDFs properly**: the page is re-rasterized at a higher dpi and
  cropped to what's visible, so small text gets *sharper*, not bigger.
- Falls back to Unicode half-blocks so it still does something useful in a
  plain terminal.

## Backends

| Backend  | Terminals                        | Quality         |
| -------- | -------------------------------- | --------------- |
| `iterm2` | iTerm2 (incl. over SSH)          | true pixels     |
| `kitty`  | Kitty, Ghostty, WezTerm          | true pixels     |
| `blocks` | anything truecolor (needs chafa) | half-block art  |

Chosen automatically; override with `backend = '...'`.

## Requirements

- Neovim 0.10+
- **PDFs:** `poppler-utils` (`pdftoppm`, `pdfinfo`)
- **Fallback backend:** `chafa`
- **Correct aspect ratio:** `python3`, to probe the terminal's pixel-per-cell
  size. Without it, the configured `cell` values are used.

```sh
sudo apt install poppler-utils chafa     # Debian/Ubuntu
brew install poppler chafa               # macOS
```

`:checkhealth inlineview` reports what was found.

## Usage

| Command              | Does                                            |
| -------------------- | ----------------------------------------------- |
| `:InlineView [path]` | open in a floating viewer                       |
| `:InlineViewInline`  | toggle in-buffer rendering of links             |
| `:InlineViewRefresh` | re-probe the terminal and repaint               |
| `:InlineViewClear`   | erase every drawn image                         |
| `:InlineViewInfo`    | report the detected backend and cell size       |

Inside a viewer:

| Key          | Does                        |
| ------------ | --------------------------- |
| `q` `<Esc>`  | close                       |
| `n` `p`      | next / previous page (PDF)  |
| `gg` `G`     | first / last page (PDF)     |
| `12%`        | jump to page 12 (PDF)       |
| `+` `-` `0`  | zoom in / out / reset       |
| `h j k l`    | pan when zoomed (PDF)       |
| `w` `f`      | fit width / fit window      |
| `<C-l>`      | force repaint               |
| `?`          | help                        |

Plus `<leader>iv`, `<leader>ii`, `<leader>ir` from the config spec.

## Configuration

See `:help inlineview-configuration` for the full set. The common ones:

```lua
require('inlineview').setup {
  backend = 'auto',
  fit = 'contain',
  auto_open = true,

  -- Only needed if the probe fails and images look stretched.
  cell = { width = 7, height = 15 },

  pdf = { max_dpi = 400, prefetch = 1 },

  inline = {
    enabled = true,
    filetypes = { 'markdown', 'quarto', 'rmd' },
    max_rows = 20,
  },
}
```

## Tests

```sh
cd local/inlineview.nvim

nvim -l tests/run.lua              # 147 unit + integration assertions
nvim -l tests/run.lua geometry     # filter by spec name
python3 tests/smoke.py             # end-to-end, drives Neovim in a real pty
```

The Lua suite covers the scaling arithmetic, every image header parser, the
poppler integration, the exact protocol bytes each backend emits, and the
viewer state machine. The smoke test launches real Neovim instances in a pty
and asserts that image escape sequences genuinely reach the terminal — that
`BufReadCmd` fired, the tty writer resolved, and nothing was clobbered.

Fixtures are generated, not committed blobs:

```sh
python3 tests/fixtures/gen.py
```

## Caveats

Neovim has no concept of images. These are escape sequences written over cells
Neovim thinks are blank, which has consequences:

- An image is erased when Neovim repaints those cells. The plugin repaints on
  scroll, resize, tab switch and after the command line closes. `<C-l>` fixes
  anything that slips through.
- Images are never drawn into the last screen row, because that would scroll
  the terminal and desynchronise Neovim's view.
- Under tmux you need `set -g allow-passthrough on`.
- Zoom beyond "fits the window" only crops for PDFs. Image panning would need
  an external cropper and isn't implemented.
- Remote URLs in markdown links are skipped; nothing is downloaded.
