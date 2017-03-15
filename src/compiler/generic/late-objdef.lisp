;;;; late machine-independent aspects of the object representation

;;;; This software is part of the SBCL system. See the README file for
;;;; more information.
;;;;
;;;; This software is derived from the CMU CL system, which was
;;;; written at Carnegie Mellon University and released into the
;;;; public domain. The software is in the public domain and is
;;;; provided with absolutely no warranty. See the COPYING and CREDITS
;;;; files for more information.

(in-package "SB!VM")

(macrolet ((frob ()
             `(progn ,@*!late-primitive-object-forms*)))
  (frob))

#!+sb-thread
(dolist (slot (primitive-object-slots
               (find 'thread *primitive-objects* :key #'primitive-object-name)))
  (when (slot-special slot)
    (setf (info :variable :wired-tls (slot-special slot))
          (ash (slot-offset slot) word-shift))))

#!+gencgc
(defconstant large-object-size
  (* 4 (max *backend-page-bytes* gencgc-card-bytes
            gencgc-alloc-granularity)))


;;; Keep this (mostly) lined up with 'early-objdef' for sanity's sake!
#+sb-xc-host
(defparameter *scav/trans/size*
  `((bignum "unboxed")
    (ratio "boxed")
    (single-float ,(or #!+64-bit "immediate" "unboxed"))
    (double-float "unboxed")
    (complex "boxed")
    (complex-single-float "unboxed")
    (complex-double-float "unboxed")

    (code-header "code_header")
    ;; The scavenge function for fun-header is basically "lose",
    ;; but it's only defined on non-x86 platforms for some reason.
    (simple-fun-header ,(or #!+(or x86 x86-64) "lose" "fun_header") "fun_header" "lose")
    (closure-header ,(or #!+(or x86 x86-64) "closure_header" "boxed")
                    "short_boxed")
    (funcallable-instance-header ,(or #!+compact-instance-header "funinstance" "boxed")
                                 "short_boxed")
    ;; These have a scav and trans function, but no size function.
    #!-(or x86 x86-64) (return-pc-header "return_pc_header" "return_pc_header" "lose")

    (value-cell-header "boxed")
    (symbol-header "boxed" "tiny_boxed")
    (character "immediate")
    (sap "unboxed")
    (unbound-marker "immediate")
    (weak-pointer "lose" "weak_pointer")
    (instance-header "instance")
    (fdefn ,(or #!+(or sparc arm) "boxed" "fdefn") "tiny_boxed")

    (no-tls-value-marker "immediate")

    #!+sb-simd-pack (simd-pack "unboxed")

    (simple-array "boxed")
    (simple-array-unsigned-byte-2 "vector_unsigned_byte_2")
    (simple-array-unsigned-byte-4 "vector_unsigned_byte_4")
    (simple-array-unsigned-byte-7 "vector_unsigned_byte_8")
    (simple-array-unsigned-byte-8 "vector_unsigned_byte_8")
    (simple-array-unsigned-byte-15 "vector_unsigned_byte_16")
    (simple-array-unsigned-byte-16 "vector_unsigned_byte_16")
    (simple-array-unsigned-fixnum #!-64-bit "vector_unsigned_byte_32"
                                  #!+64-bit "vector_unsigned_byte_64")
    (simple-array-unsigned-byte-31 "vector_unsigned_byte_32")
    (simple-array-unsigned-byte-32 "vector_unsigned_byte_32")
    #!+64-bit (simple-array-unsigned-byte-63 "vector_unsigned_byte_64")
    #!+64-bit (simple-array-unsigned-byte-64 "vector_unsigned_byte_64")

    (simple-array-signed-byte-8 "vector_unsigned_byte_8")
    (simple-array-signed-byte-16 "vector_unsigned_byte_16")
    (simple-array-signed-byte-32 "vector_unsigned_byte_32")
    (simple-array-fixnum #!-64-bit "vector_unsigned_byte_32"
                         #!+64-bit "vector_unsigned_byte_64")
    #!+64-bit (simple-array-signed-byte-64 "vector_unsigned_byte_64")

    (simple-array-single-float "vector_unsigned_byte_32")
    (simple-array-double-float "vector_unsigned_byte_64")
    (simple-array-complex-single-float "vector_unsigned_byte_64")
    (simple-array-complex-double-float "vector_unsigned_byte_128")

    (simple-bit-vector "vector_bit")
    (simple-vector "vector")

    (simple-array-nil "vector_nil")
    (simple-base-string "base_string")
    #!+sb-unicode (simple-character-string "character_string")
    #!+sb-unicode (complex-character-string "boxed")
    (complex-base-string "boxed")
    (complex-vector-nil "boxed")

    (complex-bit-vector "boxed")
    (complex-vector "boxed")
    (complex-array "boxed")))

#+sb-xc-host
(defun write-gc-tables (stream)
  (let ((scavtab  (make-array 256 :initial-element nil))
        (transtab (make-array 256 :initial-element nil))
        (sizetab  (make-array 256 :initial-element nil)))
    (dotimes (i 256)
      (cond ((eql 0 (logand i fixnum-tag-mask))
             (setf (svref scavtab i) "immediate" (svref sizetab i) "immediate"))
            (t
             (let ((pointer-kind (case (logand i lowtag-mask)
                                   (#.instance-pointer-lowtag "instance")
                                   (#.list-pointer-lowtag     "list")
                                   (#.fun-pointer-lowtag      "fun")
                                   (#.other-pointer-lowtag    "other"))))
               (when pointer-kind
                 (setf (svref scavtab i) (format nil "~A_pointer" pointer-kind)
                       (svref sizetab i) "pointer"))))))
    (dolist (entry *scav/trans/size*)
      (destructuring-bind (prefix scav &optional (trans scav) (size trans)) entry
        (let ((widetag (symbol-value (find-symbol (format nil "~A-WIDETAG" prefix)
                                                  'sb!vm))))
          (setf (svref scavtab widetag) scav
                (svref transtab widetag) trans
                (svref sizetab widetag) size))))
    (flet ((write-table (decl prefix contents)
             (format stream "~A = {" decl)
             (loop for i from 0 for x across contents
                   when (zerop (mod i 4))
                   do (format stream "~%  ")
                   do (format stream "~31@<~A~A~:[~;,~]~>"
                              prefix (or x "lose") (< i 256)))
             (format stream "~%};~%")))
      (write-table "sword_t (*scavtab[256])(lispobj *where, lispobj object)"
                   "scav_" scavtab)
      (write-table "lispobj (*transother[256])(lispobj object)"
                   "trans_" transtab)
      (write-table "sword_t (*sizetab[256])(lispobj *where)"
                   "size_" sizetab))))
