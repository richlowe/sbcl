;;;; various useful macros for generating RISC-V code

;;;; This software is part of the SBCL system. See the README file for
;;;; more information.
;;;;
;;;; This software is derived from the CMU CL system, which was
;;;; written at Carnegie Mellon University and released into the
;;;; public domain. The software is in the public domain and is
;;;; provided with absolutely no warranty. See the COPYING and CREDITS
;;;; files for more information.

(in-package "SB-VM")

;;; Instruction-like macros.

(defmacro move (dst src)
  "Move SRC into DST (unless they are location=."
  (once-only ((n-dst dst)
              (n-src src))
    `(unless (location= ,n-dst ,n-src)
       (inst addi ,n-dst ,n-src 0))))

(macrolet ((def-mem-op (op inst shift)
             `(defmacro ,op (object base &optional (offset 0) (lowtag 0))
                `(inst ,',inst ,object ,base (- (ash ,offset ,,shift) ,lowtag)))))
  (def-mem-op loadw #-64-bit lw #+64-bit ld word-shift)
  (def-mem-op storew #-64-bit sw #+64-bit sd word-shift))

(defmacro load-symbol (reg symbol)
  `(inst addi ,reg null-tn (static-symbol-offset ,symbol)))

(defmacro load-symbol-value (reg symbol)
  `(inst #-64-bit lw #+64-bit ld ,reg null-tn
         (+ (static-symbol-offset ',symbol)
            (ash symbol-value-slot word-shift)
            (- other-pointer-lowtag))))

(defmacro store-symbol-value (reg symbol)
  `(inst #-64-bit sw #+64-bit sd ,reg null-tn
         (+ (static-symbol-offset ',symbol)
            (ash symbol-value-slot word-shift)
            (- other-pointer-lowtag))))

(defun load-foreign-symbol-value (dest symbol temp)
  (let ((fixup (make-fixup symbol :foreign)))
    (inst lui temp fixup)
    (inst #-64-bit lw #+64-bit ld dest temp fixup)))

(defun store-foreign-symbol-value (src symbol temp)
  (let ((fixup (make-fixup symbol :foreign)))
    (inst lui temp fixup)
    (inst #-64-bit sw #+64-bit sd src temp fixup)))

(defmacro load-type (target source &optional (offset 0))
  "Loads the type bits of a pointer into target independent of
byte-ordering issues."
  `(inst lbu ,target ,source ,offset))

(defun lisp-jump (function)
  "Jump to the lisp function FUNCTION."
  (inst jalr zero-tn function (- (ash simple-fun-insts-offset word-shift)
                                 fun-pointer-lowtag)))

(defun lisp-return (return-pc return-style)
  "Return to RETURN-PC."
  (ecase return-style
    (:single-value (inst li nargs-tn -1))
    (:multiple-values)
    (:known))
  ;; Avoid the LRA header word.
  (inst jalr zero-tn return-pc (- n-word-bytes other-pointer-lowtag)))

(defun emit-return-pc (label)
  "Emit a return-pc header word.  LABEL is the label to use for this return-pc."
  (emit-alignment n-lowtag-bits)
  (emit-label label)
  (inst lra-header-word))


;;;; Three Way Comparison
(defun three-way-comparison (x y condition flavor not-p target)
  (ecase condition
    (:eq (if not-p
             (inst bne x y target)
             (inst beq x y target)))
    ((:lt :gt)
     (when (eq condition :gt)
       (rotatef x y))
     (ecase flavor
       (:unsigned (if not-p
                      (inst bgeu x y target)
                      (inst bltu x y target)))
       (:signed (if not-p
                    (inst bge x y target)
                    (inst blt x y target)))))))


(defun emit-error-break (vop kind code values)
  (assemble ()
    (when vop (note-this-location vop :internal-error))
    (inst ebreak)
    (if (= kind invalid-arg-count-trap) ; there is no "payload" in this trap kind
        (inst byte kind)
        (emit-internal-error kind code values))
    (emit-alignment 2)))

(defun generate-error-code (vop error-code &rest values)
  "Generate-Error-Code Error-code Value*
  Emit code for an error with the specified Error-Code and context Values."
  (assemble (:elsewhere)
    (let ((start-lab (gen-label)))
      (emit-label start-lab)
      (emit-error-break vop
                        (if (eq error-code 'invalid-arg-count-error)
                            invalid-arg-count-trap
                            error-trap)
                        (error-number-or-lose error-code) values)
      start-lab)))

;;;; PSEUDO-ATOMIC

;;; handy macro for making sequences look atomic
(defmacro pseudo-atomic ((flag-tn) &body forms)
  `(progn
     (without-scheduling ()
       (store-symbol-value csp-tn *pseudo-atomic-atomic*))
     (assemble ()
       ,@forms)
     (without-scheduling ()
       (store-symbol-value null-tn *pseudo-atomic-atomic*)
       (load-symbol-value ,flag-tn *pseudo-atomic-interrupted*)
       (let ((not-interrupted (gen-label)))
         (inst beq ,flag-tn zero-tn not-interrupted)
         (inst ebreak pending-interrupt-trap)
         (emit-alignment 2)
         (emit-label not-interrupted)))))

#|
If we are doing [reg+offset*n-word-bytes-lowtag+index*scale]
and

-2^11 ≤ offset*n-word-bytes - lowtag + index*scale < 2^11
-2^11 ≤ offset*n-word-bytes - lowtag + index*scale ≤ 2^11-1
-2^11 + lowtag -offset*n-word-bytes ≤ index*scale ≤ 2^11-1 + lowtag - offset*n-word-bytes
|#
(sb-xc:deftype load/store-index (scale lowtag offset)
  (let* ((encodable (list (- (ash 1 11)) (1- (ash 1 11))))
         (add-lowtag (mapcar (lambda (x) (+ x lowtag)) encodable))
         (sub-offset (mapcar (lambda (x) (- x (* offset n-word-bytes))) add-lowtag))
         (truncated (mapcar (lambda (x) (truncate x scale)) sub-offset)))
    `(integer ,(first truncated) ,(second truncated))))

(defmacro define-full-reffer (name type offset lowtag scs eltype &optional translate)
  `(progn
     (define-vop (,name)
       ,@(when translate `((:translate ,translate)))
       (:policy :fast-safe)
       (:args (object :scs (descriptor-reg))
              (index :scs (any-reg)))
       (:arg-types ,type tagged-num)
       (:temporary (:scs (interior-reg)) lip)
       ,@(unless (= word-shift n-fixnum-tag-bits)
           `((:temporary (:sc non-descriptor-reg) temp)))
       (:results (value :scs ,scs))
       (:result-types ,eltype)
       (:generator 5
         ,@(cond ((= word-shift n-fixnum-tag-bits)
                  `((inst add lip object index)))
                 (t
                  `((inst slli temp index ,(- word-shift n-fixnum-tag-bits))
                    (inst add lip object temp))))
         (loadw value lip ,offset ,lowtag)))
     (define-vop (,(symbolicate name "-C"))
       ,@(when translate `((:translate ,translate)))
       (:policy :fast-safe)
       (:args (object :scs (descriptor-reg)))
       (:info index)
       (:arg-types ,type
         (:constant (load/store-index #.n-word-bytes ,(eval lowtag) ,(eval offset))))
       (:results (value :scs ,scs))
       (:result-types ,eltype)
       (:generator 4
         (loadw value object (+ ,offset index) ,lowtag)))))

(defmacro define-full-setter (name type offset lowtag scs eltype &optional translate)
  `(progn
     (define-vop (,name)
       ,@(when translate `((:translate ,translate)))
       (:policy :fast-safe)
       (:args (object :scs (descriptor-reg))
              (index :scs (any-reg))
              (value :scs ,scs :target result))
       (:arg-types ,type tagged-num ,eltype)
       (:temporary (:scs (interior-reg)) lip)
       ,@(unless (= word-shift n-fixnum-tag-bits)
           `((:temporary (:sc non-descriptor-reg) temp)))
       (:results (result :scs ,scs))
       (:result-types ,eltype)
       (:generator 3
         ,@(cond ((= word-shift n-fixnum-tag-bits)
                  `((inst add lip object index)))
                 (t
                  `((inst slli temp index ,(- word-shift n-fixnum-tag-bits))
                    (inst add lip object temp))))
         (storew value lip ,offset ,lowtag)
         (move result value)))
     (define-vop (,(symbolicate name "-C"))
       ,@(when translate
           `((:translate ,translate)))
       (:policy :fast-safe)
       (:args (object :scs (descriptor-reg))
              (value :scs ,scs :target result))
       (:info index)
       (:arg-types ,type
         (:constant (load/store-index #.n-word-bytes ,(eval lowtag) ,(eval offset)))
         ,eltype)
       (:results (result :scs ,scs))
       (:result-types ,eltype)
       (:generator 1
         (storew value object (+ ,offset index) ,lowtag)
         (move result value)))))

(defmacro define-partial-reffer (name type size signed offset lowtag scs eltype &optional translate)
  (let ((shift (- (integer-length size) n-fixnum-tag-bits 1)))
    `(progn
       (define-vop (,name)
         ,@(when translate `((:translate ,translate)))
         (:policy :fast-safe)
         (:args (object :scs (descriptor-reg)) (index :scs (any-reg)))
         (:arg-types ,type positive-fixnum)
         (:temporary (:scs (interior-reg)) lip)
         ,@(unless (zerop shift)
             `((:temporary (:sc non-descriptor-reg) temp)))
         (:results (value :scs ,scs))
         (:result-types ,eltype)
         (:generator 5
           ,@(cond ((zerop shift)
                    `((inst add lip object index)))
                   (t
                    `(,(if (minusp shift)
                           `(inst srai temp index ,(- shift))
                           `(inst slli temp index ,shift))
                      (inst add lip object temp))))
           (inst ,(ecase size
                    (1 (if signed 'lb 'lbu))
                    (2 (if signed 'lh 'lhu))
                    (4 (if signed 'lw 'lwu)))
                 value lip (- (* ,offset n-word-bytes) ,lowtag))))
       (define-vop (,(symbolicate name "-C"))
         ,@(when translate
             `((:translate ,translate)))
         (:policy :fast-safe)
         (:args (object :scs (descriptor-reg)))
         (:info index)
         (:arg-types ,type
           (:constant (load/store-index ,(eval size) ,(eval lowtag) ,(eval offset))))
         (:results (value :scs ,scs))
         (:result-types ,eltype)
         (:generator 4
           (inst ,(ecase size
                    (1 (if signed 'lb 'lbu))
                    (2 (if signed 'lh 'lhu))
                    (4 (if signed 'lw 'lwu)))
                 value object
                 (- (+ (* ,offset n-word-bytes) (* index ,size)) ,lowtag)))))))

(defmacro define-partial-setter (name type size offset lowtag scs eltype &optional translate)
  (let ((shift (- (integer-length size) n-fixnum-tag-bits 1)))
    `(progn
       (define-vop (,name)
         ,@(when translate `((:translate ,translate)))
         (:policy :fast-safe)
         (:args (object :scs (descriptor-reg))
                (index :scs (any-reg))
                (value :scs ,scs))
         (:arg-types ,type positive-fixnum ,eltype)
         (:results (result :scs ,scs))
         (:temporary (:scs (interior-reg)) lip)
         ,@(unless (zerop shift)
             `((:temporary (:sc non-descriptor-reg) temp)))
         (:result-types ,eltype)
         (:generator 5
           ,@(cond ((zerop shift)
                    '((inst add lip object index)))
                   (t
                    `(,(if (minusp shift)
                           `(inst srai temp index ,(- shift))
                           `(inst slli temp index ,shift))
                      (inst add lip object temp))))
           (inst ,(ecase size (1 'sb) (2 'sh) (4 'sw))
                 value lip (- (* ,offset n-word-bytes) ,lowtag))
           (move result value)))
       (define-vop (,(symbolicate name "-C"))
         ,@(when translate
             `((:translate ,translate)))
         (:policy :fast-safe)
         (:args (object :scs (descriptor-reg))
                (value :scs ,scs :target result))
         (:info index)
         (:arg-types ,type
           (:constant (load/store-index ,(eval size) ,(eval lowtag) ,(eval offset)))
           ,eltype)
         (:results (result :scs ,scs))
         (:result-types ,eltype)
         (:generator 4
           (inst ,(ecase size (1 'sb) (2 'sh) (4 'sw))
                 value object
                 (- (+ (* ,offset n-word-bytes) (* index ,size)) ,lowtag))
           (move result value))))))

(defmacro define-float-reffer (name type size format offset lowtag scs eltype &optional arrayp note translate)
  (let ((shift (if arrayp
                   (- (integer-length size) n-fixnum-tag-bits 1)
                   (- word-shift n-fixnum-tag-bits))))
    `(progn
       (define-vop (,name)
         (:note ,note)
         ,@(when translate `((:translate ,translate)))
         (:policy :fast-safe)
         (:args (object :scs (descriptor-reg))
                (index :scs (any-reg)))
         (:arg-types ,type tagged-num)
         (:temporary (:scs (interior-reg)) lip)
         ,@(unless (zerop shift)
             `((:temporary (:sc non-descriptor-reg) temp)))
         (:results (value :scs ,scs))
         (:result-types ,eltype)
         (:generator 5
           ,@(cond ((zerop shift)
                    `((inst add lip object index)))
                   (t
                    `((inst slli temp index ,shift)
                      (inst add lip object temp))))
           (inst fload ,format value lip (- (* ,offset n-word-bytes) ,lowtag))))
       (define-vop (,(symbolicate name "-C"))
         (:note ,note)
         ,@(when translate `((:translate ,translate)))
         (:policy :fast-safe)
         (:args (object :scs (descriptor-reg)))
         (:info index)
         (:arg-types ,type
           (:constant (load/store-index ,(if arrayp size n-word-bytes) ,(eval lowtag) ,(eval offset))))
         (:results (value :scs ,scs))
         (:result-types ,eltype)
         (:generator 4
           (inst fload ,format value object (- (+ (* ,offset n-word-bytes) (* (* index ,(if arrayp size n-word-bytes)))) ,lowtag)))))))

(defmacro define-float-setter (name type size format offset lowtag scs eltype &optional arrayp note translate)
  (let ((shift (if arrayp
                   (- (integer-length size) n-fixnum-tag-bits 1)
                   (- word-shift n-fixnum-tag-bits))))
    `(progn
       (define-vop (,name)
         (:note ,note)
         ,@(when translate `((:translate ,translate)))
         (:policy :fast-safe)
         (:args (object :scs (descriptor-reg))
                (index :scs (any-reg))
                (value :scs ,scs :target result))
         (:arg-types ,type tagged-num ,eltype)
         (:temporary (:scs (interior-reg)) lip)
         ,@(unless (zerop shift)
             `((:temporary (:sc non-descriptor-reg) temp)))
         (:results (result :scs ,scs))
         (:result-types ,eltype)
         (:generator 5
           ,@(cond ((zerop shift)
                    `((inst add lip object index)))
                   (t
                    `((inst slli temp index ,shift)
                      (inst add lip object temp))))
           (inst fstore ,format value lip (- (* ,offset n-word-bytes) ,lowtag))
           (unless (location= result value)
             (inst fmove ,format result value))))
       (define-vop (,(symbolicate name "-C"))
         (:note ,note)
         ,@(when translate `((:translate ,translate)))
         (:policy :fast-safe)
         (:args (object :scs (descriptor-reg))
                (value :scs ,scs :target result))
         (:info index)
         (:arg-types ,type
           (:constant (load/store-index ,(if arrayp size n-word-bytes) ,(eval lowtag) ,(eval offset)))
           ,eltype)
         (:results (result :scs ,scs))
         (:result-types ,eltype)
         (:generator 4
           (inst fstore ,format value object (- (+ (* ,offset n-word-bytes) (* index ,(if arrayp size n-word-bytes))) ,lowtag))
           (unless (location= result value)
             (inst fmove ,format result value)))))))

;; FIXME: constant arg VOPs missing.
(defmacro define-complex-float-reffer (name type size format offset lowtag scs eltype &optional arrayp note translate)
  (let ((shift (if arrayp
                   (- (integer-length size) n-fixnum-tag-bits)
                   (- word-shift n-fixnum-tag-bits))))
    `(define-vop (,name)
       (:note ,note)
       ,@(when translate `((:translate ,translate)))
       (:policy :fast-safe)
       (:args (object :scs (descriptor-reg))
              (index :scs (any-reg)))
       (:arg-types ,type tagged-num)
       (:temporary (:scs (interior-reg)) lip)
       ,@(unless (zerop shift)
           `((:temporary (:sc non-descriptor-reg) temp)))
       (:results (value :scs ,scs))
       (:result-types ,eltype)
       (:generator 6
         ,@(cond ((zerop shift)
                  `((inst add lip object index)))
                 (t
                  `((inst slli temp index ,shift)
                    (inst add lip object temp))))
         ,(ecase format
            #+64-bit
            (:single
             `(inst fload :double value lip (- (* ,offset n-word-bytes) ,lowtag)))
            ((#-64-bit :single :double)
             `(progn
                (let ((real-tn (complex-reg-real-tn ,format value)))
                  (inst fload ,format real-tn lip (- (* ,offset n-word-bytes) ,lowtag)))
                (let ((imag-tn (complex-reg-imag-tn ,format value)))
                  (inst fload ,format imag-tn lip (- (+ (* ,offset n-word-bytes) ,size) ,lowtag))))))))))

(defmacro define-complex-float-setter (name type size format offset lowtag scs eltype &optional arrayp note translate)
  (let ((shift (if arrayp
                   (- (integer-length size) n-fixnum-tag-bits)
                   (- word-shift n-fixnum-tag-bits))))
    `(define-vop (,name)
       (:note ,note)
       ,@(when translate `((:translate ,translate)))
       (:policy :fast-safe)
       (:args (object :scs (descriptor-reg))
              (index :scs (any-reg))
              (value :scs ,scs :target result))
       (:arg-types ,type tagged-num ,eltype)
       (:temporary (:scs (interior-reg)) lip)
       ,@(unless (zerop shift)
           `((:temporary (:sc non-descriptor-reg) temp)))
       (:results (result :scs ,scs))
       (:result-types ,eltype)
       (:generator 6
         ,@(cond ((zerop shift)
                  `((inst add lip object index)))
                 (t
                  `((inst slli temp index ,shift)
                    (inst add lip object temp))))
         ,(ecase format
            #+64-bit
            (:single
             `(inst fstore :double value lip (- (* ,offset n-word-bytes) ,lowtag)))
            ((#-64-bit :single :double)
             `(progn
                (let ((real-tn (complex-reg-real-tn ,format value)))
                  (inst fstore ,format real-tn lip (- (* ,offset n-word-bytes) ,lowtag)))
                (let ((imag-tn (complex-reg-imag-tn ,format value)))
                  (inst fstore ,format imag-tn lip (- (+ (* ,offset n-word-bytes) ,size) ,lowtag))))))
         (move-complex ,format result value)))))


;;;; Stack TN's

;;; Move a stack TN to a register and vice-versa.
(defmacro load-stack-tn (reg stack)
  `(let ((reg ,reg)
         (stack ,stack))
     (let ((offset (tn-offset stack)))
       (sc-case stack
         ((control-stack)
          (loadw reg cfp-tn offset))))))

(defmacro store-stack-tn (stack reg)
  `(let ((stack ,stack)
         (reg ,reg))
     (let ((offset (tn-offset stack)))
       (sc-case stack
         ((control-stack)
          (storew reg cfp-tn offset))))))

(defmacro maybe-load-stack-tn (reg reg-or-stack)
  "Move the TN Reg-Or-Stack into Reg if it isn't already there."
  (once-only ((n-reg reg)
              (n-stack reg-or-stack))
    `(sc-case ,n-reg
       ((any-reg descriptor-reg)
        (sc-case ,n-stack
          ((any-reg descriptor-reg)
           (move ,n-reg ,n-stack))
          ((control-stack)
           (loadw ,n-reg cfp-tn (tn-offset ,n-stack))))))))

(defun align-csp (temp)
  (let ((aligned (gen-label)))
    (inst andi temp csp-tn lowtag-mask)
    (inst beq temp zero-tn aligned)
    (inst addi csp-tn csp-tn n-word-bytes)
    (storew zero-tn csp-tn -1)
    (emit-label aligned)))


;;;; Storage allocation:

;;; This is the main mechanism for allocating memory in the lisp heap.
;;;
;;; The allocated space is stored in RESULT-TN with the lowtag LOWTAG
;;; applied.  The amount of space to be allocated is SIZE bytes (which
;;; must be a multiple of the lisp object size).
;;;
;;; Each platform seems to have its own slightly different way to do
;;; heap allocation, taking various different options as parameters.
;;; For RISC-V, we take the bare minimum parameters, RESULT-TN, SIZE,
;;; and LOWTAG, and we require a single temporary register called
;;; FLAG-TN to emphasize the parallelism with PSEUDO-ATOMIC (which
;;; must surround a call to ALLOCATION anyway), and to indicate that
;;; the P-A FLAG-TN is also acceptable here.

#+gencgc
(defun allocation-tramp (alloc-tn size back-label)
  (let ((size-tn (cond ((integerp size)
                        (inst li alloc-tn size)
                        alloc-tn)
                       (t size))))
    ;; Pass alloc-tn on the number stack.
    ;; Instead of allocating space here, we save some code size by
    ;; delegating the stack pointer frobbing to the assembly routine.
    (storew size-tn nsp-tn -1))
  (invoke-asm-routine 'alloc-tramp)
  (loadw alloc-tn nsp-tn -1)
  (inst j back-label))

(defun allocation (result-tn size lowtag &key flag-tn
                                              stack-allocate-p
                                              temp-tn)
  #-gencgc (declare (ignore temp-tn))
  (cond (stack-allocate-p
         ;; Stack allocation
         ;;
         ;; The control stack grows up, so round up CSP to a
         ;; multiple of the lispobj size.  Use that as the
         ;; allocation pointer.  Then add SIZE bytes to the
         ;; allocation and set CSP to that, so we have the desired
         ;; space.
         (align-csp flag-tn)
         (inst ori result-tn csp-tn lowtag)
         (etypecase size
           (short-immediate
            (inst addi csp-tn csp-tn size))
           (u+i-immediate
            (inst li flag-tn size)
            (inst add csp-tn csp-tn flag-tn))
           (tn
            (inst add csp-tn csp-tn size))))
        ;; Normal allocation to the heap.
        #-gencgc
        (t
         (load-symbol-value flag-tn *allocation-pointer*)
         (inst ori result-tn flag-tn lowtag)
         (etypecase size
           (short-immediate
            (inst addi flag-tn flag-tn size))
           (u+i-immediate
            (inst li flag-tn (- size lowtag))
            (inst add flag-tn flag-tn result-tn))
           (tn
            (inst add flag-tn flag-tn size)))
         (store-symbol-value flag-tn *allocation-pointer*))
        #+gencgc
        (t
         (let ((alloc (gen-label))
               (back-from-alloc (gen-label)))
           ;; FIXME: Can optimize this to direct lui hi + load lo?
           ;; Hit problems if the second struct member is past the
           ;; most positive lo offset. Need relaxation.
           (inst li flag-tn (make-fixup "gc_alloc_region" :foreign))
           (loadw result-tn flag-tn)
           (loadw flag-tn flag-tn 1)
           (etypecase size
             (short-immediate
              (inst addi result-tn result-tn size))
             (U+i-immediate
              (inst li temp-tn size)
              (inst add result-tn result-tn temp-tn))
             (tn
              (inst add result-tn result-tn size)))
           (inst blt flag-tn result-tn alloc)
           (store-foreign-symbol-value result-tn "gc_alloc_region" flag-tn)
           (etypecase size
             (short-immediate
              (inst subi result-tn result-tn size))
             (u+i-immediate
              (inst sub result-tn result-tn temp-tn))
             (tn
              (inst sub result-tn result-tn size)))
           (emit-label back-from-alloc)
           (when lowtag
             (inst ori result-tn result-tn lowtag))
           (assemble (:elsewhere)
             (emit-label alloc)
             (allocation-tramp result-tn size back-from-alloc))))))

(defmacro with-fixed-allocation ((result-tn flag-tn type-code size
                                  &key (lowtag other-pointer-lowtag)
                                       stack-allocate-p
                                       temp-tn)
                                 &body body)
  "Do stuff to allocate an other-pointer object of fixed Size with a single
  word header having the specified Type-Code.  The result is placed in
  Result-TN, and Temp-TN is a non-descriptor temp (which may be randomly used
  by the body.)  The body is placed inside the PSEUDO-ATOMIC, and presumably
  initializes the object."
  (once-only ((result-tn result-tn) (flag-tn flag-tn)
              (type-code type-code) (size size)
              (stack-allocate-p stack-allocate-p)
              (lowtag lowtag))
    `(pseudo-atomic (,flag-tn)
       (allocation ,result-tn (pad-data-block ,size) ,lowtag
                   :flag-tn ,flag-tn
                   :stack-allocate-p ,stack-allocate-p
                   ,@(when temp-tn `(:temp-tn ,temp-tn)))
       (when ,type-code
         (inst li ,flag-tn (+ (ash (1- ,size) n-widetag-bits) ,type-code))
         (storew ,flag-tn ,result-tn 0 ,lowtag))
       ,@body)))

(defun load-binding-stack-pointer (reg)
  (load-symbol-value reg *binding-stack-pointer*))

(defun store-binding-stack-pointer (reg)
  (store-symbol-value reg *binding-stack-pointer*))
