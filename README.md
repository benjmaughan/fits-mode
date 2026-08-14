# fits-mode

An Emacs major mode for browsing [FITS](https://fits.gsfc.nasa.gov/) files — without loading the binary payload into a buffer.

`fits-mode` provides a set of read-only, tabulated views for inspecting FITS HDUs, headers, table columns, and table/image data, all from within Emacs. It uses a small Python/[astropy](https://www.astropy.org/) helper script as the parsing back-end and communicates over JSON, so the Emacs side stays pure Elisp with no binary I/O.

---

## Requirements

| Dependency | Notes |
|---|---|
| Emacs | 29.1 or later recommended (uses `header-line-indent-mode`) |
| Python 3 | `python3` on `PATH`, or set `fits-mode-python-executable` |
| astropy | `pip install astropy` |

---

## Installation

1. **Clone or copy** both `fits-mode.el` and `fits-helper.py` into the same directory on your `load-path`, for example `~/.emacs.d/lisp/fits-mode/`.

2. **Install the Python dependency:**

   ```sh
   pip install astropy
   ```

3. **Load the package** in your Emacs configuration:

   ```elisp
   ;; Minimal
   (add-to-list 'load-path "~/.emacs.d/lisp/fits-mode")
   (require 'fits-mode)
   ```

   Or with `use-package`:

   ```elisp
   (use-package fits-mode
     :load-path "~/.emacs.d/lisp/fits-mode")
   ```

4. **That's it.** Opening any `.fits`, `.fit`, `.fits.gz`, or `.fits.fz` file with `find-file` will launch `fits-mode` automatically. The raw binary payload is never loaded into the buffer — only the rendered view.

---

## Opening a FITS file

```
M-x find-file RET my-data.fits RET
```

or

```
M-x fits-open-file RET my-data.fits RET
```

Either command opens the **HDU list** view.

---

## Views

### HDU list (`fits-hdu-list-mode`)

The entry point. Shows one row per Header/Data Unit with its index, name, type, dimensions, and a short summary.

```
  FITS: /data/observation.fits

  #  Name          Type       Dims              Info
  ─────────────────────────────────────────────────────────────────
  0  PRIMARY       IMAGE      [2048 × 2048]     BITPIX=-32
  1  SCI           IMAGE      [2048 × 2048]     EXTVER=1
  2  EVENTS        BIN_TABLE  1024 rows × 8 cols TFIELDS=8
  3  GTI           BIN_TABLE  12 rows × 2 cols  TFIELDS=2
```

**Key bindings:**

| Key | Action |
|-----|--------|
| `RET` | Open header / columns / data (prompts if multiple apply) |
| `h` | Open header view for current HDU |
| `c` | Open columns view (table HDUs only) |
| `d` | Open data view |
| `g` | Refresh HDU list |
| `q` | Quit window |

---

### Header view (`fits-header-mode`)

Shows all FITS header cards for the selected HDU as a two-column table (keyword / value). Long string values are not truncated.

```
  Header: EVENTS (HDU 2)  —  /data/observation.fits

  Keyword        Value
  ─────────────────────────────────────────────────
  XTENSION       BINTABLE
  BITPIX         8
  NAXIS          2
  NAXIS1         64
  NAXIS2         1024
  TFIELDS        8
  TTYPE1         TIME
  TFORM1         D
  TTYPE2         RA
  TFORM2         E
  …
```

**Key bindings:**

| Key | Action |
|-----|--------|
| `q` | Back to HDU list |
| `g` | Refresh |

---

### Columns view (`fits-columns-mode`)

Available for table HDUs. Shows each column's index, TTYPE (name), TFORM (FITS format code), TUNIT (unit), and a short description where present.

```
  Columns: EVENTS (HDU 2)  —  /data/observation.fits

  #   Name     Format   Unit       Description
  ─────────────────────────────────────────────────
  1   TIME     D        s
  2   RA       E        deg
  3   DEC      E        deg
  4   ENERGY   E        keV
  5   GRADE    I
  6   DETX     I        pixel
  7   DETY     I        pixel
  8   STATUS   B
```

**Key bindings:**

| Key | Action |
|-----|--------|
| `q` | Back to HDU list |
| `g` | Refresh |

---

### Data view (`fits-data-mode`)

#### Table HDUs

Displays paginated table rows with dynamically-sized, right-aligned numeric columns. Numbers are rounded to `fits-mode-data-sig-figs` significant figures (default: 4). Column headers stay visible and scroll horizontally with the data.

```
  Data: EVENTS (HDU 2)  —  rows 1–200 of 1024  —  /data/observation.fits

  TIME        RA       DEC      ENERGY   GRADE   DETX   DETY   STATUS
  ───────────────────────────────────────────────────────────────────
  1.234e+08   83.82    -5.391   2.341       0    512    511       0
  1.234e+08   83.75    -5.402   0.9127      1    498    523       0
  1.234e+08   83.91    -5.378   7.654       0    530    504       0
  …
```

#### Image HDUs

Displays a downsampled ASCII preview grid (default: 40 columns × 24 rows) with pixel statistics in the mode line.

```
  Data: PRIMARY (HDU 0)  —  IMAGE [2048 × 2048]  —  min=0.00 max=6.543e+04 mean=812.3 std=2341

  ░░░░░░░▒▒▒▒▒▒▒░░▒▒▒▒▒▒▒▒▓▓▓▓▓▓▓▓▓███████▒▒
  ░░░░░░░▒▒▒▒▒▒▒░░▒▒▒▒▒▒▒▒▓▓▓▓▓▓▓▓▓███████▒▒
  ░▒▒▒▒▒▒▒▒▒░░░░░░░░░░▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒
  …
```

**Key bindings:**

| Key | Action |
|-----|--------|
| `n` | Next page of rows |
| `p` | Previous page of rows |
| `j` | Jump to row offset (prompts for number) |
| `q` | Back to HDU list |
| `g` | Refresh / reload current page |

---

## Configuration

All variables belong to the `fits-mode` customization group (`M-x customize-group RET fits-mode`).

| Variable | Default | Description |
|---|---|---|
| `fits-mode-python-executable` | `"python3"` | Python interpreter used to run the helper. Set this to a full path or virtualenv python if needed. |
| `fits-mode-data-page-size` | `200` | Number of table rows loaded per page. |
| `fits-mode-data-sig-figs` | `4` | Significant figures for floating-point cells in data views. Header card values are always shown at full precision. |
| `fits-mode-data-max-column-width` | `40` | Maximum character width of a data column. Columns are otherwise sized to fit their content on the current page. |
| `fits-mode-image-grid-size` | `(40 . 24)` | Dimensions `(columns . rows)` of the downsampled preview grid for image HDUs. |
| `fits-mode-file-regexp` | `\\.\\(fits\|fit\\)\\(\\.\\(fz\|gz\\)\\)?\\'` | Regexp controlling which file names trigger auto-mode and the file handler. |
| `fits-mode-columns-name-width` | `24` | Maximum display width for column names in `fits-columns-mode`. Increase this if your FITS table column names are longer than the default. |

Example customization:

```elisp
(use-package fits-mode
  :load-path "~/.emacs.d/lisp/fits-mode"
  :custom
  (fits-mode-python-executable "/home/user/.venvs/astro/bin/python")
  (fits-mode-data-page-size 500)
  (fits-mode-data-sig-figs 6)
  (fits-mode-image-grid-size '(60 . 30))
  (fits-mode-columns-name-width 32))
```

---

## How it works

`fits-mode` is split into two parts:

- **`fits-mode.el`** — the Emacs Lisp front-end. It registers a `file-name-handler-alist` entry (the same mechanism used by `jka-compr` for transparent decompression) so that `find-file` on a FITS file intercepts `insert-file-contents`, prevents the binary payload from ever entering the buffer, and routes the buffer to `fits-hdu-list-mode`. All interactive views are built on `tabulated-list-mode`.

- **`fits-helper.py`** — a small Python script that accepts a subcommand (`info`, `header`, `columns`, `data`) plus file path and parameters on the command line, and emits a JSON response. `fits-mode.el` calls this script synchronously via `call-process` and parses the result.

Both files must live in the **same directory**; the Elisp locates the helper script relative to its own file path at load time.

---

## Troubleshooting

**`fits-mode: Python helper failed` or `ModuleNotFoundError: astropy`**
Astropy is not installed for the Python executable `fits-mode` is using. Run:
```sh
pip install astropy
```
or set `fits-mode-python-executable` to point to a Python that has astropy:
```elisp
(setq fits-mode-python-executable "/path/to/venv/bin/python")
```

**File opens as raw binary / garbled text**
The `file-name-handler-alist` entry may not be active. Check that the file name matches `fits-mode-file-regexp` and that `(require 'fits-mode)` ran without error.

**Line wrapping in data view**
`fits-data-mode` sets `truncate-lines`, `word-wrap`, and `visual-line-mode` buffer-locally and guards against global hooks re-enabling wrapping. If wrapping persists, check for a global mode that forces `visual-line-mode` on unknown buffer types.

**Column header misaligned with data**
The header line is rendered with an `:eval` form that reads `window-hscroll` on every redisplay. If it still looks off, try `g` to refresh the buffer, which rebuilds the column format from the current page's content.
