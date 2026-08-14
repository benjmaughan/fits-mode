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

Example customization:

```elisp
(use-package fits-mode
  :load-path "~/.emacs.d/lisp/fits-mode"
  :custom
  (fits-mode-python-executable "/home/user/.venvs/astro/bin/python")
  (fits-mode-data-page-size 500)
  (fits-mode-data-sig-figs 6)
  (fits-mode-image-grid-size '(60 . 30)))
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

---

## License

Distributed under the same terms as GNU Emacs (GPL v3 or later). See the file headers for details.


I'll build this as a small package: an Elisp major-mode front end plus a Python/astropy helper script that does the actual FITS parsing (much saner than reimplementing the FITS spec in Elisp). Let me write and sanity-check both files.Emacs 29.3 installed — good, I can actually byte-compile and smoke-test this rather than just hand-checking parens.Now let me write the Python helper script first and test it against a real synthetic FITS file.All working correctly, including the error path. Now let's write the Elisp package.Now let's byte-compile it to catch any real syntax/reference errors:Clean compile, zero warnings. Now let's actually functionally test it in batch mode by driving the interactive functions programmatically against the synthetic FITS file.The HDU list renders correctly. Let's now verify the header/columns/data drill-down buffers, paging, and the auto-mode-alist / file-handler trick with `find-file`.Everything works: header cards, table columns, paginated table data with correct row counts, next-page, and jump-to-offset all behave correctly. Now let's test the image HDU data view and the `find-file` auto-mode-alist/file-handler path (the trickiest part).The image preview grid renders too, with stats in the header line. Now let's test the `find-file` path — the file-name-handler + auto-mode-alist trick, which is the most fragile part.Excellent — this is the critical result: a 43KB binary file produces only a 138-byte buffer with the rendered HDU table, correctly routed to `fits-hdu-list-mode` via plain `find-file`, with `buffer-file-name` intact for revert/reference. Let's check a couple more edge cases: read-only enforcement and the missing-dependency error path.All the edge cases check out: read-only enforcement, `revert-buffer`, and clean error propagation when the Python side isn't usable. The package works end-to-end. Let me clean up and produce the final deliverables.Two files, both actually built and exercised end-to-end (not just eyeballed):

**`fits-helper.py`** — a small astropy-backed script that does all real FITS parsing and emits JSON. Subcommands: `info` (HDU summary), `header`, `columns` (table HDUs), `data` (paginated table rows, or a downsampled preview grid + stats for image HDUs).

**`fits-mode.el`** — the Emacs side, byte-compiles cleanly with zero warnings. Key design points:

- **`fits-hdu-list-mode`** — top-level `tabulated-list-mode` view: `#`, Name, Type, Dims, Info per HDU.
- From there: `h` header, `c` columns (table HDUs only), `d` data, `RET` prompts among whichever apply. Each opens its own buffer (`fits-header-mode`, `fits-columns-mode`, `fits-data-mode`), all `tabulated-list-mode`-derived, `q` to go back, `g` to refresh.
- **Data view** pages real table rows (`n`/`p`/`j` to jump), and for image/array HDUs shows a downsampled grid plus min/max/mean/std in the header line — genuinely "data" doesn't scale to a table otherwise.
- The interesting bit: opening a `.fits` file with plain `find-file` does **not** read the binary payload into a buffer. I registered a `file-name-handler-alist` entry (the same mechanism `jka-compr` uses for transparent decompression) that short-circuits `insert-file-contents` for FITS files, so `find-file` still sets `buffer-file-name` and dispatches via `auto-mode-alist` normally, but the buffer only ever holds the rendered table. I tested this against a real 43KB FITS file — buffer ended up 138 bytes.
- `M-x fits-open-file` is the explicit entry point if you don't want the auto-mode magic.

Install: drop both files somewhere on your `load-path` (they must stay in the same directory — the `.el` locates the helper script relative to itself) and `(require 'fits-mode)`. Given your setup, something like:

```elisp
(use-package fits-mode
  :load-path "~/.emacs.d/lisp/fits-mode")
```

Requires `pip install astropy` on whatever `python3` Emacs finds (customizable via `fits-mode-python-executable` if you want a specific venv). If astropy's missing, you get a clear error message rather than a cryptic traceback.

One thing worth flagging: the `file-name-handler-alist` trick is
elegant but touches fairly deep Emacs machinery, so if you ever see
weirdness with FITS files specifically (not other files), that's the
first place to look — it's isolated to the `fits-mode--file-handler`
function at the bottom of the file, and you can just remove the two
`add-to-list` calls if you'd rather always go through `fits-open-file`
explicitly.


--- New prompt ---

This is great but can you improve the table viewer? At the moment it
shows a truncated view like the one below. I'd like it to be formatted
neatly in columns with numbers shown to 4 significant figures, and to
render nicely even for large tables. The lines shouldn't wrap. Instead
the view should scroll as I move to columns off the screen. Something
like the org-mode table view without line wrapping. I'd also like the
column names to show at the top and stay visible when I scroll to
lower rows in the table

--- response ---

Good — confirmed. `tabulated-list-mode` already sets `truncate-lines t` and syncs the header line horizontally (via `header-line-indent-mode`, Emacs 29+) — that part isn't broken. The real bugs are: (1) I overwrote the column-name header line with a plain status string, and (2) fixed 14-char columns truncate raw high-precision floats. Let me fix both, plus add 4-sig-fig formatting server-side.Now let's update the Python helper to add significant-figure formatting:Now test the Python side of this change directly:Clean 4-sig-fig strings. Now the Elisp side: fix the header-line bug and add dynamic column sizing / right-alignment.Now let's replace the `fits--data-load` implementation and mode body:Now let's byte-compile and re-run the full functional test suite.Clean. Now let's actually test the new column-sizing/formatting logic end-to-end.This is exactly right: right-aligned numeric columns sized to content (4 sig figs), left-aligned NAME column, and the status now lives in `mode-line-process` while the header line (column names) is intact. Let's confirm the header line itself renders the actual column names now, and check the image data view still works too.Header line correctly shows `ID RA DEC FLUX NAME` with proper `:align-to` alignment (this is what syncs with horizontal scroll), and the image data view now has its stats in `mode-line-process` with numeric grid columns right-aligned. Let's run a byte-compile-clean final check and re-test the whole suite once more before shipping.Everything checks out — clean compile, all views working, paging/jump math correct, revert-buffer fine, and the header/columns views are unaffected (their `mode-line-process` stays nil as expected since only `fits-data-mode` sets it). Updating the deliverables:Turns out the underlying problem wasn't wrapping — `tabulated-list-mode` already disables that — it was two things I'd gotten wrong:

1. **The header line was being clobbered.** I was overwriting `header-line-format` (which holds the column names, and — I confirmed by reading `tabulated-list.el`'s source — automatically stays pinned and scrolls in sync with the buffer horizontally via `header-line-indent-mode` on Emacs 29+) with a plain "Rows X-Y of Z" string. That status text now goes in `mode-line-process` instead, which shows next to the mode name in the mode line and is equally always-visible, leaving the header line free to do its job.

2. **Columns were a fixed 14 characters.** Now each page computes its own column widths from the actual content (header name vs. longest cell), caps at `fits-mode-data-max-column-width` (40 by default, customizable), and right-aligns columns whose values all look numeric.

3. **Numbers are now rounded server-side** (in the Python helper) to 4 significant figures by default — customizable via `fits-mode-data-sig-figs` — so a value like `158.7793095952577` becomes `158.8`. This is applied to table cells and the image preview grid; header card values stay at full precision since exact values there (e.g. WCS keywords) can matter.

I verified all of this by actually running it — built a synthetic FITS file, opened it through the real `find-file`/`fits-open-file` paths in batch Emacs, and inspected the rendered buffer content, `tabulated-list-format`, and `header-line-format` directly (confirmed it contains `ID`, `RA`, `DEC`, etc. with proper `:align-to` alignment markers) rather than just reasoning about it.

Since column widths are computed per-page from that page's content,
they can shift slightly as you page through a very long table (page
3's widest RA value might differ from page 1's) — a minor tradeoff for
not having to prescan the whole table. Everything else (paging,
jump-to-offset, revert-buffer, read-only enforcement) is unchanged.

