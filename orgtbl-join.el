;;; orgtbl-join.el --- join columns from another table

;; Copyright (C) 2014, 2015, 2016, 2017, 2018, 2019, 2020  Thierry Banel

;; Author: Thierry Banel tbanelwebmin at free dot fr
;; Contributors:
;; Version: 0.1
;; Keywords: org, table, join, filtering
;; Package-Requires: ((cl-lib "0.5"))

;; orgtbl-join is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; orgtbl-join is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:
;; 
;; A master table is enriched with columns coming from a reference
;; table.  For enriching a row of the master table, matching rows from
;; the reference table are selected.  The matching succeeds when the
;; key cells of the master row and the reference row are equal.
;;
;; Full documentation here:
;;   https://github.com/tbanel/orgtbljoin/blob/master/README.org

;;; Requires:
(require 'org-table)
(eval-when-compile (require 'cl-lib))
(require 'rx)

;;; Code:

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; The function (org-table-to-lisp) has been greatly enhanced
;; in Org Mode version 9.4
;; To benefit from this speedup in older versions of Org Mode,
;; this function is copied here with a slightly different name

(defun org-table-to-lisp-9-4 (&optional txt)
  "Convert the table at point to a Lisp structure.

The structure will be a list.  Each item is either the symbol `hline'
for a horizontal separator line, or a list of field values as strings.
The table is taken from the parameter TXT, or from the buffer at point."
  (if txt
      (with-temp-buffer
        (insert txt)
        (goto-char (point-min))
        (org-table-to-lisp-9-4))
    (save-excursion
      (goto-char (org-table-begin))
      (let ((table nil))
        (while (re-search-forward "\\=[ \t]*|" nil t)
	  (let ((row nil))
	    (if (looking-at "-")
		(push 'hline table)
	      (while (not (progn (skip-chars-forward " \t") (eolp)))
		(push (buffer-substring-no-properties
		       (point)
		       (progn (re-search-forward "[ \t]*\\(|\\|$\\)")
			      (match-beginning 0)))
		      row))
	      (push (nreverse row) table)))
	  (forward-line))
        (nreverse table)))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Utility functions

(defun orgtbl--join-colname-to-int (colname table &optional err)
  "Convert the column name into an integer (first column is numbered 1)
COLNAME may be:
- a dollar form, like $5 which is converted to 5
- an alphanumeric name which appears in the column header (if any)
- the special symbol `hline' which is converted into 0
If COLNAME is quoted (single or double quotes),
quotes are removed beforhand.
When COLNAME does not match any actual column,
an error is generated if ERR optional parameter is true
otherwise nil is returned."
  (if (symbolp colname)
      (setq colname (symbol-name colname)))
  (if (or (string-match "^'\\(.*\\)'$" colname)
	  (string-match "^\"\\(.*\\)\"$" colname))
      (setq colname (match-string 1 colname)))
  ;; skip first hlines if any
  (while (not (listp (car table)))
    (setq table (cdr table)))
  (cond ((equal colname "hline")
	 0)
	((string-match "^\\$\\([0-9]+\\)$" colname)
	 (let ((n (string-to-number (match-string 1 colname))))
	   (if (<= n (length (car table)))
	       n
	     (if err
		 (user-error "Column %s outside table" colname)))))
	((string-match "^\\([0-9]+\\)$" colname)
	 (user-error "%s as column name no longer supported, write $%s"
		     colname colname))
	(t
	 (or
	  (cl-loop
	   for h in (car table)
	   for i from 1
	   thereis (and (equal h colname) i))
	  (and
	   err
	   (user-error "Column %s not found in table" colname))))))

(defun orgtbl--join-query-column (prompt table)
  "Interactively query a column.
PROMPT is displayed to the user to explain what answer is expected.
TABLE is the org mode table from which a column will be choosen
by the user.  Its header is used for column names completion.  If
TABLE has no header, completion is done on generic column names:
$1, $2..."
  (while (eq 'hline (car table))
    (setq table (cdr table)))
  (org-icompleting-read
    prompt
    (if (memq 'hline table) ;; table has a header
	(car table)
      (cl-loop              ;; table does not have a header
       for row in (car table)
       for i from 1
       collect (format "$%s" i)))))

(defun orgtbl--join-convert-to-hashtable (table col)
  "Convert an Org-mode TABLE into a hash table.
The purpose is to provide fast lookup to TABLE's rows.  The COL
column contains the keys for the hashtable entries.  Return a
cons, the car contains the header, the cdr contains the
hashtable."
  ;; skip heading horinzontal lines if any
  (while (eq (car table) 'hline)
    (setq table (cdr table)))
  ;; split header and body
  (let ((head)
	(body (memq 'hline table))
	(hash (make-hash-table :test 'equal :size (+ 20 (length table)))))
    (if (not body)
	(setq body table)
      (setq head table)
      ;; terminate header with nil
      (let ((h head))
	(while (not (eq (cadr h) 'hline))
	  (setq h (cdr h)))
	(setcdr h nil)))
    ;; fill-in the hashtable
    (cl-loop for row in body
	     if (listp row)
	     do
	     (let ((key (nth col row)))
	       (puthash key (nconc (gethash key hash) (list row)) hash)))
    (cons head hash)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; The following functions are borrowed
;; from the orgtbl-aggregate package.

(defun orgtbl-list-local-tables ()
  "Search for available tables in the current file."
  (interactive)
  (let ((tables))
    (save-excursion
      (goto-char (point-min))
      (while (re-search-forward "^[ \t]*#\\+\\(tbl\\)?name:[ \t]*\\(.*\\)" nil t)
	(push (match-string-no-properties 2) tables)))
    tables))

(defun orgtbl-get-distant-table (name-or-id)
  "Find a table in the current buffer named NAME-OR-ID
and returns it as a lisp list of lists.
An horizontal line is translated as the special symbol `hline'."
  (unless (stringp name-or-id)
    (setq name-or-id (format "%s" name-or-id)))
  (let (buffer loc)
    (save-excursion
      (goto-char (point-min))
      (if (re-search-forward
	   (concat "^[ \t]*#\\+\\(tbl\\)?name:[ \t]*"
		   (regexp-quote name-or-id)
		   "[ \t]*$")
	   nil t)
	  (setq buffer (current-buffer)
		loc (match-beginning 0))
	(let ((id-loc (org-id-find name-or-id 'marker)))
	  (unless (and id-loc (markerp id-loc))
	    (error "Can't find remote table \"%s\"" name-or-id))
	  (setq buffer (marker-buffer id-loc)
		loc (marker-position id-loc))
	  (move-marker id-loc nil))))
    (with-current-buffer buffer
      (save-excursion
	(goto-char loc)
	(forward-char 1)
	(unless (and (re-search-forward "^\\(\\*+ \\)\\|[ \t]*|" nil t)
		     (not (match-beginning 1)))
	  (user-error "Cannot find a table at NAME or ID %s" name-or-id))
	(org-table-to-lisp-9-4)))))

(defun orgtbl-insert-elisp-table (table)
  "Insert TABLE in current buffer at point.
TABLE is a list of lists of cells.  The list may contain the
special symbol 'hline to mean an horizontal line."
  (let* ((nbrows (length table))
	 (nbcols (cl-loop
		  for row in table
		  maximize (if (listp row) (length row) 0)))
	 (maxwidths  (make-list nbcols 1))
	 (numbers    (make-list nbcols 0))
	 (non-empty  (make-list nbcols 0)))
    ;; remove text properties, compute maxwidths
    (cl-loop for row in table
	     do
	     (cl-loop for cell on row
		      for mx on maxwidths
		      for nu on numbers
		      for ne on non-empty
		      for cellnp = (substring-no-properties (or (car cell) ""))
		      do (setcar cell cellnp)
		      do (when (string-match-p org-table-number-regexp cellnp)
			   (cl-incf (car nu)))
		      do (unless (equal cellnp "")
			   (cl-incf (car ne)))
		      do (if (< (car mx) (length cellnp))
			    (setcar mx (length cellnp)))))

    ;; inactivating jit-lock-after-change boosts performance a lot
    (cl-letf (((symbol-function 'jit-lock-after-change) (lambda (a b c)) ))
      ;; insert well padded and aligned cells at current buffer position
      (cl-loop for row in table
	       do
	       (if (listp row)
		   (cl-loop for cell in row
			    for mx in maxwidths
			    for nu in numbers
			    for ne in non-empty
			    for pad = (- mx (length cell))
			    do (cond ((<= pad 0)
				      ;; no alignment
				      (insert "| " cell " "))
				     ((< nu (* org-table-number-fraction ne))
				      ;; left alignment
				      (insert "| " cell (make-string pad ? ) " "))
				     (t
				      ;; right alignment
				      (insert "| " (make-string pad ? ) cell " "))))
		 (cl-loop with bar = "|"
			  for mx in maxwidths
			  do (insert bar (make-string (+ mx 2) ?-))
			  do (setq bar "+")))
	       do (insert "|\n")))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; In-place mode

;;;###autoload
(defun orgtbl-join (&optional ref-table ref-column)
  "Add material from a reference table to the current table.

Optional REF-TABLE is the name of a reference table, in the
current buffer, as given by a #+NAME: name-of-reference
tag above the table.  If not given, it is prompted interactively.

Optional REF-COLUMN is the name of a column in the reference
table, to be compared with the column the point in on.  If not
given, it is prompted interactively.

Rows from the reference table are appended to rows of the current
table.  For each row of the current table, matching rows from the
reference table are searched and appended.  The matching is
performed by testing for equality of cells in the current column,
and a joining column in the reference table.

If a row in the current table matches several rows in the
reference table, then the current row is duplicated and each copy
is appended with a different reference row.

If no matching row is found in the reference table, then the
current row is kept, with empty cells appended to it."
  (interactive)
  (org-table-check-inside-data-field)
  (let ((col (format "$%s" (org-table-current-column)))
	(tbl (org-table-to-lisp-9-4))
	(pt (line-number-at-pos))
	(cn (- (point) (point-at-bol))))
    (unless ref-table
      (setq ref-table
	    (org-icompleting-read
	     "Reference table: "
	     (orgtbl-list-local-tables))))
    (setq ref-table (orgtbl-get-distant-table ref-table))
    (unless ref-column
      (setq ref-column
	    (orgtbl--join-query-column
	     "Reference column: "
	     ref-table)))
    (let ((b (org-table-begin))
	  (e (org-table-end)))
      (save-excursion
	(goto-char e)
	(orgtbl-insert-elisp-table
	 (orgtbl--create-table-joined
	  tbl
	  col
	  ref-table
	  ref-column)))
      (delete-region b e))
    (goto-char (point-min))
    (forward-line (1- pt))
    (forward-char cn)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; PULL & PUSH engine

(defun orgtbl--join-append-mas-ref-row (masrow refrow refcol)
  "Concatenate master and reference rows, skiping the reference column.
MASROW is a list of cells from the master table.  REFROW is a
list of cells from the reference table.  REFCOL is the position,
numbered from zero, of the column in REFROW that should not be
appended in the result, because it is already present in MASROW."
  (let ((result (reverse masrow))
	(i 0))
    (while refrow
      (unless (equal i refcol)
	(setq result (cons (car refrow) result)))
      (setq refrow (cdr refrow))
      (setq i (1+ i)))
    (reverse result)))

(defun orgtbl--create-table-joined (mastable mascol reftable refcol)
  "Join a master table with a reference table.
MASTABLE is the master table, as a list of lists of cells.
MASCOL is the name of the joining column in the master table.
REFTABLE is the reference table.
REFCOL is the name of the joining column in the reference table.
Returns MASTABLE enriched with material from REFTABLE."
  (let ((result)  ;; result built in reverse order
	(refhead)
	(refhash))
    ;; make master table rectangular if not all rows
    ;; share the same number of cells
    (let ((width
	   (cl-loop for row in mastable
		    maximize (if (listp row) (length row) 0))))
      (cl-loop for row on mastable
	       if (listp (car row))
	       do (let ((n (- width (length (car row)))))
		    (if (> n 0)
			(setcar
			 row
			 (nconc (car row) (make-list n "")))))))
    ;; skip any hline a the top of both tables
    (while (eq (car mastable) 'hline)
      (setq result (cons 'hline result))
      (setq mastable (cdr mastable)))
    (while (eq (car reftable) 'hline)
      (setq reftable (cdr reftable)))
    ;; convert column-names to numbers
    (setq mascol (1- (orgtbl--join-colname-to-int mascol mastable t)))
    (setq refcol (1- (orgtbl--join-colname-to-int refcol reftable t)))
    ;; convert reference table into fast-lookup hashtable
    (setq reftable (orgtbl--join-convert-to-hashtable reftable refcol)
	  refhead (car reftable)
	  refhash (cdr reftable))
    ;; iterate over master table header if any
    ;; and join it with reference table header if any
    (if (memq 'hline mastable)
	(while (listp (car mastable))
	  (setq result
		(cons (orgtbl--join-append-mas-ref-row
		       (car mastable)
		       (and refhead (car refhead))
		       refcol)
		      result))
	  (setq mastable (cdr mastable))
	  (if refhead
	      (setq refhead (cdr refhead)))))
    ;; create the joined table
    (cl-loop
     for masline in mastable
     do
     (if (not (listp masline))
	 (setq result (cons masline result))
       (let ((result0 result))
	 ;; if several ref-lines match, all of them are considered
	 (cl-loop
	  for refline in (gethash (nth mascol masline) refhash)
	  do
	  (setq
	   result
	   (cons
	    (orgtbl--join-append-mas-ref-row masline refline refcol)
	    result)))
	 ;; if no ref-line matches, add the non-matching master-line anyway
	 (if (eq result result0)
	     (setq result (cons masline result))))))
    (nreverse result)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; PUSH mode

;;;###autoload
(defun orgtbl-to-joined-table (table params)
  "Enrich the master TABLE with lines from a reference table.

PARAMS contains pairs of key-value with the following keys:

:ref-table   the reference table.
             Lines from the reference table will be added to the
             master table.

:mas-column  the master joining column.
             This column names one of the master table columns.

:ref-column  the reference joining column.
             This column names one of the reference table columns.

Columns names are either found in the header of the table, if the
table has a header, or a dollar form: $1, $2, and so on.

The destination must be specified somewhere in the
same file with a bloc like this:
#+BEGIN RECEIVE ORGTBL destination_table_name
#+END RECEIVE ORGTBL destination_table_name"
  (interactive)
  (let ((joined-table
	 (orgtbl--create-table-joined
	  table
	  (plist-get params :mas-column)
	  (orgtbl-get-distant-table (plist-get params :ref-table))
	  (plist-get params :ref-column))))
    (with-temp-buffer
      (orgtbl-insert-elisp-table joined-table)
      (buffer-substring-no-properties (point-min) (1- (point-max))))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; PULL mode

;;;###autoload
(defun org-insert-dblock:join ()
  "Wizard to interactively insert a joined table as a dynamic block."
  (interactive)
  (let* ((localtables (orgtbl-list-local-tables))
	 (mastable
	  (org-icompleting-read
	   "Master table: "
	   localtables))
	 (mascol
	  (orgtbl--join-query-column
	   "Master joining column: "
	   (orgtbl-get-distant-table mastable)))
	 (reftable
	  (org-icompleting-read
	   "Reference table: "
	   localtables))
	 (refcol
	  (orgtbl--join-query-column
	   "Reference joining column: "
	   (orgtbl-get-distant-table reftable))))
    (org-create-dblock
     (list :name "join"
	   :mas-table mastable :mas-column mascol
	   :ref-table reftable :ref-column refcol))
    (org-update-dblock)))

;;;###autoload
(defun org-dblock-write:join (params)
  "Create a joined table out of a master and a reference table.

PARAMS contains pairs of key-value with the following keys:

:mas-table   the master table.
             This table will be copied and enriched with material
             from the reference table.

:ref-table   the reference table.
             Lines from the reference table will be added to the
             master table.

:mas-column  the master joining column.
             This column names one of the master table columns.

:ref-column  the reference joining column.
             This column names one of the reference table columns.

Columns names are either found in the header of the table, if the
table has a header, or a dollar form: $1, $2, and so on.

The
#+BEGIN RECEIVE ORGTBL destination_table_name
#+END RECEIVE ORGTBL destination_table_name"
  (interactive)
  (let ((formula (plist-get params :formula))
	(content (plist-get params :content))
	(tblfm nil))
    (when (and content
	       (string-match
		(rx bos (* (any " \t")) (group "#+" (? "tbl") "name:" (* not-newline)))
		content))
      (insert (match-string 1 content) "\n"))
    (orgtbl-insert-elisp-table
     (orgtbl--create-table-joined
      (orgtbl-get-distant-table (plist-get params :mas-table))
      (plist-get params :mas-column)
      (orgtbl-get-distant-table (plist-get params :ref-table))
      (plist-get params :ref-column)))
    (delete-char -1) ;; remove trailing \n which Org Mode will add again
    (when (and content
	       (string-match "^[ \t]*\\(#\\+tblfm:.*\\)" content))
      (setq tblfm (match-string 1 content)))
    (when (stringp formula)
      (if tblfm
	  (unless (string-match (rx-to-string formula) tblfm)
	    (setq tblfm (format "%s::%s" tblfm formula)))
	(setq tblfm (format "#+TBLFM: %s" formula))))
    (when tblfm
      (end-of-line)
      (insert "\n" tblfm)
      (forward-line -1)
      (condition-case nil
	  (org-table-recalculate 'all)
	(args-out-of-range nil)))))

;;;###autoload
(defun orgtbl-join-setup-keybindings ()
  "Setup key-binding and menu entry.
This function can be called in your .emacs. It will add the `C-c
C-x j' key-binding for calling the orgtbl-join wizard, and a menu
entry under Tbl > Column > Join with another table."
  (eval-after-load 'org
    '(progn
       (org-defkey org-mode-map "\C-c\C-xj" 'orgtbl-join)
       (easy-menu-add-item
	org-tbl-menu '("Column")
	["Join with another table" orgtbl-join t]))))

(provide 'orgtbl-join)
;;; orgtbl-join.el ends here
