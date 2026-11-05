#!/usr/bin/env python3
"""Helper script for fits-mode.el.

Introspects a FITS file with astropy and prints a single JSON value to
stdout describing what was asked for.  Never mutates the file (opened
read-only, memory-mapped).  This script has no state between
invocations; fits-mode.el calls it once per request.

Subcommands:
    info    FILE                       -> list of HDU summaries
    header  FILE --hdu N                -> list of header cards
    columns FILE --hdu N                -> list of table columns
    data    FILE --hdu N [--offset --limit --grid-rows --grid-cols]
                                        -> a page of table rows, or a
                                           downsampled preview grid for
                                           image/array HDUs
    ascii   FILE --hdu N [--max-width --max-height --char-aspect
                          --stretch --clip-low --clip-high]
                                        -> a block-averaged, contrast-
                                           stretched intensity map of an
                                           image HDU (levels 0-255), for
                                           rendering as ASCII art

On any failure a JSON object of the form {"error": ..., "message": ...}
is printed instead, and the process exits non-zero.
"""
import sys
import json
import argparse

try:
    import numpy as np
    from astropy.io import fits
except ImportError as exc:  # astropy/numpy missing
    print(json.dumps({"error": "missing-dependency", "message": str(exc)}))
    sys.exit(1)


def _jsonable(value):
    """Coerce a numpy/FITS scalar into something json.dumps can handle."""
    if isinstance(value, np.generic):
        value = value.item()
    if isinstance(value, bytes):
        try:
            value = value.decode("utf-8", "replace")
        except Exception:
            value = repr(value)
    if isinstance(value, float):
        if value != value:  # NaN
            return None
        if value in (float("inf"), float("-inf")):
            return "inf" if value > 0 else "-inf"
    if isinstance(value, fits.card.Undefined):
        return None
    if value is None or isinstance(value, (bool, int, float, str)):
        return value
    return str(value)


def _is_table(hdu):
    return getattr(hdu, "columns", None) is not None


def _format_value(value, sig):
    """Like `_jsonable`, but floats are rounded to SIG significant figures
    and returned as a ready-to-display string (e.g. "158.8", "1.091e+00").
    Used for table/image *data* cells, where readability beats precision;
    header cards go through `_jsonable` unchanged since exact values there
    (e.g. WCS keywords) matter."""
    if isinstance(value, np.generic):
        value = value.item()
    if isinstance(value, float):
        if value != value:  # NaN
            return None
        if value in (float("inf"), float("-inf")):
            return "inf" if value > 0 else "-inf"
        if value == 0:
            return "0"
        return f"{value:.{sig}g}"
    return _jsonable(value)


def cmd_info(args):
    out = []
    with fits.open(args.file, memmap=True) as hdul:
        for i, hdu in enumerate(hdul):
            name = hdu.name or ("PRIMARY" if i == 0 else "")
            entry = {
                "index": i,
                "name": name,
                "ver": int(getattr(hdu, "ver", 1) or 1),
                "type": type(hdu).__name__,
                "is_table": _is_table(hdu),
            }
            if _is_table(hdu):
                nrows = int(hdu.header.get("NAXIS2", 0))
                ncols = len(hdu.columns)
                entry["nrows"] = nrows
                entry["ncols"] = ncols
                entry["dims"] = f"{nrows} rows"
                entry["info"] = f"{nrows} rows x {ncols} cols"
            else:
                shape = tuple(getattr(hdu, "shape", ()) or ())
                dtype = ""
                if getattr(hdu, "data", None) is not None:
                    dtype = str(hdu.data.dtype)
                entry["nrows"] = 0
                entry["ncols"] = 0
                entry["dims"] = "x".join(str(s) for s in shape) if shape else "-"
                entry["info"] = (f"{entry['dims']} {dtype}").strip()
            out.append(entry)
    print(json.dumps(out))


def cmd_header(args):
    with fits.open(args.file, memmap=True) as hdul:
        hdu = hdul[args.hdu]
        out = [
            {
                "keyword": card.keyword,
                "value": _jsonable(card.value),
                "comment": card.comment or "",
            }
            for card in hdu.header.cards
        ]
    print(json.dumps(out))


def cmd_columns(args):
    with fits.open(args.file, memmap=True) as hdul:
        hdu = hdul[args.hdu]
        if not _is_table(hdu):
            print(json.dumps({"error": "not-a-table",
                               "message": "HDU %d has no columns" % args.hdu}))
            return
        out = [
            {
                "name": col.name,
                "format": col.format,
                "unit": col.unit or "",
                "disp": col.disp or "",
            }
            for col in hdu.columns
        ]
    print(json.dumps(out))


def _table_page(hdu, offset, limit, sig):
    data = hdu.data
    total = len(data) if data is not None else 0
    offset = max(0, offset)
    limit = max(1, limit)
    chunk = data[offset:offset + limit] if data is not None else []
    colnames = [c.name for c in hdu.columns]
    rows = []
    for rec in chunk:
        row = []
        for name in colnames:
            v = rec[name]
            if isinstance(v, np.ndarray):
                if v.size <= 8:
                    row.append(json.dumps([_format_value(x, sig) for x in v.tolist()]))
                else:
                    row.append(f"<array {v.shape}>")
            else:
                row.append(_format_value(v, sig))
        rows.append(row)
    return {
        "kind": "table",
        "columns": colnames,
        "rows": rows,
        "total": total,
        "offset": offset,
    }


def _image_preview(hdu, grid_rows, grid_cols, sig):
    arr = hdu.data
    if arr is None:
        return {"kind": "image", "shape": [], "dtype": "", "stats": {},
                "columns": [], "rows": []}
    arr = np.asarray(arr)
    shape = arr.shape
    stats = {}
    try:
        finite = arr[np.isfinite(arr)] if np.issubdtype(arr.dtype, np.floating) else arr.ravel()
        if finite.size:
            stats = {
                "min": _jsonable(np.min(finite)),
                "max": _jsonable(np.max(finite)),
                "mean": _jsonable(np.mean(finite)),
                "std": _jsonable(np.std(finite)),
            }
    except Exception:
        stats = {}

    if arr.ndim >= 2:
        a2 = arr
        while a2.ndim > 2:
            a2 = a2[0]
        r, c = a2.shape
        rstep = max(1, r // max(1, grid_rows))
        cstep = max(1, c // max(1, grid_cols))
        pooled = a2[::rstep, ::cstep][:grid_rows, :grid_cols]
        colnames = [str(i) for i in range(pooled.shape[1])]
        rows = [[_format_value(v, sig) for v in row] for row in pooled.tolist()]
    elif arr.ndim == 1:
        step = max(1, arr.shape[0] // max(1, grid_rows))
        colnames = ["value"]
        rows = [[_format_value(v, sig)] for v in arr[::step][:grid_rows].tolist()]
    else:
        colnames = ["value"]
        rows = [[_format_value(arr.item(), sig)]]

    return {
        "kind": "image",
        "shape": list(shape),
        "dtype": str(arr.dtype),
        "stats": stats,
        "columns": colnames,
        "rows": rows,
    }


def _image_plane(hdu):
    """Return the first 2-D plane of an image HDU as a float array, or None."""
    arr = hdu.data
    if arr is None:
        return None
    arr = np.asarray(arr)
    if arr.ndim == 0:
        return None
    while arr.ndim > 2:
        arr = arr[0]
    if arr.ndim == 1:
        arr = arr[np.newaxis, :]
    return arr.astype(np.float64, copy=False)


def _fit_grid(nrows, ncols, max_w, max_h, char_aspect):
    """Choose an output (H, W) in characters that preserves the image's
    aspect ratio, given that a character cell is CHAR_ASPECT times taller
    than it is wide, and fits within MAX_W x MAX_H."""
    max_w = max(1, max_w)
    max_h = max(1, max_h)
    w = min(max_w, ncols)
    h = max(1, round(w * nrows / ncols / char_aspect))
    if h > max_h:
        h = max_h
        w = max(1, round(h * char_aspect * ncols / nrows))
    return min(h, nrows), min(w, ncols)


def _block_mean(a, h, w):
    """Downsample 2-D array A to roughly (H, W) by averaging blocks,
    ignoring NaNs.  Very large arrays are first strided down so we never
    average over more than a few samples per output cell in each axis."""
    r, c = a.shape
    # Cheap pre-subsample to keep the work (and memmap reads) bounded.
    rs = max(1, r // (h * 4))
    cs = max(1, c // (w * 4))
    if rs > 1 or cs > 1:
        a = a[::rs, ::cs]
        r, c = a.shape
    redges = np.linspace(0, r, h + 1).astype(int)
    cedges = np.linspace(0, c, w + 1).astype(int)
    out = np.full((h, w), np.nan)
    with np.errstate(all="ignore"):
        for i in range(h):
            band = a[redges[i]:max(redges[i + 1], redges[i] + 1)]
            for j in range(w):
                block = band[:, cedges[j]:max(cedges[j + 1], cedges[j] + 1)]
                fin = block[np.isfinite(block)]
                if fin.size:
                    out[i, j] = fin.mean()
    return out


def _stretch(a, kind, lo_pct, hi_pct):
    """Clip A to the [LO_PCT, HI_PCT] percentiles, normalise to 0..1 and
    apply a display stretch.  NaNs are preserved."""
    fin = a[np.isfinite(a)]
    if fin.size == 0:
        return a, None, None
    lo, hi = np.percentile(fin, [lo_pct, hi_pct])
    if not hi > lo:
        lo, hi = float(fin.min()), float(fin.max())
    if not hi > lo:
        return np.where(np.isfinite(a), 0.0, np.nan), float(lo), float(hi)
    with np.errstate(all="ignore"):
        x = np.clip((a - lo) / (hi - lo), 0.0, 1.0)
        if kind == "sqrt":
            x = np.sqrt(x)
        elif kind == "log":
            x = np.log10(1 + 1000 * x) / np.log10(1001)
        elif kind == "asinh":
            x = np.arcsinh(10 * x) / np.arcsinh(10)
    return x, float(lo), float(hi)


def cmd_ascii(args):
    with fits.open(args.file, memmap=True) as hdul:
        hdu = hdul[args.hdu]
        if _is_table(hdu):
            print(json.dumps({"error": "not-an-image",
                              "message": "HDU %d is a table" % args.hdu}))
            return
        plane = _image_plane(hdu)
        if plane is None:
            print(json.dumps({"kind": "ascii", "shape": [], "plane": [],
                              "grid": [0, 0], "stretch": args.stretch,
                              "clip": [None, None], "levels": []}))
            return
        shape = list(np.shape(hdu.data))
        nrows, ncols = plane.shape
        h, w = _fit_grid(nrows, ncols, args.max_width, args.max_height,
                         args.char_aspect)
        pooled = _block_mean(plane, h, w)
        norm, lo, hi = _stretch(pooled, args.stretch, args.clip_low, args.clip_high)
        # FITS convention: pixel (1,1) is bottom-left, so flip vertically
        # to display with the origin at the bottom like DS9 does.
        norm = norm[::-1]
        levels = [[None if not np.isfinite(v) else int(round(v * 255))
                   for v in row] for row in norm]
    print(json.dumps({
        "kind": "ascii",
        "shape": shape,
        "plane": [nrows, ncols],
        "grid": [h, w],
        "stretch": args.stretch,
        "clip": [_jsonable(lo), _jsonable(hi)],
        "levels": levels,
    }))


def cmd_data(args):
    with fits.open(args.file, memmap=True) as hdul:
        hdu = hdul[args.hdu]
        if _is_table(hdu):
            result = _table_page(hdu, args.offset, args.limit, args.sig_figs)
        else:
            result = _image_preview(hdu, args.grid_rows, args.grid_cols, args.sig_figs)
    print(json.dumps(result))


def build_parser():
    p = argparse.ArgumentParser(description=__doc__)
    sub = p.add_subparsers(dest="command", required=True)

    p_info = sub.add_parser("info", help="summarize all HDUs")
    p_info.add_argument("file")
    p_info.set_defaults(func=cmd_info)

    p_header = sub.add_parser("header", help="dump header cards of one HDU")
    p_header.add_argument("file")
    p_header.add_argument("--hdu", type=int, required=True)
    p_header.set_defaults(func=cmd_header)

    p_columns = sub.add_parser("columns", help="dump column definitions of a table HDU")
    p_columns.add_argument("file")
    p_columns.add_argument("--hdu", type=int, required=True)
    p_columns.set_defaults(func=cmd_columns)

    p_data = sub.add_parser("data", help="page of table rows, or an image preview grid")
    p_data.add_argument("file")
    p_data.add_argument("--hdu", type=int, required=True)
    p_data.add_argument("--offset", type=int, default=0)
    p_data.add_argument("--limit", type=int, default=200)
    p_data.add_argument("--grid-rows", type=int, default=40)
    p_data.add_argument("--grid-cols", type=int, default=24)
    p_data.add_argument("--sig-figs", type=int, default=4)
    p_data.set_defaults(func=cmd_data)

    p_ascii = sub.add_parser("ascii", help="intensity map of an image HDU for ASCII rendering")
    p_ascii.add_argument("file")
    p_ascii.add_argument("--hdu", type=int, required=True)
    p_ascii.add_argument("--max-width", type=int, default=80)
    p_ascii.add_argument("--max-height", type=int, default=40)
    p_ascii.add_argument("--char-aspect", type=float, default=2.0)
    p_ascii.add_argument("--stretch", choices=["linear", "sqrt", "log", "asinh"],
                         default="asinh")
    p_ascii.add_argument("--clip-low", type=float, default=0.5)
    p_ascii.add_argument("--clip-high", type=float, default=99.5)
    p_ascii.set_defaults(func=cmd_ascii)

    return p


def main(argv=None):
    args = build_parser().parse_args(argv)
    try:
        args.func(args)
    except Exception as exc:  # pragma: no cover - defensive
        print(json.dumps({"error": "exception", "message": str(exc)}))
        sys.exit(1)


if __name__ == "__main__":
    main()
