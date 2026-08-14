LLM chat used to develop the mode:


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

