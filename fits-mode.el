;;; fits-mode.el --- Browse astronomical FITS files -*- lexical-binding: t; -*-

;; Author: Ben
;; Keywords: files, data, tools, astronomy
;; Package-Requires: ((emacs "27.1"))
;; Version: 0.1.0

;;; Commentary:

;; A read-only browser for FITS (Flexible Image Transport System) files.
;; Opening a .fits file shows a top-level table of its HDUs (extensions);
;; from there you can drill into a given HDU's header, column
;; definitions (for table HDUs), or a paginated view of its data.
;;
;; All the actual FITS parsing is delegated to a small bundled Python
;; script, `fits-helper.py', which uses astropy and prints JSON.  This
;; means fits-mode.el never has to (re-)implement the FITS spec, and
;; benefits from astropy's handling of compressed/tiled images,
;; variable-length arrays, WCS quirks, etc.
;;
;; Usage:
;;
;;   (require 'fits-mode)
;;
;; That's it -- it's self-installing: it registers itself in
;; `auto-mode-alist' so that opening a .fits/.fit file (optionally
;; .gz/.fz compressed) with `find-file' shows the HDU browser directly,
;; and it also arranges for the raw binary content *not* to be read into
;; the buffer first (see `fits-mode--file-handler').  You can also open
;; a file explicitly with `M-x fits-open-file'.
;;
;; In the HDU list buffer:
;;   RET   prompt for which view to open (header/columns/data)
;;   h     view header
;;   c     view columns (table HDUs only)
;;   d     view data
;;   g     refresh
;;   q     quit window
;;
;; In header/columns/data buffers:
;;   q     back to the HDU list
;;   g     refresh
;; Data buffers additionally support:
;;   n/p   next/previous page of rows (table HDUs)
;;   j     jump to a given row offset
;;   t     toggle ASCII picture / numeric grid (image HDUs)
;;   s     cycle the display stretch of the ASCII picture
;;
;; Requires Python 3 with astropy installed (`pip install astropy').

;;; Code:

(require 'tabulated-list)
(require 'json)
(require 'seq)

(defgroup fits-mode nil
  "Browse astronomical FITS files."
  :group 'files
  :prefix "fits-")

(defcustom fits-mode-python-executable "python3"
  "Python executable used to run the bundled FITS helper script."
  :type 'string
  :group 'fits-mode)

(defcustom fits-mode-data-page-size 200
  "Number of table rows fetched per page in `fits-data-mode'."
  :type 'integer
  :group 'fits-mode)

(defcustom fits-mode-data-sig-figs 4
  "Number of significant figures floating-point data cells are rounded to.
Applies to `fits-data-mode' (table rows and image preview grids) only;
header card values are always shown at full precision."
  :type 'integer
  :group 'fits-mode)

(defcustom fits-mode-columns-name-width 24
  "Maximum display width for FITS column names in `fits-columns-mode'."
  :type 'integer
  :group 'fits-mode)

(defcustom fits-mode-data-max-column-width 40
  "Maximum width, in characters, of a single column in `fits-data-mode'.
Columns are otherwise sized to fit their content on the current page, so
this only matters for pathological cases (very long strings or array
reprs); numeric columns formatted to `fits-mode-data-sig-figs' rarely
come close to it."
  :type 'integer
  :group 'fits-mode)

(defcustom fits-mode-image-grid-size '(40 . 24)
  "Size, as (ROWS . COLS), of the downsampled preview grid for image HDUs."
  :type '(cons integer integer)
  :group 'fits-mode)

(defcustom fits-mode-image-default-view 'ascii
  "How `fits-data-mode' first shows image HDUs.
`ascii' renders a downsampled ASCII-art picture of the image; `table'
shows a downsampled grid of numeric pixel values.  Toggle between the
two with \\<fits-data-mode-map>\\[fits-data-toggle-image-view]."
  :type '(choice (const :tag "ASCII picture" ascii)
                 (const :tag "Numeric grid" table))
  :group 'fits-mode)

(defcustom fits-mode-image-ascii-ramp " .:-=+*#%@"
  "Characters used for the ASCII image preview, from darkest to brightest.
Any length of two or more works.  For a smoother look in fonts that
support it, try \" ░▒▓█\"."
  :type 'string
  :group 'fits-mode)

(defcustom fits-mode-image-ascii-nan-char ?\s
  "Character drawn for preview cells containing only NaN/blank pixels."
  :type 'character
  :group 'fits-mode)

(defcustom fits-mode-image-ascii-max-size nil
  "Maximum size, as (COLS . ROWS), of the ASCII image preview.
nil means fit the preview to the window it is displayed in."
  :type '(choice (const :tag "Fit window" nil)
                 (cons (integer :tag "Columns") (integer :tag "Rows")))
  :group 'fits-mode)

(defcustom fits-mode-image-char-aspect 2.0
  "Height-to-width ratio of a character cell in your font.
Used to keep the ASCII image preview's aspect ratio correct."
  :type 'number
  :group 'fits-mode)

(defcustom fits-mode-image-stretch 'asinh
  "Display stretch applied to the ASCII image preview.
Pixel values are first clipped to the percentile range
`fits-mode-image-clip-percentiles' and normalised; this then maps them
to brightness.  Cycle through the choices with
\\<fits-data-mode-map>\\[fits-data-cycle-stretch]."
  :type '(choice (const linear) (const sqrt) (const log) (const asinh))
  :group 'fits-mode)

(defcustom fits-mode-image-clip-percentiles '(0.5 . 99.5)
  "Percentiles (LOW . HIGH) at which pixel values are clipped for display."
  :type '(cons number number)
  :group 'fits-mode)

(defcustom fits-mode-file-regexp
  "\\.\\(fits\\|fit\\)\\(\\.\\(fz\\|gz\\)\\)?\\'"
  "Regexp matching FITS file names, used for auto-mode and handler setup."
  :type 'regexp
  :group 'fits-mode)

(defvar fits-mode--helper-script
  (expand-file-name "fits-helper.py"
                     (file-name-directory
                      (or load-file-name buffer-file-name default-directory)))
  "Path to the bundled `fits-helper.py' script.")

;;; Low-level: talking to the Python helper

(defun fits--call-helper (subcommand file &rest args)
  "Run \"fits-helper.py SUBCOMMAND FILE ARGS...\" and return parsed JSON."
  (unless (fboundp 'json-parse-string)
    (error "fits-mode requires an Emacs built with native JSON support"))
  (unless (file-exists-p fits-mode--helper-script)
    (error "fits-mode: helper script not found at %s" fits-mode--helper-script))
  (with-temp-buffer
    (let* ((full-args (append (list subcommand file) args))
           (status (apply #'call-process fits-mode-python-executable
                           nil t nil
                           fits-mode--helper-script full-args))
           (output (buffer-string)))
      (if (/= status 0)
          (error "fits-mode: helper exited %s: %s" status (string-trim output))
        (condition-case err
            (json-parse-string output :object-type 'alist :array-type 'list
                               :null-object nil :false-object :false)
          (error
           (error "fits-mode: could not parse helper output (%s): %s"
                  err (string-trim output))))))))

(defun fits--maybe-signal-error (result)
  "Signal a Lisp error if the helper RESULT is an {\"error\": ...} object."
  (when (and (listp result) (not (arrayp result)) (assq 'error result))
    (let ((kind (alist-get 'error result))
          (msg (alist-get 'message result)))
      (if (equal kind "missing-dependency")
          (error "fits-mode: Python dependency missing (%s) -- try: pip install astropy"
                 msg)
        (error "fits-mode: %s" (or msg kind)))))
  result)

(defun fits--call (subcommand file &rest args)
  "Call helper SUBCOMMAND on FILE with ARGS, signalling on error."
  (fits--maybe-signal-error (apply #'fits--call-helper subcommand file args)))

;;; Shared buffer-local state

(defvar-local fits--file nil
  "Path of the FITS file this buffer (or its ancestry) represents.")
(defvar-local fits--parent-buffer nil
  "Buffer to return to with \\[fits-back].")
(defvar-local fits--hdu-index nil
  "HDU index displayed by this header/columns/data buffer.")

(defun fits--current-file-basename ()
  (if fits--file (file-name-nondirectory fits--file) "?"))

(defun fits-back ()
  "Return to the parent HDU-list buffer, if it is still alive."
  (interactive)
  (let ((parent fits--parent-buffer))
    (quit-window)
    (when (buffer-live-p parent)
      (switch-to-buffer parent))))

;;; fits-hdu-list-mode: the top-level HDU browser

(defvar-local fits--hdus nil
  "Cached list of HDU info alists for the current buffer's file.")

(defvar fits-hdu-list-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map tabulated-list-mode-map)
    (define-key map (kbd "RET") #'fits-hdu-view)
    (define-key map "h" #'fits-view-header)
    (define-key map "c" #'fits-view-columns)
    (define-key map "d" #'fits-view-data)
    (define-key map "g" #'fits-hdu-list-refresh)
    (define-key map "q" #'quit-window)
    map)
  "Keymap for `fits-hdu-list-mode'.")

(define-derived-mode fits-hdu-list-mode tabulated-list-mode "FITS-HDUs"
  "Major mode listing the HDUs (extensions) of a FITS file.

\\{fits-hdu-list-mode-map}"
  (setq tabulated-list-format
        [("#"    3  t)
         ("Name" 16 t)
         ("Type" 14 t)
         ("Dims"  16 t)
         ("Info"  34 t)])
  (setq tabulated-list-padding 2)
  (setq tabulated-list-sort-key nil)
  (setq buffer-read-only t)
  (setq revert-buffer-function (lambda (&rest _) (fits--refresh-hdu-list)))
  (tabulated-list-init-header)
  ;; If this buffer was set up by `find-file' via auto-mode-alist (rather
  ;; than through `fits-open-file'), `buffer-file-name' is already set;
  ;; pick it up and populate the listing immediately.
  (when (and buffer-file-name (not fits--file))
    (setq fits--file buffer-file-name)
    (fits--refresh-hdu-list)))

(defun fits--hdu-list-entries ()
  (mapcar
   (lambda (hdu)
     (let ((idx (alist-get 'index hdu)))
       (list idx
             (vector (number-to-string idx)
                     (or (alist-get 'name hdu) "")
                     (or (alist-get 'type hdu) "")
                     (or (alist-get 'dims hdu) "")
                     (or (alist-get 'info hdu) "")))))
   fits--hdus))

(defun fits--refresh-hdu-list ()
  "Populate the current `fits-hdu-list-mode' buffer from `fits--file'."
  (unless fits--file
    (error "fits-mode: no file associated with this buffer"))
  (message "fits-mode: reading %s..." (fits--current-file-basename))
  (setq fits--hdus (fits--call "info" fits--file))
  (setq tabulated-list-entries (fits--hdu-list-entries))
  (let ((inhibit-read-only t))
    (tabulated-list-print t))
  (rename-buffer (format "*FITS: %s*" (fits--current-file-basename)) t)
  (message "fits-mode: %d HDU(s) in %s"
           (length fits--hdus) (fits--current-file-basename)))

(defun fits-hdu-list-refresh ()
  "Re-read the FITS file and refresh the HDU list."
  (interactive)
  (fits--refresh-hdu-list))

(defun fits--current-hdu ()
  "Return the HDU info alist for the entry at point."
  (let ((idx (tabulated-list-get-id)))
    (unless idx (user-error "No HDU at point"))
    (or (seq-find (lambda (h) (equal (alist-get 'index h) idx)) fits--hdus)
        (error "fits-mode: no cached info for HDU %s" idx))))

(defun fits--hdu-is-table-p (hdu)
  (eq (alist-get 'is_table hdu) t))

(defun fits-hdu-view ()
  "Prompt for which view (header/columns/data) to open for the HDU at point."
  (interactive)
  (let* ((hdu (fits--current-hdu))
         (table-p (fits--hdu-is-table-p hdu))
         (choices (if table-p '(?h ?c ?d) '(?h ?d)))
         (prompt (if table-p
                     "View: [h]eader [c]olumns [d]ata "
                   "View: [h]eader [d]ata "))
         (ch (read-char-choice prompt choices)))
    (pcase ch
      (?h (fits-view-header))
      (?c (fits-view-columns))
      (?d (fits-view-data)))))

;;; fits-header-mode

(defvar fits-header-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map tabulated-list-mode-map)
    (define-key map "q" #'fits-back)
    (define-key map "g" #'fits-header-refresh)
    map)
  "Keymap for `fits-header-mode'.")

(define-derived-mode fits-header-mode tabulated-list-mode "FITS-Header"
  "Major mode showing the header cards of one FITS HDU.

\\{fits-header-mode-map}"
  (setq tabulated-list-format
        [("Keyword" 10 t) ("Value" 24 t) ("Comment" 50 t)])
  (setq tabulated-list-padding 2)
  (setq buffer-read-only t)
  (setq revert-buffer-function (lambda (&rest _) (fits--header-load)))
  (tabulated-list-init-header))

(defun fits--header-load ()
  (let ((cards (fits--call "header" fits--file
                            "--hdu" (number-to-string fits--hdu-index))))
    (setq tabulated-list-entries
          (let ((i 0))
            (mapcar
             (lambda (card)
               (setq i (1+ i))
               (list i (vector (or (alist-get 'keyword card) "")
                                (format "%s" (or (alist-get 'value card) ""))
                                (or (alist-get 'comment card) ""))))
             cards)))
    (let ((inhibit-read-only t))
      (tabulated-list-print t))))

(defun fits-header-refresh ()
  (interactive)
  (fits--header-load))

(defun fits-view-header ()
  "Show the header cards of the HDU at point in a new buffer."
  (interactive)
  (let* ((hdu (fits--current-hdu))
         (idx (alist-get 'index hdu))
         (parent (current-buffer))
         (file fits--file)
         (bufname (format "*FITS Header: %s[%d]*"
                           (fits--current-file-basename) idx)))
    (with-current-buffer (get-buffer-create bufname)
      (fits-header-mode)
      (setq fits--file file
            fits--hdu-index idx
            fits--parent-buffer parent)
      (fits--header-load)
      (goto-char (point-min))
      (pop-to-buffer (current-buffer)))))

;;; fits-columns-mode

(defvar fits-columns-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map tabulated-list-mode-map)
    (define-key map "q" #'fits-back)
    (define-key map "g" #'fits-columns-refresh)
    map)
  "Keymap for `fits-columns-mode'.")

(define-derived-mode fits-columns-mode tabulated-list-mode "FITS-Columns"
  "Major mode showing the column definitions of a FITS table HDU.

\\{fits-columns-mode-map}"
  (setq tabulated-list-format
        `[("Name" ,fits-mode-columns-name-width t) ("Format" 8 t) ("Unit" 10 t) ("Disp" 10 t)])
  (setq tabulated-list-padding 2)
  (setq buffer-read-only t)
  (setq revert-buffer-function (lambda (&rest _) (fits--columns-load)))
  (tabulated-list-init-header))

(defun fits--columns-load ()
  (let ((cols (fits--call "columns" fits--file
                           "--hdu" (number-to-string fits--hdu-index))))
    (setq tabulated-list-entries
          (let ((i 0))
            (mapcar
             (lambda (col)
               (setq i (1+ i))
               (list i (vector (or (alist-get 'name col) "")
                                (or (alist-get 'format col) "")
                                (or (alist-get 'unit col) "")
                                (or (alist-get 'disp col) ""))))
             cols)))
    (let ((inhibit-read-only t))
      (tabulated-list-print t))))

(defun fits-columns-refresh ()
  (interactive)
  (fits--columns-load))

(defun fits-view-columns ()
  "Show the column definitions of the (table) HDU at point."
  (interactive)
  (let* ((hdu (fits--current-hdu)))
    (unless (fits--hdu-is-table-p hdu)
      (user-error "HDU %s is not a table" (alist-get 'index hdu)))
    (let* ((idx (alist-get 'index hdu))
           (parent (current-buffer))
           (file fits--file)
           (bufname (format "*FITS Columns: %s[%d]*"
                             (fits--current-file-basename) idx)))
      (with-current-buffer (get-buffer-create bufname)
        (fits-columns-mode)
        (setq fits--file file
              fits--hdu-index idx
              fits--parent-buffer parent)
        (fits--columns-load)
        (goto-char (point-min))
        (pop-to-buffer (current-buffer))))))

;;; fits-data-mode: paginated table rows, or a downsampled image grid

(defvar-local fits--data-offset 0)
(defvar-local fits--data-total 0)
(defvar-local fits--data-kind nil)   ; 'table or 'image
(defvar-local fits--data-image-view nil) ; 'ascii or 'table, for image HDUs
(defvar-local fits--data-stretch nil)    ; current stretch for ASCII view
(defvar fits-data-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map tabulated-list-mode-map)
    (define-key map "q" #'fits-back)
    (define-key map "g" #'fits-data-refresh)
    (define-key map "n" #'fits-data-next-page)
    (define-key map "p" #'fits-data-prev-page)
    (define-key map "j" #'fits-data-jump-to-offset)
    (define-key map "t" #'fits-data-toggle-image-view)
    (define-key map "s" #'fits-data-cycle-stretch)
    map)
  "Keymap for `fits-data-mode'.")

(defun fits--data-enforce-no-wrap ()
  "Keep the current fits-data buffer in horizontal-scroll mode."
  (when (or (bound-and-true-p visual-line-mode)
            (not truncate-lines)
            word-wrap
            line-move-visual)
    (setq-local truncate-lines t
                word-wrap nil
                line-move-visual nil)
    (when (bound-and-true-p visual-line-mode)
      (visual-line-mode -1))))

(defun fits--data-header-line ()
  "Render the `fits-data-mode' header from `tabulated-list-format'.
The rendered header tracks the current window's horizontal scroll
using the same column widths, padding, and alignment metadata that
`tabulated-list-mode' uses for data rows."
  (let ((segments (list (make-string (max tabulated-list-padding 0) ?\s)))
        (hscroll (window-hscroll))
        (ncols (length tabulated-list-format))
        rendered)
    (dotimes (i ncols)
      (let* ((col (aref tabulated-list-format i))
             (label (format "%s" (or (nth 0 col) "")))
             (width (nth 1 col))
             (props (nthcdr 3 col))
             (not-last-col (< i (1- ncols)))
             (pad-right (if not-last-col
                            (or (plist-get props :pad-right) 1)
                          0))
             (right-align (plist-get props :right-align))
             (visible-label (if not-last-col
                                (truncate-string-to-width label width)
                              label))
             (label-width (string-width visible-label))
             (body (if right-align
                       (concat (make-string (max 0 (- width label-width)) ?\s)
                               visible-label)
                     (concat visible-label
                             (make-string (max 0 (- width label-width)) ?\s)))))
        (push (concat body (make-string pad-right ?\s)) segments)))
    (setq segments (nreverse segments))
    (while segments
      (let* ((segment (car segments))
             (segment-width (string-width segment)))
        (cond
         ((>= hscroll segment-width)
          (setq hscroll (- hscroll segment-width)))
         ((> hscroll 0)
          (push (truncate-string-to-width segment segment-width hscroll) rendered)
          (setq hscroll 0))
         (t
          (push segment rendered))))
      (setq segments (cdr segments)))
    (apply #'concat (nreverse rendered))))

(define-derived-mode fits-data-mode tabulated-list-mode "FITS-Data"
  "Major mode showing FITS table rows, or an image preview grid.

Columns are sized to fit their content on the current page (numeric
columns right-aligned, formatted to `fits-mode-data-sig-figs' significant
figures) rather than to a fixed width, so nothing is truncated
mid-number.  Lines are never wrapped (`tabulated-list-mode' already sets
`truncate-lines'); move point or scroll horizontally
(\\[scroll-left]/\\[scroll-right]) to bring off-screen columns into view,
the same way you would in a wide `org-mode' table.  The column-name
header line stays pinned at the top of the window and tracks horizontal
scrolling with it.

For table HDUs this pages through the real data (\\[fits-data-next-page]
and \\[fits-data-prev-page] to page, \\[fits-data-jump-to-offset] to jump
to a row offset).  For image/array HDUs, since the raw array can be very
large, a downsampled preview grid is shown instead, with summary
statistics shown in the mode line.

\\{fits-data-mode-map}"
  (setq tabulated-list-padding 1)
  (setq tabulated-list-use-header-line t)
  (setq-local truncate-lines t
              word-wrap nil
              line-move-visual nil)
  (when (bound-and-true-p visual-line-mode)
    (visual-line-mode -1))
  ;; Keep these settings enforced even if global/local hooks try to re-enable wrapping.
  (add-hook 'visual-line-mode-hook #'fits--data-enforce-no-wrap nil t)
  (setq buffer-read-only t)
  (setq revert-buffer-function (lambda (&rest _) (fits--data-load))))

(defun fits--data-numeric-string-p (s)
  "Non-nil if string S looks like a plain number (int, float, or exponent)."
  (string-match-p "\\`-?[0-9]+\\(\\.[0-9]+\\)?\\([eE][-+]?[0-9]+\\)?\\'" s))

(defun fits--data-cell-string (v)
  "Turn a JSON-decoded data cell V into its display string."
  (cond
   ((null v) "")
   ((eq v t) "T")
   ((eq v :false) "F")
   (t (format "%s" v))))

(defun fits--data-compute-format (cols str-rows)
  "Build a `tabulated-list-format' vector sized to fit COLS and STR-ROWS.
COLS is a list of column-name strings; STR-ROWS is a list of lists of
already-stringified cell values (see `fits--data-cell-string').  Columns
whose values all look numeric are right-aligned; width is capped at
`fits-mode-data-max-column-width'."
  (let* ((ncols (length cols))
         (widths (make-vector ncols 0))
         (numeric (make-vector ncols t)))
    (dotimes (i ncols)
      (aset widths i (max 3 (length (nth i cols)))))
    (dolist (row str-rows)
      (dotimes (i ncols)
        (let ((s (or (nth i row) "")))
          (when (> (length s) (aref widths i))
            (aset widths i (length s)))
          (when (and (> (length s) 0) (not (fits--data-numeric-string-p s)))
            (aset numeric i nil)))))
    (let (fmt)
      (dotimes (i ncols)
        (push (list (nth i cols)
                    (min fits-mode-data-max-column-width (+ 1 (aref widths i)))
                    nil
                    :right-align (and (aref numeric i) t))
              fmt))
      (vconcat (nreverse fmt)))))

(defun fits--data-ascii-target-size ()
  "Return (COLS . ROWS) available for the ASCII image preview."
  (or fits-mode-image-ascii-max-size
      (let ((win (or (get-buffer-window) (selected-window))))
        (cons (max 10 (- (window-body-width win) 2))
              (max 5 (- (window-body-height win) 1))))))

(defun fits--data-ascii-char (level)
  "Map an intensity LEVEL (0-255, or nil for NaN) to a ramp character."
  (let* ((ramp fits-mode-image-ascii-ramp)
         (n (length ramp)))
    (if (null level)
        fits-mode-image-ascii-nan-char
      (aref ramp (min (1- n) (/ (* level n) 256))))))

(defun fits--data-load-ascii ()
  "Render the current image HDU as ASCII art in this buffer."
  (let* ((size (fits--data-ascii-target-size))
         (clip fits-mode-image-clip-percentiles)
         (res (fits--call "ascii" fits--file
                          "--hdu" (number-to-string fits--hdu-index)
                          "--max-width" (number-to-string (car size))
                          "--max-height" (number-to-string (cdr size))
                          "--char-aspect" (number-to-string
                                           fits-mode-image-char-aspect)
                          "--stretch" (symbol-name fits--data-stretch)
                          "--clip-low" (number-to-string (car clip))
                          "--clip-high" (number-to-string (cdr clip))))
         (levels (alist-get 'levels res))
         (clipv (alist-get 'clip res)))
    (setq tabulated-list-format []
          tabulated-list-entries nil)
    (setq header-line-format
          (format " %s  shape=%s  grid=%s  stretch=%s  clip=[%s, %s]   (t: numbers, s: stretch)"
                  (fits--current-file-basename)
                  (mapconcat #'number-to-string (alist-get 'shape res) "x")
                  (mapconcat #'number-to-string (alist-get 'grid res) "x")
                  (alist-get 'stretch res)
                  (if (numberp (car clipv)) (format "%.4g" (car clipv)) "-")
                  (if (numberp (cadr clipv)) (format "%.4g" (cadr clipv)) "-")))
    (let ((inhibit-read-only t))
      (erase-buffer)
      (unless levels
        (insert "(this HDU has no image data)\n"))
      (dolist (row levels)
        (insert (apply #'string (mapcar #'fits--data-ascii-char row)) "\n")))
    (goto-char (point-min))
    (ignore-errors (set-window-hscroll (get-buffer-window) 0))
    (setq mode-line-process nil)
    (force-mode-line-update)))

(defun fits--data-load ()
  (if (and (eq fits--data-kind 'image) (eq fits--data-image-view 'ascii))
      (fits--data-load-ascii)
    (fits--data-load-table)))

(defun fits--data-load-table ()
  (let* ((grid-rows (car fits-mode-image-grid-size))
         (grid-cols (cdr fits-mode-image-grid-size))
         (res (fits--call "data" fits--file
                           "--hdu" (number-to-string fits--hdu-index)
                           "--offset" (number-to-string fits--data-offset)
                           "--limit" (number-to-string fits-mode-data-page-size)
                           "--grid-rows" (number-to-string grid-rows)
                           "--grid-cols" (number-to-string grid-cols)
                           "--sig-figs" (number-to-string fits-mode-data-sig-figs)))
         (kind (alist-get 'kind res))
         (cols (mapcar (lambda (c) (format "%s" c)) (alist-get 'columns res)))
         (raw-rows (alist-get 'rows res))
         (str-rows (mapcar (lambda (row) (mapcar #'fits--data-cell-string row))
                            raw-rows)))
    (setq fits--data-kind (intern kind))
    (setq fits--data-total (or (alist-get 'total res) (length raw-rows)))
    (setq tabulated-list-format (fits--data-compute-format cols str-rows))
    (tabulated-list-init-header)
    ;; Keep header names aligned with horizontally scrolled table content.
    (setq header-line-format
          '(:eval (list "" 'header-line-indent (fits--data-header-line))))
    (setq tabulated-list-entries
          (let ((i fits--data-offset))
            (mapcar (lambda (row)
                      (setq i (1+ i))
                      (list i (vconcat row)))
                    str-rows)))
    (let ((inhibit-read-only t))
      (tabulated-list-print t))
    (goto-char (point-min))
    (ignore-errors (set-window-hscroll (get-buffer-window) 0))
    (setq mode-line-process
          (if (eq fits--data-kind 'image)
              (let ((stats (alist-get 'stats res)))
                (format "  [shape=%s dtype=%s min=%s max=%s mean=%s std=%s]"
                        (alist-get 'shape res) (alist-get 'dtype res)
                        (alist-get 'min stats) (alist-get 'max stats)
                        (alist-get 'mean stats) (alist-get 'std stats)))
            (format "  [rows %d-%d of %d]"
                    fits--data-offset
                    (max fits--data-offset
                         (1- (+ fits--data-offset (length raw-rows))))
                    fits--data-total)))
    (force-mode-line-update)))

(defun fits-data-refresh ()
  (interactive)
  (fits--data-load))

(defun fits-data-toggle-image-view ()
  "Toggle an image HDU between the ASCII picture and the numeric grid."
  (interactive)
  (unless (eq fits--data-kind 'image)
    (user-error "Not an image HDU"))
  (setq fits--data-image-view
        (if (eq fits--data-image-view 'ascii) 'table 'ascii))
  (fits--data-load))

(defun fits-data-cycle-stretch ()
  "Cycle the display stretch of the ASCII image preview."
  (interactive)
  (unless (and (eq fits--data-kind 'image) (eq fits--data-image-view 'ascii))
    (user-error "Stretch only applies to the ASCII image view"))
  (let* ((order '(linear sqrt log asinh))
         (next (or (cadr (memq fits--data-stretch order)) (car order))))
    (setq fits--data-stretch next)
    (fits--data-load)
    (message "fits-mode: stretch %s" next)))

(defun fits-data-next-page ()
  "Advance to the next page of rows (table HDUs only)."
  (interactive)
  (if (< (+ fits--data-offset fits-mode-data-page-size) fits--data-total)
      (progn
        (setq fits--data-offset (+ fits--data-offset fits-mode-data-page-size))
        (fits--data-load))
    (message "fits-mode: already at the last page")))

(defun fits-data-prev-page ()
  "Go back to the previous page of rows (table HDUs only)."
  (interactive)
  (setq fits--data-offset (max 0 (- fits--data-offset fits-mode-data-page-size)))
  (fits--data-load))

(defun fits-data-jump-to-offset (offset)
  "Jump directly to row OFFSET."
  (interactive "nJump to row offset: ")
  (setq fits--data-offset (max 0 offset))
  (fits--data-load))

(defun fits-view-data ()
  "Show a paginated view of the data of the HDU at point."
  (interactive)
  (let* ((hdu (fits--current-hdu))
         (idx (alist-get 'index hdu))
         (parent (current-buffer))
         (file fits--file)
         (bufname (format "*FITS Data: %s[%d]*"
                           (fits--current-file-basename) idx)))
    (with-current-buffer (get-buffer-create bufname)
      (fits-data-mode)
      (setq fits--file file
            fits--hdu-index idx
            fits--parent-buffer parent
            fits--data-offset 0
            fits--data-kind (if (fits--hdu-is-table-p hdu) 'table 'image)
            fits--data-image-view fits-mode-image-default-view
            fits--data-stretch fits-mode-image-stretch)
      ;; Display first so the ASCII preview can size itself to the window.
      (pop-to-buffer (current-buffer))
      (fits--data-load)
      (goto-char (point-min)))))

;;; Entry points

;;;###autoload
(defun fits-open-file (file)
  "Open FITS FILE and show its HDU listing.
Unlike opening it with `find-file' directly, this never reads the raw
file bytes into an Emacs buffer -- the buffer is populated entirely via
the Python helper script."
  (interactive "fFITS file: ")
  (let* ((file (expand-file-name file))
         (bufname (format "*FITS: %s*" (file-name-nondirectory file)))
         (buf (get-buffer-create bufname)))
    (with-current-buffer buf
      (unless (eq major-mode 'fits-hdu-list-mode)
        (fits-hdu-list-mode))
      (setq fits--file file)
      (fits--refresh-hdu-list))
    (switch-to-buffer buf)))

;;; Avoid slurping raw binary FITS content into a buffer on `find-file'.
;;
;; We register a file-name-handler that short-circuits
;; `insert-file-contents' for FITS files: it reports the file as read
;; (with 0 bytes actually inserted) so that `find-file' proceeds to set
;; `buffer-file-name' and dispatch to `fits-hdu-list-mode' via
;; `auto-mode-alist' as usual, but never has to insert (or the user have
;; to look at) megabytes of binary FITS payload.  This is the same
;; technique `jka-compr' uses for transparent decompression.

(defun fits-mode--file-handler (operation &rest args)
  "Handle file OPERATION for FITS files.
Only `insert-file-contents' is special-cased; everything else is passed
through to the default implementation."
  (if (eq operation 'insert-file-contents)
      (let ((filename (car args))
            (visit (cadr args)))
        (when visit
          (setq buffer-file-name filename)
          (condition-case nil
              (set-visited-file-modtime)
            (error nil)))
        (list filename 0))
    (let ((inhibit-file-name-handlers
           (cons 'fits-mode--file-handler
                 (and (eq inhibit-file-name-operation operation)
                      inhibit-file-name-handlers)))
          (inhibit-file-name-operation operation))
      (apply operation args))))

;;;###autoload
(add-to-list 'auto-mode-alist (cons fits-mode-file-regexp #'fits-hdu-list-mode))

;;;###autoload
(add-to-list 'file-name-handler-alist
             (cons fits-mode-file-regexp #'fits-mode--file-handler))

(provide 'fits-mode)

;;; fits-mode.el ends here
