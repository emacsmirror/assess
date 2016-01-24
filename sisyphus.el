;;; sisyphus.el --- Test support functions -*- lexical-binding: t -*-

;;; Header:

;; This file is not part of Emacs

;; Author: Phillip Lord <phillip.lord@russet.org.uk>
;; Maintainer: Phillip Lord <phillip.lord@russet.org.uk>
;; Version: 0.1
;; Package-Requires: ((emacs "24.4")(m-buffer "0.13")(dash))

;; The contents of this file are subject to the GPL License, Version 3.0.

;; Copyright (C) 2015, Phillip Lord

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; This file provides functions to support ert, the Emacs Regression Test
;; framework. It includes:

;;  - a set of predicates for comparing strings, buffers and file contents.
;;  - explainer functions for all predicates giving useful output
;;  - macros for creating many temporary buffers at once, and for restoring the
;;    buffer list.
;;  - methods for testing indentation, by comparision or "roundtripping".
;;  - methods for testing fontification.

;; Sisyphus aims to be a stateless as possible, leaving Emacs unchanged whether
;; the tests succeed or fail, with respect to buffers, open files and so on; this
;; helps to keep tests independent from each other. Violations of this will be
;; considered a bug.

;; Sisyphus aims also to be as noiseless as possible, reducing and suppressing
;; extraneous messages where possible, to leave a clean ert output in batch mode.


;;; Status:

;; Sisyphus is currently a work in progress; the API is not currently stable.
;; Even the name is somewhat is doubt. Sisyphus seemed like a good idea when I
;; started, but I keep spelling it wrong. I may also considering winding this
;; into ert-x, because then it can be used to test core.


;;; Code:

;; ** Preliminaries

;; #+begin_src emacs-lisp
(require 'pp)
(require 'ert)
(require 'm-buffer-at)
(require 'm-buffer)
(require 'dash)
;; #+end_src

;; ** Advice

;; Emacs-24 insists on printing out results on a single line with escaped
;; newlines. This does not work so well with the explainer functions in sisyphus
;; and, probably, does not make sense anywhere. So, we advice here. The use of
;; nadvice.el limits this package to Emacs 24.4. Emacs 25 has this fixed.

;; #+begin_src emacs-lisp
(when (= emacs-major-version 24)

  (defun sisyphus--ert-pp-with-indentation-and-newline (orig object)
    (let ((pp-escape-newlines nil))
      (funcall orig object)))

  (advice-add
   'ert--pp-with-indentation-and-newline
   :around
   #'sisyphus--ert-pp-with-indentation-and-newline))
;; #+end_src

;; ** Deliberate Errors

;; Sometimes during testing, we need to throw an "error" deliberately. Sisyphus'
;; own test cases do this to check that state is preserved with this form of
;; non-local exit. Throwing `error' itself is a bit dangerous because we might
;; get that for other reasons; so we create a new symbol here for general use.

;; #+begin_src emacs-lisp
(define-error 'sisyphus-deliberate-error
  "An error deliberately caused during testing."
  'error)
;; #+end_src

;; ** Types

;; Many tests on files or buffers actually end up being string comparision.
;; In many cases, we want to compare the *contents* of a buffer to, for example,
;; the *contents* of a file.

;; Emacs normally uses strings to represent files (i.e. file names) and can also
;; use them to represent buffers (i.e. buffer names). So, here, we introduce a
;; set of "types" where so that we can distinguish between strings, buffer names
;; and file names, passing them at a single parameter. This will allow us to make
;; later parts of the API use overloaded methods based on their type.

;; "Types" are either a Emacs core type (as with buffers and strings), or an 2
;; element list (I haven't used cons cells in case I want to add more elements),
;; with a keyword at the head. This allows sisyphus to distinguish between a
;; simple string and a file or buffer name.

;; #+begin_src elisp
;; Identify "~/.emacs" as a file name
;; (sisyphus-file "~/.emacs")

;; Identify "*Messages*" as a buffer
;; (sisyphus-buffer "*Messages*")
;; #+end_src

;; *** Implementation

;; #+begin_src emacs-lisp
(defun sisyphus-to-string (x)
  "Turn X into a string in a type appropriate way.

If X is identified as a file, returns the file contents.
If X is identified as a buffer, returns the buffer contents.
If X is a string, returns that.

See also `sisyphus-buffer' and `sisyphus-file' which turn a
string into something that will identified appropriately."
  (pcase x
    ((pred stringp) x)
    ((pred bufferp) (m-buffer-at-string x))
    (`(:buffer ,b) (sisyphus-to-string (get-buffer-create b)))
    (`(:file ,f)
     (with-temp-buffer
       (insert-file-contents f)
       (buffer-string)))
    ;; error condition
    (_ (error "Type not recognised"))))

(defun sisyphus-buffer (b)
  "Add type data to the string B marking it as a buffer."
  `(:buffer b))

(defun sisyphus-file (f)
  "Add type data to the string F marking it as a file."
  `(:file ,f))

(defun sisyphus-to-file-name (file)
  "Return file name for FILE.

FILE can be either a string, or a plist returned by
`sisyphus-file' or `sisyphus-make-related-file'."
  (pcase file
    ((pred stringp) file)
    (`(:file ,f) f)
    (_ (error "Type not recognised"))))
;; #+end_src

;; ** Entity Comparision

;; In this section, we provide support for comparing strings, buffer or file
;; contents. The main entry point is `sisyphus=', which works like `string=' but
;; on any of the three data types, in any order.

;; #+begin_src elisp
;;   ;; Compare Two Strings
;;   (sisyphus= "hello" "goodbye")

;;   ;; Compare the contents of Two Buffers
;;   (sisyphus=
;;    (sisyphus-buffer "sisyphus.el")
;;    (sisyphus-buffer "sisyphus-previous.el"))

;;   ;; Compare the contents of Two files
;;   (sisyphus=
;;    (sisyphus-file "~/.emacs")
;;    (sisyphus-file "~/.emacs"))

;;   ;; We can use core Emacs types also
;;   (sisyphus=
;;    (sisyphus-buffer "sisyphus.el")
;;    (get-buffer "sisyphus-previous.el"))

;;   ;; And in any combination; here we compare a string and the contents of a
;;   ;; file.
;;   (sisyphus=
;;    ";; This is an empty .emacs file"
;;    (sisyphus-file "~/.emacs"))
;; #+end_src

;; In addition, `sisyphus=' has an "explainer" function attached which produces a
;; richer output when `sisyphus=' returns false, showing diffs of the string
;; comparison. Compare, for example, the results of running these two tests, one
;; using `string=' and one using `sisyphus='.

;; #+begin_example
;; F temp
;;     (ert-test-failed
;;      ((should
;;        (string= "a" "b"))
;;       :form
;;       (string= "a" "b")
;;       :value nil))

;; F test-sisyphus=
;;     (ert-test-failed
;;      ((should
;;        (sisyphus= "a" "b"))
;;       :form
;;       (sisyphus= "a" "b")
;;       :value nil :explanation "Strings:
;; a
;; and
;; b
;; Differ at:*** /tmp/a935uPW	2016-01-20 13:25:47.373076381 +0000
;; --- /tmp/b9357Zc	2016-01-20 13:25:47.437076381 +0000
;; ***************
;; *** 1 ****
;; ! a
;; \\ No newline at end of file
;; --- 1 ----
;; ! b
;; \\ No newline at end of file

;; "))
;; #+end_example

;; As `sisyphus=' has a compatible interface with `string=' it is also possible
;; to add this explainer function to `string=' for use with tests which do not
;; otherwise use sisyphus, like so:

;; #+begin_src elisp
;; (put 'string= 'ert-explainer 'sisyphus-explain=)
;; #+end_src

;; Currently, `sisyphus' uses the ~diff~ program to do the comparison if it is
;; available, or falls back to just reporting a difference -- this could do with
;; improving, but it is at least no worse than the existing behaviour for string
;; comparison.

;; *** Implementation

;; We start by writing a file silently -- this is important because the
;; ~*Messages*~ buffer should not be affected by the machinary of a failing test,
;; as it hides what is happening from the test code.

;; #+begin_src emacs-lisp
(defun sisyphus--write-file-silently (filename)
  "Write current buffer into FILENAME.
Unlike most other ways of saving a file, this should not
print any messages!"
  (write-region
   (point-min) (point-max)
   filename nil
   'dont-display-wrote-file-message))
;; #+end_src

;; Diff does a nicer comparison than anything in Emacs, although a lisp
;; implementation would have been more portable. Diff is used by quite a few
;; other tools in Emacs, so probably most people will have access to diff.

;; #+begin_src emacs-lisp
(defun sisyphus--explainer-diff-string= (a b)
  "Compare strings A and B using diff output.

We assume that diff exists. Temporary files are left
afterwards for cleanup by the operating system."
  (sisyphus-with-preserved-buffer-list
   (let* ((diff
           (executable-find "diff"))
          (a-buffer
           (generate-new-buffer "a"))
          (b-buffer
           (generate-new-buffer "b"))
          (a-file
           (make-temp-file
            (buffer-name a-buffer)))
          (b-file
           (make-temp-file
            (buffer-name b-buffer))))
     (with-current-buffer
         a-buffer
       (insert a)
       (sisyphus--write-file-silently a-file))
     (with-current-buffer
         b-buffer
       (insert b)
       (sisyphus--write-file-silently b-file))
     (progn
         (format "Strings:\n%s\nand\n%s\nDiffer at:%s\n"
                 a b
                 (with-temp-buffer
                   (call-process
                    diff
                    ;; no infile
                    nil
                    ;; dump to current buffer
                    t
                    nil
                    "-c"
                    a-file
                    b-file)
                   (buffer-string)))))))

(defun sisyphus--explainer-simple-string= (a b)
  "Compare strings for first difference."
  ;; We could do a bit more here.
  (format "String :%s:%s: are not equal."))
;; #+end_src

;; And the actual predicate function and explainer. We do a simple string
;; comparison on the contents of each entity.

;; #+begin_src emacs-lisp
(defun sisyphus= (a b)
  "Compare A and B to see if they are the same.

Equality in this sense means compare the contents in a way which
is appropriate for the type of the two arguments. So, if they are
strings, the compare strings, if buffers, then compare the buffer
contents and so on."
  (string=
   (sisyphus-to-string a)
   (sisyphus-to-string b)))

(defun sisyphus-explain= (a b)
  "Compare A and B and return an explanation.

This function is called by ERT as an explainer function
automatically. See `sisyphus=' for more information."
  (let ((a (sisyphus-to-string a))
        (b (sisyphus-to-string b)))
    (cond
     ((sisyphus= a b)
      t)
     ((executable-find "diff")
      (sisyphus--explainer-diff-string= a b))
     (t
      (sisyphus--explainer-simple-string= a b)))))

(put 'sisyphus= 'ert-explainer 'sisyphus-explain=)
;; #+end_src

;; ** Buffer creation

;; For tests, it is often better to use temporary buffers, as it is much less
;; affected by the existing state of Emacs, and much less likely to affect future
;; state; this is particularly the case where tests are being developed as the
;; developer may be trying to change or write test files at the same time as
;; Emacs is trying to use them for testing.

;; Emacs really only provides a single primitive `with-temp-buffer' for this
;; situation, and that only creates a single temporary buffer at a time. Nesting
;; of these forms sometimes works, but fails if we need to operate on two buffers
;; at once.

;; So, we provide an environment for restoring the buffer list. This allows any
;; creation of buffers we need for testing, followed by clean up afterwards. For
;; example, a trivial usage would be to remove buffers explicitly created.

;; #+begin_src elisp
;;   (sisyphus-with-preserved-buffer-list
;;    (get-buffer-create "a")
;;    (get-buffer-create "b")
;;    (get-buffer-create "c"))
;; #+end_src

;; Any buffer created in this scope is removed, whether this is as a direct or
;; indirect result of the function. For example, this usage creates a ~*Help*~
;; buffer which then gets removed again.

;; #+begin_src elisp
;;   (sisyphus-with-preserved-buffer-list
;;    (describe-function 'self-insert-command))
;; #+end_src

;; This does not prevent changes to existing buffers of course. If ~*Help*~ is
;; already open before evaluation, it will remain open afterwards but with
;; different content.

;; Sometimes, it is useful to create several temporary buffers at once.
;; `sisyphus-with-temp-buffers' provides an easy mechanism for doing this, as
;; well as evaluating content in these buffers. For example, this returns true
;; (actually three killed buffers which were live when the `mapc' form runs).

;; #+begin_src elisp
;;   (sisyphus-with-temp-buffers
;;       (a b c)
;;     (mapc #'buffer-live-p (list a b c)))
;; #+end_src

;; While this creates two buffers, puts "hellogoodbye" into one and "goodbye"
;; into the other, then compares the contents of these buffers with `sisyphus='.

;; #+begin_src elisp
;;   (sisyphus-with-temp-buffers
;;       ((a (insert "hello")
;;           (insert "goodbye"))
;;        (b (insert "goodbye")))
;;     (sisyphus= a b))
;; #+end_src

;; Finally, we provide a simple mechanism for converting any sisyphus type into a
;; buffer. The following form, for example, returns the contents of the ~.emacs~
;; file.

;; #+begin_src elisp
;;   (sisyphus-as-temp-buffer
;;       (sisyphus-file "~/.emacs")
;;     (buffer-string))
;; #+end_src

;; ** Implementation

;; #+begin_src emacs-lisp
(defmacro sisyphus-with-preserved-buffer-list (&rest body)
  "Evaluate BODY, but delete any buffers that have been created."
  (declare (debug t))
  `(let ((before-buffer-list
          (buffer-list)))
     (unwind-protect
         (progn
           ,@body)
       (--map
        (kill-buffer it)
        (-difference (buffer-list)
                     before-buffer-list)))))

(defun sisyphus--temp-buffer-let-form (item)
  (if (not (listp item))
      (sisyphus--temp-buffer-let-form
       (list item))
    `(,(car item)
      (with-current-buffer
          (generate-new-buffer " *sisyphus-with-temp-buffers*")
        ,@(cdr item)
        (current-buffer)))))
;; #+end_src

;; The implementation of `sisyphus-with-temp-buffers' currently uses
;; `sisyphus-with-preserved-buffer-list' to remove buffers which means that it
;; will also delete any buffers created by the user; this may be a mistake, and
;; it might be better to delete the relevant buffers explicitly.

;; #+begin_src emacs-lisp
(defmacro sisyphus-with-temp-buffers (varlist &rest body)
  "Bind variables in varlist to temp buffers, then eval BODY.

VARLIST is of the same form as a `let' binding. Each element is a
symbol or a list (symbol valueforms). Each symbol is bound to a
buffer generated with `generate-new-buffer'. VALUEFORMS are
evaluated with the buffer current. Any buffers created inside
this form (and not just by this form!) are unconditionally killed
at the end of the form."
  (declare (indent 1)
           (debug let))
  (let ((let-form
         (-map
          #'sisyphus--temp-buffer-let-form
          varlist)))
    `(sisyphus-with-preserved-buffer-list
      (let ,let-form
        ,@body))))

(defmacro sisyphus-as-temp-buffer (x &rest body)
  "Insert X in a type-appropriate way into a temp buffer and eval
BODY there.

See `sisyphus-to-string' for the meaning of type-appropriate."
  (declare (indent 1) (debug t))
  `(with-temp-buffer
     (insert (sisyphus-to-string ,x))
     ,@body))
;; #+end_src

;; ** Opening files

;; Opening files presents a particular problem for testing, particularly if we
;; open a file that is already open in the same or a different Emacs. For batch
;; use of Emacs with parallelisation, the situation becomes intractable.

;; A solution is to copy files before we open them, which means that they can be
;; changed freely. Largely, the copied file will behave the same as the main file;
;; the only notable exception to this is those features which depend on the
;; current working directory (dir-local variables, for example).

;; `sisyphus-make-related-file' provides a simple method for doing this. For
;; example, this form will return exactly the contents of ~my-test-file.el~, even
;; if that file is current open in the current Emacs (even if the buffer has not
;; been saved). Likewise, a test opening this file could be run in a batch Emacs
;; without interfering with an running interactive Emacs.

;; #+begin_src elisp
;;   (sisyphus-as-temp-buffer
;;       (sisyphus-make-related-file "dev-resources/my-test-file.el")
;;     (buffer-substring))
;; #+end_src

;; We also add support for opening a file, as if it where opened interactively,
;; with all the appropriate hooks being run, in the form of the
;; `sisyphus-with-find-file' macro. Combined with `sisyphus-make-related-file',
;; we can write the following expression without removing our ~.emacs~.

;; #+begin_src elisp
;;   (sisyphus-with-find-file
;;       (sisyphus-make-related-file "~/.emacs")
;;     (erase-buffer)
;;     (save-buffer))
;; #+end_src

;; #+RESULTS:

;; *** Implementation

;; All of the functions here support the file type introduced earlier, but
;; interpret raw strings as a file also.

;; #+begin_src emacs-lisp
(defun sisyphus--make-related-file-1 (file &optional directory)
  (make-temp-file
   (concat
    (or directory
        temporary-file-directory)
    (file-name-nondirectory file))
   nil
   (concat "."
           (file-name-extension file))))

(defun sisyphus-make-related-file (file &optional directory)
  "Open a copy of FILE in DIRECTORY.

FILE is copied to a temporary file in DIRECTORY or
`temporary-file-directory'. The copy has a unique name but shares
the same file extension.

This is useful for making test changes to FILE without actually
altering it."
  (let* ((file (sisyphus-to-file-name file))
         (related-file
          (sisyphus--make-related-file-1 file directory)))
    (copy-file file related-file t)
    (sisyphus-file
     related-file)))

(defmacro sisyphus-with-find-file (file &rest body)
  "Open FILE and evaluate BODY in resultant buffer.

FILE is opened with `find-file-noselect' so all the normal hooks
for file opening should occur. The buffer is killed after the
macro exits, unless it was already open. This happens
unconditionally, even if the buffer has changed.

See also `sisyphus-make-related-file'."
  (declare (debug t) (indent 1))
  (let ((temp-buffer (make-symbol "temp-buffer"))
        (file-has-buffer-p (make-symbol "file-has-buffer-p"))
        (file-s (make-symbol "file")))
    `(let* ((,file-s ,file)
            (,file-s (sisyphus-to-file-name ,file-s))
            (,file-has-buffer-p
             (find-buffer-visiting ,file-s))
            (,temp-buffer))
       (unwind-protect
           (with-current-buffer
               (setq ,temp-buffer
                     (find-file-noselect ,file-s))
             ,@body)
         (when
          ;; kill the buffer unless it was already open.
             (and (not ,file-has-buffer-p)
                  (buffer-live-p ,temp-buffer))
           ;; kill unconditionally
           (with-current-buffer ,temp-buffer
             (set-buffer-modified-p nil))
           (kill-buffer ,temp-buffer))))))
;; #+end_src

;; ** Indentation functions

;; There are two main ways to test indentation -- we can either take unindented
;; text, indent it, and then compare it to something else; or, we can roundtrip
;; -- take indented code, unindent it, re-indent it again and see whether we end
;; up with what we started. Sisyphus supports both of these.

;; Additionally, there are two different ways to specific a mode -- we can either
;; define it explicitly or, if we are opening from a file, we can use the normal
;; `auto-mode-alist' functionality to determine the mode. Sisyphus supports both
;; of these also.

;; The simplest function is `sisyphus-indentation=' which we can use as follows.
;; In this case, we have mixed a multi-line string and a single line with
;; control-n characters; this is partly to show that we can, and partly to make
;; sure that the code works both in an `org-mode' buffer and an ~*Org Src*~ buffer.

;; #+begin_src elisp
;;   (sisyphus-indentation=
;;    'emacs-lisp-mode
;;    "(sisyphus-with-find-file
;;   \"~/.emacs\"
;;   (buffer-string))"
;;    "(sisyphus-with-find-file\n    \"~/.emacs\"\n  (buffer-string))")
;; #+end_src

;; #+RESULTS:
;; : t

;; Probably more useful is `sisyphus-roundtrip-indentation=' which allows us to
;; just specify the indented form; in this case, the string is first unindented
;; (every line starts at the first position) and then reindented. This saves the
;; effort of keeping the text in both the indented and unindent forms in sync
;; (but without the indentation).

;; #+begin_src elisp
;;   (sisyphus-roundtrip-indentation=
;;    'emacs-lisp-mode
;;    "(sisyphus-with-find-file\n    \"~/.emacs\"\n  (buffer-string))")
;; #+end_src

;; #+RESULTS:
;; : t

;; While these are useful for simple forms of indentation checking, they have
;; the significant problem of writing indented code inside an Emacs string. An
;; easier solution for longer pieces of code is to use
;; `sisyphus-file-roundtrip-indentation='. This opens a file (safely using
;; `sisyphus-make-related-file'), unindents, and reindents. The mode must be set
;; up automatically by the file type.

;; #+begin_src elisp
;;   (sisyphus-file-roundtrip-indentation=
;;     "sisyphus.el")
;; #+end_src

;; #+RESULTS:

;; All of these methods are fully supported with ert explainer functions -- as
;; before they use diff where possible to compare the two forms.


;; *** Implementation

;; We start with some functionality for making Emacs quiet while indenting,
;; otherwise we will get a large amount of spam on the command line. Emacs needs
;; to have a better technique for shutting up `message'.

;; #+begin_src emacs-lisp
(defun sisyphus--indent-buffer (&optional column)
  (cond
   (column
    (indent-region (point-min) (point-max) column))
   ;; if indent-region-function is set, use it, and hope that it is not
   ;; noisy.
   (indent-region-function
    (funcall indent-region-function (point-min) (point-max)))
   (t
    (-map
     (lambda (m)
       (goto-char m)
       (indent-according-to-mode))
     (m-buffer-match-line-start (current-buffer))))))

(defun sisyphus--indent-in-mode (mode unindented)
  (with-temp-buffer
    (insert
     (sisyphus-to-string unindented))
    (funcall mode)
    (sisyphus--indent-buffer)
    (buffer-string)))
;; #+end_src

;; Now for the basic indentation= comparison.

;; #+begin_src emacs-lisp
(defun sisyphus-indentation= (mode unindented indented)
  "Return non-nil if UNINDENTED indents in MODE to INDENTED.
Both UNINDENTED and INDENTED can be any value usable by
`sisyphus-to-string'. Indentation is performed using
`indent-region', which MODE should set up appropriately.

See also `sisyphus-file-roundtrip-indentation=' for an
alternative mechanism."
  (sisyphus=
   (sisyphus--indent-in-mode
    mode
    unindented)
   indented))

(defun sisyphus-explain-indentation= (mode unindented indented)
  "Explanation function for `sisyphus-indentation='."
  (sisyphus-explain=
   (sisyphus--indent-in-mode
    mode
    unindented)
   indented))

(put 'sisyphus-indentation= 'ert-explainer 'sisyphus-explain-indentation=)
;; #+end_src

;; Roundtripping.

;; #+begin_src emacs-lisp
(defun sisyphus--buffer-unindent (buffer)
  (with-current-buffer
      buffer
    (sisyphus--indent-buffer 0)))

(defun sisyphus--roundtrip-1 (comp mode indented)
  (with-temp-buffer
    (funcall comp
             mode
             (progn
               (insert
                (sisyphus-to-string indented))
               (sisyphus--buffer-unindent (current-buffer))
               (buffer-string))
             indented)))

(defun sisyphus-roundtrip-indentation= (mode indented)
  "Return t if in MODE, text in INDENTED is corrected indented.

This is checked by unindenting the text, then reindenting it according
to MODE.

See also `sisyphus-indentation=' and
`sisyphus-file-roundtrip-indentation=' for alternative
mechanisms of checking indentation."
  (sisyphus--roundtrip-1
   #'sisyphus-indentation=
   mode indented))

(defun sisyphus-explain-roundtrip-indentation= (mode indented)
  "Explanation function for `sisyphus-roundtrip-indentation='."
  (sisyphus--roundtrip-1
   #'sisyphus-explain-indentation=
   mode indented))

(put 'sisyphus-roundtrip-indentation=
     'ert-explainer
     'sisyphus-explain-roundtrip-indentation=)
;; #+end_src

;; And file based checking.

;; #+begin_src emacs-lisp
(defun sisyphus--file-roundtrip-1 (comp file)
  (funcall
   comp
   (sisyphus-with-find-file
       (sisyphus-make-related-file file)
     (sisyphus--buffer-unindent (current-buffer))
     (sisyphus--indent-buffer)
     (buffer-string))
   file))

(defun sisyphus-file-roundtrip-indentation= (file)
  "Return t if text in FILE is indented correctly.

FILE is copied with `sisyphus-make-related-file', so this
function should be side-effect free whether or not FILE is
already open. The file is opened with `find-file-noselect', so
hooks associated with interactive visiting of a file should all
be called, with the exception of directory local variables, as
the copy of FILE will be in a different directory."
  (sisyphus--file-roundtrip-1
   #'sisyphus= file))

(defun sisyphus-explain-file-roundtrip-indentation= (file)
  "Explanation function for `sisyphus-file-roundtrip-indentation=."
  (sisyphus--file-roundtrip-1
   #'sisyphus-explain= file))

(put 'sisyphus-file-roundtrip-indentation=
     'ert-explainer
     'sisyphus-explain-file-roundtrip-indentation=)
;; #+end_src

;; ** Font-Lock

;; Set up a buffer from string or file, font-lock it, test it.

;; We need to define some functionality for testing font-lock.

;; API below -- so we can define functionality that works generally over a list,
;; and automatically coerce an item to a list.


;; #+begin_src elisp
;;    (sisyphus-face-at=
;;     "(defun x ())"
;;     'emacs-lisp-mode
;;     2
;;     'font-lock-keyword-face)

;;    (sisyphus-face-at=
;;     "(defun x ())
;; (defun y ())
;; (defun z ())"
;;     'emacs-lisp-mode
;;     '(2 15 28)
;;     'font-lock-keyword-face)

;;    (sisyphus-face-at=
;;     "(defun x ())"
;;     'emacs-lisp-mode
;;     '(2 8)
;;     '(font-lock-keyword-face font-lock-function-name-face))


;;    (sisyphus-face-at=
;;     "(defun x ())\n(defun y ())\n(defun z ())"
;;     'emacs-lisp-mode
;;     (lambda(buf)
;;       (m-buffer-match buf "defun"))
;;     'font-lock-keyword-face)
;; #+end_src


;; #+begin_src emacs-lisp
(defun sisyphus--face-at-location=
    (location face property throw-on-nil)
  ;; it's match data
  (if (listp location)
      ;; We need to test every point but not the last because the match is
      ;; passed the end.
      (let ((all nil))
        (cl-loop for i from
                 (marker-position (car location))
                 below
                 (marker-position (cadr location))
                 do
                 (setq all
                       (cons (sisyphus--face-at-location=
                              i face
                              property throw-on-nil)
                             all)))
        (-every? #'identity all))
    (let* ((local-faces
            (get-text-property location property))
           (rtn
            ;; for face this can be one of -- a face name (a symbol or string)
            ;; a list of faces, or a plist of face attributes
            (pcase local-faces
              ;; compare directly
              ((pred symbolp)
               (eq face local-faces))
              ;; give up -- we should probably be able to compare the plists here.
              ((and `(,s . ,_)
                    (guard (keywordp s)))
               nil)
              ;; compare that we have at least this.
              ((and `(,s . ,_)
                    (guard (symbolp s)))
               (member face s)))))
      (if (and throw-on-nil
               (not rtn))
          (throw
           'face-non-match
           (format "Face does not match expected value
\tExpected: %s
\tActual: %s
\tLocation: %s
\tLine Context: %s
\tbol Position: %s
"
                   face local-faces location
                   (thing-at-point 'line)
                   (m-buffer-at-line-beginning-position
                    (current-buffer) location)))
        rtn))))


(defun sisyphus--face-at=
    (buffer locations faces property throw-on-nil)
  (let* (
         ;; default property
         (property (or property 'face))
         ;; make sure we have a list of locations
         (locations
          (pcase locations
            ((pred functionp)
             (funcall locations buffer))
            ((pred listp)
             locations)
            (_ (list locations))))
         (first-location
          (car locations))
         ;; make sure we have a list of markers
         (locations
          (cond
           ((integerp first-location)
            (m-buffer-pos-to-marker buffer locations))
           ((stringp first-location)
            ;; this function does not exist yet -- should find the first
            ;; occurance of exactly the first string, then the first
            ;; occurrence of the next and so on
            (m-buffer-find-string buffer locations))
           ;; markers
           ((markerp first-location)
            locations)
           ;; match data
           ((and (listp first-location)
                 (markerp (car first-location)))
            locations)))
          ;; make sure we have a list of faces
          (faces
           (if (listp faces)
               faces
             (list faces)))
          ;; make sure faces is as long as locations
          (faces
           (if (> (length locations)
                  (length faces))
               (-cycle faces)
             faces)))
    (--every?
     (sisyphus--face-at-location=
      (car it) (cdr it) property throw-on-nil)
     (-zip-pair locations faces))))

(defun sisyphus--face-at=-1 (x mode locations faces property throw-on-nil)
  (with-temp-buffer
    (insert (sisyphus-to-string x))
    (funcall mode)
    (font-lock-fontify-buffer)
    ;; do not forget to remove this!
    (switch-to-buffer (current-buffer))
    (sisyphus--face-at= (current-buffer) locations faces property throw-on-nil)))

(defun sisyphus-face-at=
    (x mode locations faces &optional property)
  "Return non-nil if in X with MODE at MARKERS, FACES are present on PROPERTY.

This function tests if one or more faces are present at specific
locations in some text. It operates over single or multiple
values for both locations and faces; if there are more locations
than faces, then faces will be cycled over. If locations are
match data, then each the beginning and end of each match are
tested against each face.

X can be a buffer, file name or string -- see
`sisyphus-to-string' for details.

MODE is the major mode with which to fontify X -- actually, it
will just be a function called to initialize the buffer.

LOCATIONS can be either one or a list of the following things:
integer positions in X; markers in X (or nil!); match data in X;
or strings which match X. If this is a list, all items in list
should be of the same type.

FACES can be one or more faces.

PROPERTY is the text property on which to check the faces.

See also `sisyphus-to-string' for treatment of the parameter X.

See `sisyphus-file-face-at=' for a similar function which
operates over files and takes the mode from that file."
  (sisyphus--face-at=-1 x mode locations faces property nil))

(defun sisyphus-explain-face-at=
    (x mode locations faces &optional property)
  (catch 'face-non-match
    (sisyphus--face-at=-1 x mode locations faces property t)))

(put 'sisyphus-face-at=
     'ert-explainer
     'sisyphus-explain-face-at=)

(defun sisyphus--file-face-at=-1 (file locations faces property throw-on-nil)
  (sisyphus-with-find-file
      (sisyphus-make-related-file file)
    (font-lock-fontify-buffer)
    (sisyphus--face-at= (current-buffer) locations faces property throw-on-nil)))

(defun sisyphus-file-face-at= (file locations faces &optional property)
  (sisyphus--file-face-at=-1 file locations faces property nil))

(defun sisyphus-explain-file-face-at= (file locations faces &optional property)
  (catch 'face-non-match
    (sisyphus--file-face-at=-1 file locations faces property t)))

(put 'sisyphus-file-face-at=
     'ert-explainer
     'sisyphus-explain-file-face-at=)
;; #+end_src


;; #+begin_src emacs-lisp
(provide 'sisyphus)
;;; sisyphus.el ends here
;; #+end_src
