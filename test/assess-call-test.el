;;; assess-call-test.el --- Tests for assess-call.el -*- lexical-binding: t -*-

;;; Header:

;; The contents of this file are subject to the GPL License, Version 3.0.

;; Copyright (C) 2015, 2016, Phillip Lord, Newcastle University

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


;;; Code:

;; ** Requires

;; #+begin_src emacs-lisp
(require 'ert)
(require 'assess-call)

(defun assess-call-return-car (&rest args)
  (car args))

(defun assess-call-call-return-car (&rest args)
  (apply #'assess-call-return-car args))

(ert-deftest call-capture ()
  (should
   (equal
    '(((10 11 12) . 10))
    (assess-call-capture
     'assess-call-return-car
     (lambda ()
       (assess-call-return-car 10 11 12))))))

(ert-deftest call-capture-deep ()
  (should
   (equal
    '(((20 21 22) . 20))
    (assess-call-capture
     'assess-call-return-car
     (lambda ()
       (assess-call-call-return-car 20 21 22))))))

(defun assess-call-capture-multiply (a b)
  (* a b))

(ert-deftest call-capture-twice ()
  (should
   (equal
    '(((3 4) . 12) ((1 2) . 2))
    (assess-call-capture
     'assess-call-capture-multiply
     (lambda ()
       (assess-call-capture-multiply 1 2)
       (assess-call-capture-multiply 3 4))))))

(defvar assess-call-test-hook nil)

(ert-deftest assess-call-test-hook-test ()
 (should
  (equal
   '(nil)
   (assess-call-capture-hook
    'assess-call-test-hook
    (lambda ()
      (run-hooks 'assess-call-test-hook)))))
 (should
  (equal
   '(nil nil)
   (assess-call-capture-hook
    'assess-call-test-hook
    (lambda ()
      (run-hooks 'assess-call-test-hook)
      (run-hooks 'assess-call-test-hook)))))
  (should
   (equal
    '((bob))
    (assess-call-capture-hook
     'assess-call-test-hook
     (lambda ()
       (run-hook-with-args 'assess-call-test-hook
                           'bob))))))

(provide 'assess-call-test)
