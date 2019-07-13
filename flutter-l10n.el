;;; flutter-l10n.el --- Tools for Flutter L10N -*- lexical-binding: t -*-

;; Copyright (C) 2019 Aaron Madlon-Kay

;; Author: Aaron Madlon-Kay
;; Version: 0.1.0
;; URL: https://github.com/amake/flutter.el
;; Package-Requires: ((emacs "24.5"))
;; Keywords: languages

;; This file is not part of GNU Emacs.

;; flutter-l10n.el is free software; you can redistribute it and/or modify it
;; under the terms of the GNU General Public License as published by the Free
;; Software Foundation; either version 3, or (at your option) any later version.
;;
;; flutter-l10n.el is distributed in the hope that it will be useful, but
;; WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
;; FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
;; more details.
;;
;; You should have received a copy of the GNU General Public License along with
;; flutter-l10n.el.  If not, see http://www.gnu.org/licenses.

;;; Commentary:

;; flutter-l10n.el is a package providing helpful functions for localizing
;; Flutter applications according to best practices described at
;; `https://flutter.dev/docs/development/accessibility-and-localization/internationalization'.

;;; Code:

(eval-when-compile (require 'subr-x))
(require 'thingatpt)
(require 'flutter-project)



;;; Public variables

(defvar-local flutter-l10n-classname "AppLocalizations"
  "The name of the class that holds the application's string
definitions.")

(put 'flutter-l10n-classname 'safe-local-variable #'stringp)

(defvar-local flutter-l10n-file "lib/app_l10n.dart"
  "The name of the file relative to the project root that holds
the string definitions class.")

(put 'flutter-l10n-file 'safe-local-variable #'stringp)


;;; Code generation

(defconst flutter-l10n--ref-templ "%s.of(context).%s")

(defun flutter-l10n--gen-string-ref (id)
  "Generate a reference to the string with ID."
  (format flutter-l10n--ref-templ flutter-l10n-classname id))

(defconst flutter-l10n--def-templ-interp
  "String %s() {\n  Intl.message(%s, name: '%1$s', args: []);\n}")

(defconst flutter-l10n--def-templ-nointerp
  "String get %s => Intl.message(%s, name: '%1$s');")

(defun flutter-l10n--gen-string-def (id value)
  "Generate a l10n string definition with ID and VALUE."
  (let ((template (if (flutter-l10n--has-interp value)
                      flutter-l10n--def-templ-interp
                    flutter-l10n--def-templ-nointerp)))
    (format template id value)))

(defun flutter-l10n--has-interp (string)
  "Return non-nil if STRING uses interpolation."
  (string-match-p "\\$" string))

(defconst flutter-l10n--comment-templ "// %s")

(defun flutter-l10n--gen-comment (contents)
  "Generate a comment with CONTENTS."
  (format flutter-l10n--comment-templ contents))

(defconst flutter-l10n--import-templ "import 'package:%s/%s';")

(defun flutter-l10n--gen-import (file)
  "Generate an import statement for FILE in the current project."
  (format flutter-l10n--import-templ
          (flutter-project-get-name)
          (string-remove-prefix "lib/" file)))


;;; Internal utilities

(defun forward-dart-string (&optional arg)
  "Move to the end or beginning of the string at point.
Go forward for positive ARG, or backward for negative ARG.
Assumes start in middle of string.  Not meant for general use;
only for making `bounds-of-thing-at-point' work."
  (interactive "^p")
  (if (natnump arg)
      (re-search-forward "[^\"']+[\"']" nil 'move)
    (re-search-backward "[\"'][^\"']" nil 'move)))

(defun flutter-l10n--normalize-string (string)
  "Normalize a Dart STRING."
  (format "'%s'" (flutter-l10n--strip-quotes string)))

(defun flutter-l10n--strip-quotes (string)
  "Strip qutoes from a quoted STRING."
  (if (string-match-p "^\\([\"']\\).*\\1$" string)
      (substring string 1 -1)
    string))

(defun flutter-l10n--looking-at-import-p ()
  "Return non-nil if current line is an import statement."
  (save-excursion
    (beginning-of-line)
    (looking-at-p "^import ")))

(defun flutter-l10n--get-l10n-file ()
  "Find the root of the project."
  (concat (file-name-as-directory (flutter-project-get-root)) flutter-l10n-file))

(defun flutter-l10n--append-to-current-line (contents)
  "Append CONTENTS to end of current line."
  (save-excursion
    (end-of-line)
    (insert " " contents)))

(defun flutter-l10n--append-to-l10n-file (definition)
  "Append DEFINITION to the end of the l10n class in the l10n file."
  (let ((target (find-file-noselect (flutter-l10n--get-l10n-file))))
    (with-current-buffer target
      (goto-char (point-max))
      (search-backward "}")
      (insert "\n  " definition "\n"))))

(defun flutter-l10n--file-imported-p (file)
  "Return non-nil if the current file has an import statement for
FILE."
  (let ((statement (flutter-l10n--gen-import file)))
    (save-excursion
      (goto-char 1)
      (search-forward statement nil t))))

(defun flutter-l10n--import-file (file)
  "Add an import statement for FILE to the current file."
  (let ((statement (flutter-l10n--gen-import file)))
    (save-excursion
      (goto-char 1)
      (insert statement "\n"))))

(defun flutter-l10n--read-id ()
  "Prompt user for a string ID."
  (let ((response (read-string "String ID [skip]: ")))
    (if (string-empty-p response)
        nil
      response)))

(defun flutter-l10n--nesting-at-point ()
  "Build a list indicating the nested structure of the code at point.

Each item is of the form (DELIMITER . POSITION), in order of
decreasing position (from leaf to root).  Assumes that code is
well-formed."
  (let (structure
        (curr-point (point)))
    (save-excursion
      (goto-char 1)
      (while (re-search-forward "//\\|[][(){}]" curr-point t)
        (let ((char (match-string 0)))
          (cond ((string= "//" char)
                 (end-of-line))
                ((cl-search char "([{")
                 (push `(,char . ,(match-beginning 0)) structure))
                ((cl-search char ")]}")
                 (pop structure))))))
    structure))

(defun flutter-l10n--find-applied-consts ()
  "Find the `const` keywords that apply to point.

Result is a list of (BEGINING . END) in decreasing order (from
leaf to root)."
  (let (results
        (structure (flutter-l10n--nesting-at-point)))
    (save-excursion
      (while structure
        (let* ((delim (pop structure))
               (token (car delim))
               (position (cdr delim))
               (bound (cdar structure)))
          (goto-char (- position (length token)))
          (when (and (re-search-backward "\\b[a-z]+\\b" bound t)
                     (string= "const" (match-string 0)))
            ;; TODO: Fix false positive when const in comment
            (push `(,(match-beginning 0) . ,(match-end 0)) results)))))
    (nreverse results)))

(defun flutter-l10n--delete-applied-consts ()
  "Delete the `const` keywords that apply to point."
  (dolist (pos (flutter-l10n--find-applied-consts))
    (delete-region (car pos) (cdr pos))))


;;; Public interface

;;;###autoload
(defun flutter-l10n-externalize-at-point ()
  "Replace a string with a Flutter l10n call.
The corresponding string definition will be put on the kill
ring for yanking into the l10n class."
  (interactive)
  (let* ((bounds (bounds-of-thing-at-point 'dart-string))
         (beg (car bounds))
         (end (cdr bounds))
         (value (flutter-l10n--normalize-string
                 (buffer-substring beg end)))
         (id (flutter-l10n--read-id))
         (definition (flutter-l10n--gen-string-def id value))
         (reference (flutter-l10n--gen-string-ref id))
         (comment (flutter-l10n--gen-comment
                   (flutter-l10n--strip-quotes value))))
    (when id ; null id means user chose to skip
      (delete-region beg end)
      (insert reference)
      (flutter-l10n--delete-applied-consts)
      (flutter-l10n--append-to-current-line comment)
      (unless (flutter-l10n--file-imported-p flutter-l10n-file)
        (flutter-l10n--import-file flutter-l10n-file))
      (kill-new definition))))

;;;###autoload
(defun flutter-l10n-externalize-all ()
  "Interactively externalize all string literals in the buffer.
The corresponding string definitions will be appended to the end
of the l10n class indicated by `flutter-l10n-file'."
  (interactive)
  (save-excursion
    (goto-char 1)
    (let (history)
      (while (re-search-forward "'[^']+?'\\|\"[^\"]\"" nil t)
        (unless (flutter-l10n--looking-at-import-p)
          (let* ((value (flutter-l10n--normalize-string
                         (match-string 0)))
                 (id (flutter-l10n--read-id))
                 (definition (flutter-l10n--gen-string-def id value))
                 (reference (flutter-l10n--gen-string-ref id))
                 (comment (flutter-l10n--gen-comment
                           (flutter-l10n--strip-quotes value))))
            (when id ; null id means user chose to skip
              (replace-match reference t t)
              (flutter-l10n--delete-applied-consts)
              (flutter-l10n--append-to-current-line comment)
              (unless (member id history)
                (flutter-l10n--append-to-l10n-file definition))
              (push id history)))))
      (if history
          (unless (flutter-l10n--file-imported-p flutter-l10n-file)
            (flutter-l10n--import-file flutter-l10n-file))))))

(provide 'flutter-l10n)
;;; flutter-l10n.el ends here
