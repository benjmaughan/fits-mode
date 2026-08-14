# fits-mode

`fits-mode` is an Emacs major mode for browsing FITS files without inserting the raw binary payload into an editing buffer. It is useful when you want fast, read-only inspection of HDU metadata, headers, table schemas, and data from within Emacs.

## Architecture

`fits-mode` has two parts:

- **Emacs Lisp front-end (`fits-mode.el`)**: provides the HDU/header/columns/data views using `tabulated-list-mode`, key-driven navigation, pagination, and refresh.
- **Python helper (`fits-helper.py`)**: uses Astropy to read FITS content and returns JSON for the Elisp front-end.

This split keeps FITS parsing in Astropy while keeping the Emacs side focused on rendering and interaction.

## Requirements

- Emacs 27.1+
- Python 3
- `astropy` in the Python environment used by `fits-mode`

## Installation

1. Put `fits-mode.el` and `fits-helper.py` in the same directory on your `load-path`.
2. Install Astropy:

   ```sh
   pip install astropy
   ```

3. Load `fits-mode`:

   ```elisp
   (add-to-list 'load-path "~/.emacs.d/lisp/fits-mode")
   (require 'fits-mode)
   ```

`fits-mode` registers FITS filename handling automatically, so opening matching FITS files with `find-file` enters `fits-hdu-list-mode`.

## Usage

Open a FITS file with `find-file` or explicitly:

```elisp
M-x fits-open-file
```

### HDU list (`fits-hdu-list-mode`)

Entry view for one-row-per-HDU summary.

Keys:
- `RET` prompt for view (`header` / `columns` / `data`)
- `h` header view
- `c` columns view (table HDUs)
- `d` data view
- `g` refresh
- `q` quit window

### Header view (`fits-header-mode`)

Shows `Keyword`, `Value`, and `Comment` cards for a selected HDU.

Keys:
- `g` refresh
- `q` back

### Columns view (`fits-columns-mode`)

Shows table-column metadata (`Name`, `Format`, `Unit`, `Disp`) for table HDUs.

Keys:
- `g` refresh
- `q` back

### Data view (`fits-data-mode`)

- **Table HDUs**: paginated rows with dynamic column sizing and horizontal scroll.
- **Image/array HDUs**: downsampled ASCII preview plus summary stats in the mode line.

Keys:
- `n` next page
- `p` previous page
- `j` jump to row offset
- `g` refresh
- `q` back

## Text renderings

### HDU list

```text
#  Name      Type       Dims               Info
0  PRIMARY   IMAGE      [2048, 2048]       BITPIX=-32
1  EVENTS    BIN_TABLE  1024 rows x 8 cols TFIELDS=8
```

### Header

```text
Keyword   Value     Comment
XTENSION  BINTABLE
TFIELDS   8
TTYPE1    TIME
```

### Columns

```text
Name      Format  Unit  Disp
TIME      D       s
ENERGY    E       keV
```

### Data (table)

```text
TIME       RA      DEC     ENERGY
1.234e+08  83.82   -5.391  2.341
1.234e+08  83.75   -5.402  0.9127
```

## Configuration

All options are in customization group `fits-mode` (`M-x customize-group RET fits-mode`):

| Option | Default | Description |
|---|---|---|
| `fits-mode-python-executable` | `"python3"` | Python executable used to invoke `fits-helper.py`. |
| `fits-mode-data-page-size` | `200` | Rows fetched per page in `fits-data-mode` for table HDUs. |
| `fits-mode-data-sig-figs` | `4` | Significant figures used for floating-point display in data views. |
| `fits-mode-data-max-column-width` | `40` | Maximum display width for one data column in `fits-data-mode`. |
| `fits-mode-image-grid-size` | `(40 . 24)` | Downsampled image preview grid size as `(ROWS . COLS)`. |
| `fits-mode-file-regexp` | `"\\.\\(fits\\|fit\\)\\(\\.\\(fz\\|gz\\)\\)?\\'"` | Filename regexp used for auto-mode and file-handler registration. |
| `fits-mode-columns-name-width` | `24` | Maximum display width for column names in `fits-columns-mode`. |

Example:

```elisp
(setq fits-mode-python-executable "/path/to/python")
(setq fits-mode-data-page-size 500)
(setq fits-mode-data-sig-figs 6)
(setq fits-mode-columns-name-width 32)
```
