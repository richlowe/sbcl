;;;; support for threads in the target machine

;;;; This software is part of the SBCL system. See the README file for
;;;; more information.
;;;;
;;;; This software is derived from the CMU CL system, which was
;;;; written at Carnegie Mellon University and released into the
;;;; public domain. The software is in the public domain and is
;;;; provided with absolutely no warranty. See the COPYING and CREDITS
;;;; files for more information.

(in-package "SB-THREAD")

;;; CAS Lock
;;;
;;; Locks don't come any simpler -- or more lightweight than this. While
;;; this is probably a premature optimization for most users, we still
;;; need it internally for implementing condition variables outside Futex
;;; builds.

(defmacro with-cas-lock ((place) &body body)
  "Runs BODY with interrupts disabled and *CURRENT-THREAD* compare-and-swapped
into PLACE instead of NIL. PLACE must be a place acceptable to
COMPARE-AND-SWAP, and must initially hold NIL.

WITH-CAS-LOCK is suitable mostly when the critical section needing protection
is very small, and cost of allocating a separate lock object would be
prohibitive. While it is the most lightweight locking constructed offered by
SBCL, it is also the least scalable if the section is heavily contested or
long.

WITH-CAS-LOCK can be entered recursively."
  `(without-interrupts
     (%with-cas-lock (,place) ,@body)))

(defmacro %with-cas-lock ((place) &body body &environment env)
  (with-unique-names (owner self)
    (multiple-value-bind (vars vals old new cas-form read-form)
        (sb-ext:get-cas-expansion place env)
      `(let* (,@(mapcar #'list vars vals)
              (,owner (progn
                        (barrier (:read))
                        ,read-form))
              (,self *current-thread*)
              (,old nil)
              (,new ,self))
         (unwind-protect
              (progn
                (unless (eq ,owner ,self)
                  (loop until (loop repeat 100
                                    when (and (progn
                                                (barrier (:read))
                                                (not ,read-form))
                                              (not (setf ,owner ,cas-form)))
                                    return t
                                    else
                                    do (sb-ext:spin-loop-hint))
                        do (thread-yield)))
                ,@body)
           (unless (eq ,owner ,self)
             (let ((,old ,self)
                   (,new nil))
               (unless (eq ,old ,cas-form)
                 (bug "Failed to release CAS lock!")))))))))

;;; Conditions

(define-condition thread-error (error)
  ((thread :reader thread-error-thread :initarg :thread))
  (:documentation
   "Conditions of type THREAD-ERROR are signalled when thread operations fail.
The offending thread is initialized by the :THREAD initialization argument and
read by the function THREAD-ERROR-THREAD."))

(define-condition simple-thread-error (thread-error simple-condition)
  ())

(define-condition thread-deadlock (thread-error)
  ((cycle :initarg :cycle :reader thread-deadlock-cycle))
  (:report
   (lambda (condition stream)
     (let* ((*print-circle* t)
            (cycle (thread-deadlock-cycle condition))
            (start (caar cycle)))
       (format stream "Deadlock cycle detected:~%")
       (loop for part = (pop cycle)
             while part
             do (format stream "    ~S~%  waited for:~%    ~S~%  owned by:~%"
                        (car part)
                        (cdr part)))
       (format stream "    ~S~%" start)))))

(setf (documentation 'thread-error-thread 'function)
 "Return the offending thread that the THREAD-ERROR pertains to.")

(define-condition symbol-value-in-thread-error (cell-error thread-error)
  ((info :reader symbol-value-in-thread-error-info :initarg :info))
  (:report
   (lambda (condition stream)
     (destructuring-bind (op problem)
         (symbol-value-in-thread-error-info condition)
       (format stream "Cannot ~(~A~) value of ~S in ~S: ~S"
               op
               (cell-error-name condition)
               (thread-error-thread condition)
               (ecase problem
                 (:unbound-in-thread "the symbol is unbound in thread.")
                 (:no-tls-value "the symbol has no thread-local value.")
                 (:thread-dead "the thread has exited.")
                 (:invalid-tls-value "the thread-local value is not valid."))))))
  (:documentation
   "Signalled when SYMBOL-VALUE-IN-THREAD or its SETF version fails due to eg.
the symbol not having a thread-local value, or the target thread having
exited. The offending symbol can be accessed using CELL-ERROR-NAME, and the
offending thread using THREAD-ERROR-THREAD."))

(define-condition join-thread-error (thread-error)
  ((problem :initarg :problem :reader join-thread-problem))
  (:report (lambda (c s)
             (ecase (join-thread-problem c)
               (:abort
                (format s "Joining thread failed: thread ~A ~
                           did not return normally."
                        (thread-error-thread c)))
               (:timeout
                (format s "Joining thread timed out: thread ~A ~
                           did not exit in time."
                        (thread-error-thread c)))
               (:self-join
                (format s "In thread ~A, attempt to join the current ~
                           thread."
                        (thread-error-thread c))))))
  (:documentation
   "Signalled when joining a thread fails due to abnormal exit of the thread
to be joined. The offending thread can be accessed using
THREAD-ERROR-THREAD."))

(define-deprecated-function :late "1.0.29.17" join-thread-error-thread thread-error-thread
    (condition)
  (thread-error-thread condition))

(define-condition interrupt-thread-error (thread-error) ()
  (:report (lambda (c s)
             (format s "Interrupt thread failed: thread ~A has exited."
                     (thread-error-thread c))))
  (:documentation
   "Signalled when interrupting a thread fails because the thread has already
exited. The offending thread can be accessed using THREAD-ERROR-THREAD."))

(define-deprecated-function :late "1.0.29.17" interrupt-thread-error-thread thread-error-thread
    (condition)
  (thread-error-thread condition))

;;; Of the WITH-PINNED-OBJECTS in this file, not every single one is
;;; necessary because threads are only supported with the conservative
;;; gencgc and numbers on the stack (returned by GET-LISP-OBJ-ADDRESS)
;;; are treated as references.

(setf (documentation 'thread-name 'function)
 "Name of the thread. Can be assigned to using SETF. Thread names can be
arbitrary printable objects, and need not be unique.")

(defmethod print-object ((thread thread) stream)
  (print-unreadable-object (thread stream :type t :identity t)
    (let* ((cookie (list thread))
           (info (if (thread-alive-p thread)
                     :running
                     (multiple-value-list
                      (join-thread thread :default cookie))))
           (state (if (eq :running info)
                      (let* ((thing (progn
                                      (barrier (:read))
                                      (thread-waiting-for thread))))
                        (typecase thing
                          (cons
                           (list "waiting on:" (cdr thing)
                                 "timeout: " (car thing)))
                          (null
                           (list info))
                          (t
                           (list "waiting on:" thing))))
                      (if (eq cookie (car info))
                          (list :aborted)
                          :finished)))
           (values (when (eq :finished state)
                     info))
           (*print-level* 4))
      (format stream
              "~@[~S ~]~:[~{~I~A~^~2I~_ ~}~_~;~A~:[ no values~; values: ~:*~{~S~^, ~}~]~]"
              (thread-name thread)
              (eq :finished state)
              state
              values))))

(defun print-lock (lock name owner stream)
  (let ((*print-circle* t))
    (print-unreadable-object (lock stream :type t :identity (not name))
      (if owner
          (format stream "~@[~S ~]~2I~_owner: ~S" name owner)
          (format stream "~@[~S ~](free)" name)))))

(defmethod print-object ((mutex mutex) stream)
  (print-lock mutex (mutex-name mutex) (mutex-owner mutex) stream))

;; NB: ephemeral threads must terminate strictly before the test of NTHREADS>1
;; in DEINIT, i.e. this is not a promise that the thread will terminate
;; just-in-time for the final call out to save, but rather by an earlier time.
(defun thread-ephemeral-p (thread)
  "Return T if THREAD is `ephemeral', which indicates that this thread is
used by SBCL for internal purposes, and specifically that our runtime knows how
to terminate this thread cleanly prior to core file saving without signalling
an error in that case."
  (thread-%ephemeral-p thread))

;; A thread is eligible for gc iff it has finished and there are no
;; more references to it. This structure keeps a reference to
;; all running threads ordered by stack base address.
(sb-ext:define-load-time-global *all-threads* ())
(sb-ext:define-load-time-global *all-threads-lock* (make-mutex :name "all threads lock"))

(defvar *default-alloc-signal* nil)

(defmacro with-all-threads-lock (&body body)
  `(with-system-mutex (*all-threads-lock*)
     ,@body))

(defun list-all-threads ()
  "Return a list of the live threads. Note that the return value is
potentially stale even before the function returns, as new threads may be
created and old ones may exit at any time."
  ;; No lock needed, just an atomic read, since tree mutations can't happen.
  ;; Of course by the time we're done collecting nodes, the tree can have
  ;; been replaced by a different tree.
  (barrier (:read))
  (avltree-list *all-threads*))

;;; used by debug-int.lisp to access interrupt contexts

#-sb-thread
(progn
  (declaim (inline sb-vm::current-thread-offset-sap))
  (defun sb-vm::current-thread-offset-sap (n)
    (sap-ref-sap (alien-sap (extern-alien "all_threads" (* t)))
                 (* n sb-vm:n-word-bytes))))

(declaim (inline current-thread-sap))
(defun current-thread-sap ()
  #+sb-thread
  (sb-vm::current-thread-offset-sap sb-vm::thread-this-slot)
  #-sb-thread
  (int-sap 0))

(declaim (inline current-thread-os-thread))
(defun current-thread-os-thread ()
  #+sb-thread
  (sap-int (sb-vm::current-thread-offset-sap sb-vm::thread-os-thread-slot))
  #-sb-thread
  0)

(sb-ext:define-load-time-global *initial-thread* nil)
(sb-ext:define-load-time-global *make-thread-lock* nil)

(defun init-initial-thread ()
  (/show0 "Entering INIT-INITIAL-THREAD")
  ;;; FIXME: is it purposeful or accidental that we recreate some of
  ;;; the global mutexes but not *ALL-THREADS-LOCKS* ?
  (setf sb-impl::*exit-lock* (make-mutex :name "Exit Lock")
        *make-thread-lock* (make-mutex :name "Make-Thread Lock"))
  (let ((thread (%make-thread :name "main thread"
                              :%alive-p t)))
    (setf (thread-os-thread thread) (current-thread-os-thread)
          (thread-stack-end thread) (get-lisp-obj-address sb-vm:*control-stack-end*)
          (thread-primitive-thread thread) (sap-int (current-thread-sap))
          *initial-thread* thread
          *current-thread* thread)
    (grab-mutex (thread-result-lock *initial-thread*))
    ;; Either *all-threads* is empty or it contains exactly one thread
    ;; in case we are in reinit since saving core with multiple
    ;; threads doesn't work.
    (setq *all-threads*
          (avl-insert nil (get-lisp-obj-address sb-vm:*control-stack-start*) thread))))

(defun main-thread ()
  "Returns the main thread of the process."
  *initial-thread*)

(defun main-thread-p (&optional (thread *current-thread*))
  "True if THREAD, defaulting to current thread, is the main thread of the process."
  (eq thread *initial-thread*))

(defmacro return-from-thread (values-form &key allow-exit)
  "Unwinds from and terminates the current thread, with values from
VALUES-FORM as the results visible to JOIN-THREAD.

If current thread is the main thread of the process (see
MAIN-THREAD-P), signals an error unless ALLOW-EXIT is true, as
terminating the main thread would terminate the entire process. If
ALLOW-EXIT is true, returning from the main thread is equivalent to
calling SB-EXT:EXIT with :CODE 0 and :ABORT NIL.

See also: ABORT-THREAD and SB-EXT:EXIT."
  `(%return-from-thread (multiple-value-list ,values-form) ,allow-exit))

(defun %return-from-thread (values allow-exit)
  (let ((self *current-thread*))
    (cond ((main-thread-p self)
           (unless allow-exit
             (error 'simple-thread-error
                    :format-control "~@<Tried to return ~S as values from main thread, ~
                                     but exit was not allowed.~:@>"
                    :format-arguments (list values)
                    :thread self))
           (sb-ext:exit :code 0))
          (t
           (throw '%return-from-thread (values-list values))))))

(defun abort-thread (&key allow-exit)
  "Unwinds from and terminates the current thread abnormally, causing
JOIN-THREAD on current thread to signal an error unless a
default-value is provided.

If current thread is the main thread of the process (see
MAIN-THREAD-P), signals an error unless ALLOW-EXIT is true, as
terminating the main thread would terminate the entire process. If
ALLOW-EXIT is true, aborting the main thread is equivalent to calling
SB-EXT:EXIT code 1 and :ABORT NIL.

Invoking the initial ABORT restart established by MAKE-THREAD is
equivalent to calling ABORT-THREAD in other than main threads.
However, whereas ABORT restart may be rebound, ABORT-THREAD always
unwinds the entire thread. (Behaviour of the initial ABORT restart for
main thread depends on the :TOPLEVEL argument to
SB-EXT:SAVE-LISP-AND-DIE.)

See also: RETURN-FROM-THREAD and SB-EXT:EXIT."
  (let ((self *current-thread*))
    (cond ((main-thread-p self)
           (unless allow-exit
             (error 'simple-thread-error
                    :format-control "~@<Tried to abort initial thread, but ~
                                     exit was not allowed.~:@>"))
           (sb-ext:exit :code 1))
          (t
           ;; We /could/ use TOPLEVEL-CATCHER or %END-OF-THE-WORLD as well, but
           ;; this seems tidier. Those to are a bit too overloaded already.
           (throw '%abort-thread t)))))


;;;; Aliens, low level stuff

(define-alien-routine "kill_safely"
    int
  (os-thread #-alpha unsigned #+alpha unsigned-int)
  (signal int))

(define-alien-routine "wake_thread"
    int
  (os-thread unsigned))

#+sb-thread
(progn
  ;; FIXME it would be good to define what a thread id is or isn't
  ;; (our current assumption is that it's a fixnum).  It so happens
  ;; that on Linux it's a pid, but it might not be on posix thread
  ;; implementations.
  (define-alien-routine ("create_thread" %create-thread)
      unsigned (lisp-fun-address unsigned))

  (declaim (inline %block-deferrable-signals))
  (define-alien-routine ("block_deferrable_signals" %block-deferrable-signals)
      void
    (where unsigned)
    (old   unsigned))

  (defun block-deferrable-signals ()
    (%block-deferrable-signals 0 0))

  #+sb-futex
  (progn
    (declaim (inline futex-wait %futex-wait futex-wake))

    (define-alien-routine ("futex_wait" %futex-wait) int
      (word unsigned) (old-value unsigned)
      (to-sec long) (to-usec unsigned-long))

    (defun futex-wait (word old to-sec to-usec)
      (with-interrupts
        (%futex-wait word old to-sec to-usec)))

    (define-alien-routine "futex_wake"
        int (word unsigned) (n unsigned-long))))

(defmacro with-deadlocks ((thread lock &optional (timeout nil timeoutp)) &body forms)
  (with-unique-names (n-thread n-lock new n-timeout)
    `(let* ((,n-thread ,thread)
            (,n-lock ,lock)
            (,n-timeout ,(when timeoutp
                           `(or ,timeout sb-impl::*deadline*)))
            (,new (if ,n-timeout
                      ;; Using CONS tells the rest of the system there's a
                      ;; timeout in place, so it isn't considered a deadlock.
                      (cons ,n-timeout ,n-lock)
                      ,n-lock)))
       (declare (dynamic-extent ,new))
       ;; No WITHOUT-INTERRUPTS, since WITH-DEADLOCKS is used
       ;; in places where interrupts should already be disabled.
       (unwind-protect
            (progn
              (setf (thread-waiting-for ,n-thread) ,new)
              (barrier (:write))
              ,@forms)
         ;; Interrupt handlers and GC save and restore any
         ;; previous wait marks using WITHOUT-DEADLOCKS below.
         (setf (thread-waiting-for ,n-thread) nil)
         (barrier (:write))))))

;;;; Mutexes

(setf (documentation 'make-mutex 'function) "Create a mutex."
      (documentation 'mutex-name 'function) "The name of the mutex. Setfable.")

#+(and sb-thread sb-futex)
(progn
  (locally (declare (sb-ext:muffle-conditions sb-ext:compiler-note))
    (define-structure-slot-addressor mutex-state-address
        :structure mutex
        :slot state))
  ;; Important: current code assumes these are fixnums or other
  ;; lisp objects that don't need pinning.
  (defconstant +lock-free+ 0)
  (defconstant +lock-taken+ 1)
  (defconstant +lock-contested+ 2))

(defun mutex-owner (mutex)
  "Current owner of the mutex, NIL if the mutex is free. Naturally,
this is racy by design (another thread may acquire the mutex after
this function returns), it is intended for informative purposes. For
testing whether the current thread is holding a mutex see
HOLDING-MUTEX-P."
  ;; Make sure to get the current value.
  (sb-ext:compare-and-swap (mutex-%owner mutex) nil nil))

(sb-ext:define-load-time-global **deadlock-lock** nil)

#+(or (not sb-thread) sb-futex)
(defstruct (waitqueue (:copier nil) (:constructor make-waitqueue (&key name)))
  "Waitqueue type."
  (name nil :type (or null string))
  #+(and sb-thread sb-futex)
  (token nil))

#+(and sb-thread (not sb-futex))
(defstruct (waitqueue (:copier nil) (:constructor make-waitqueue (&key name)))
  "Waitqueue type."
  (name nil :type (or null string))
  ;; For WITH-CAS-LOCK: because CONDITION-WAIT must be able to call
  ;; %WAITQUEUE-WAKEUP without re-aquiring the mutex, we need a separate
  ;; lock. In most cases this should be uncontested thanks to the mutex --
  ;; the only case where that might not be true is when CONDITION-WAIT
  ;; unwinds and %WAITQUEUE-DROP is called.
  %owner
  %head
  %tail)

;;; Signals an error if owner of LOCK is waiting on a lock whose release
;;; depends on the current thread. Does not detect deadlocks from sempahores.
(defun check-deadlock ()
  (let* ((self *current-thread*)
         (origin (progn
                   (barrier (:read))
                   (thread-waiting-for self))))
    (labels ((detect-deadlock (lock)
               (let ((other-thread (mutex-%owner lock)))
                 (cond ((not other-thread))
                       ((eq self other-thread)
                        (let ((chain
                                (with-cas-lock ((symbol-value '**deadlock-lock**))
                                  (prog1 (deadlock-chain self origin)
                                    ;; We're now committed to signaling the
                                    ;; error and breaking the deadlock, so
                                    ;; mark us as no longer waiting on the
                                    ;; lock. This ensures that a single
                                    ;; deadlock is reported in only one
                                    ;; thread, and that we don't look like
                                    ;; we're waiting on the lock when print
                                    ;; stuff -- because that may lead to
                                    ;; further deadlock checking, in turn
                                    ;; possibly leading to a bogus vicious
                                    ;; metacycle on PRINT-OBJECT.
                                    (setf (thread-waiting-for self) nil)))))
                          (error 'thread-deadlock
                                 :thread *current-thread*
                                 :cycle chain)))
                       (t
                        (let ((other-lock (progn
                                            (barrier (:read))
                                            (thread-waiting-for other-thread))))
                          ;; If the thread is waiting with a timeout OTHER-LOCK
                          ;; is a cons, and we don't consider it a deadlock -- since
                          ;; it will time out on its own sooner or later.
                          (when (mutex-p other-lock)
                            (detect-deadlock other-lock)))))))
             (deadlock-chain (thread lock)
               (let* ((other-thread (mutex-owner lock))
                      (other-lock (when other-thread
                                    (barrier (:read))
                                    (thread-waiting-for other-thread))))
                 (cond ((not other-thread)
                        ;; The deadlock is gone -- maybe someone unwound
                        ;; from the same deadlock already?
                        (return-from check-deadlock nil))
                       ((consp other-lock)
                        ;; There's a timeout -- no deadlock.
                        (return-from check-deadlock nil))
                       ((waitqueue-p other-lock)
                        ;; Not a lock.
                        (return-from check-deadlock nil))
                       ((eq self other-thread)
                        ;; Done
                        (list (list thread lock)))
                       (t
                        (if other-lock
                            (cons (cons thread lock)
                                  (deadlock-chain other-thread other-lock))
                            ;; Again, the deadlock is gone?
                            (return-from check-deadlock nil)))))))
      ;; Timeout means there is no deadlock
      (when (mutex-p origin)
        (detect-deadlock origin)
        t))))

;;;; WAIT-FOR -- waiting on arbitrary conditions

(defun %%wait-for (test stop-sec stop-usec)
  (declare (function test))
  (declare (dynamic-extent test))
  (labels ((try ()
             (declare (optimize (safety 0)))
             (awhen (funcall test)
               (return-from %%wait-for it)))
           (tick (sec usec)
             (declare (type fixnum sec usec))
             ;; TICK is microseconds
             (+ usec (* 1000000 sec)))
           (get-tick ()
             (multiple-value-call #'tick
               (decode-internal-time (get-internal-real-time)))))
    (let* ((timeout-tick (when stop-sec (tick stop-sec stop-usec)))
           (start (get-tick))
           ;; Rough estimate of how long a single attempt takes.
           (try-ticks (progn
                        (try) (try) (try)
                        (max 1 (truncate (- (get-tick) start) 3)))))
      ;; Scale sleeping between attempts:
      ;;
      ;; Start by sleeping for as many ticks as an average attempt
      ;; takes, then doubling for each attempt.
      ;;
      ;; Max out at 0.1 seconds, or the 2 x time of a single try,
      ;; whichever is longer -- with a hard cap of 10 seconds.
      ;;
      ;; FIXME: Maybe the API should have a :MAX-SLEEP argument?
      (loop with max-ticks = (max 100000 (min (* 2 try-ticks)
                                              (expt 10 7)))
            for scale of-type fixnum = 1
            then (let ((x (logand sb-xc:most-positive-fixnum (* 2 scale))))
                   (if (> scale x)
                       sb-xc:most-positive-fixnum
                       x))
            do (try)
               (let* ((now (get-tick))
                      (sleep-ticks (min (* try-ticks scale) max-ticks))
                      (sleep
                        (if timeout-tick
                            ;; If sleep would take us past the
                            ;; timeout, shorten it so it's just
                            ;; right.
                            (if (>= (+ now sleep-ticks) timeout-tick)
                                (- timeout-tick now)
                                sleep-ticks)
                            sleep-ticks)))
                 (declare (type fixnum sleep))
                 (cond ((plusp sleep)
                        ;; microseconds to seconds and nanoseconds
                        (multiple-value-bind (sec nsec)
                            (truncate (* 1000 sleep) (expt 10 9))
                          (with-interrupts
                            (sb-unix:nanosleep sec nsec))))
                       (t
                        (return-from %%wait-for nil))))))))

(defun %wait-for (test timeout)
  (declare (function test))
  (declare (dynamic-extent test))
  (tagbody
   :restart
     (multiple-value-bind (to-sec to-usec stop-sec stop-usec deadlinep)
         (decode-timeout timeout)
       (declare (ignore to-sec to-usec))
       (return-from %wait-for
         (or (%%wait-for test stop-sec stop-usec)
             (when deadlinep
               (signal-deadline)
               (go :restart)))))))

(defmacro sb-ext:wait-for (test-form &key timeout)
  "Wait until TEST-FORM evaluates to true, then return its primary value.
If TIMEOUT is provided, waits at most approximately TIMEOUT seconds before
returning NIL.

If WITH-DEADLINE has been used to provide a global deadline, signals a
DEADLINE-TIMEOUT if TEST-FORM doesn't evaluate to true before the
deadline.

Experimental: subject to change without prior notice."
  `(dx-flet ((wait-for-test () (progn ,test-form)))
     (%wait-for #'wait-for-test ,timeout)))

(defmacro with-progressive-timeout ((name &key seconds)
                                    &body body)
  "Binds NAME as a local function for BODY. Each time #'NAME is called, it
returns SECONDS minus the time that has elapsed since BODY was entered, or
zero if more time than SECONDS has elapsed. If SECONDS is NIL, #'NAME
returns NIL each time."
  (with-unique-names (deadline time-left sec)
    `(let* ((,sec ,seconds)
            (,deadline
              (when ,sec
                (+ (get-internal-real-time)
                   (round (* ,seconds sb-xc:internal-time-units-per-second))))))
       (flet ((,name ()
                (when ,deadline
                  (let ((,time-left (- ,deadline (get-internal-real-time))))
                    (if (plusp ,time-left)
                        (* (coerce ,time-left 'single-float)
                           (sb-xc:/ $1.0f0 sb-xc:internal-time-units-per-second))
                        0)))))
         ,@body))))

(defun %try-mutex (mutex new-owner)
  (declare (type mutex mutex) (optimize (speed 3)))
  (barrier (:read))
  (let ((old (mutex-%owner mutex)))
    (when (eq new-owner old)
      (error "Recursive lock attempt ~S." mutex))
    #-sb-thread
    (when old
      (error "Strange deadlock on ~S in an unithreaded build?" mutex))
    #-(and sb-thread sb-futex)
    (and (not old)
         ;; Don't even bother to try to CAS if it looks bad.
         (not (sb-ext:compare-and-swap (mutex-%owner mutex) nil new-owner)))
    #+(and sb-thread sb-futex)
    ;; From the Mutex 2 algorithm from "Futexes are Tricky" by Ulrich Drepper.
    (when (eql +lock-free+ (sb-ext:compare-and-swap (mutex-state mutex)
                                                    +lock-free+
                                                    +lock-taken+))
      (let ((prev (sb-ext:compare-and-swap (mutex-%owner mutex) nil new-owner)))
        (when prev
          (bug "Old owner in free mutex: ~S" prev))
        t))))

#+sb-thread
(defun %%wait-for-mutex (mutex new-owner to-sec to-usec stop-sec stop-usec)
  (declare (type mutex mutex) (optimize (speed 3)))
  (declare (sb-ext:muffle-conditions sb-ext:compiler-note))
  #-sb-futex
  (declare (ignore to-sec to-usec))
  #-sb-futex
  (flet ((cas ()
           (loop repeat 100
                 when (and (progn
                             (barrier (:read))
                             (not (mutex-%owner mutex)))
                           (not (sb-ext:compare-and-swap (mutex-%owner mutex) nil
                                                         new-owner)))
                 do (return-from cas t)
                 else
                 do
                    (sb-ext:spin-loop-hint))
           ;; Check for pending interrupts.
           (with-interrupts nil)))
    (declare (dynamic-extent #'cas))
    (%%wait-for #'cas stop-sec stop-usec))
  #+sb-futex
  ;; This is a fairly direct translation of the Mutex 2 algorithm from
  ;; "Futexes are Tricky" by Ulrich Drepper.
  (flet ((maybe (old)
           (when (eql +lock-free+ old)
             (let ((prev (sb-ext:compare-and-swap (mutex-%owner mutex)
                                                  nil new-owner)))
               (when prev
                 (bug "Old owner in free mutex: ~S" prev))
               (return-from %%wait-for-mutex t)))))
    (prog ((old (sb-ext:compare-and-swap (mutex-state mutex)
                                         +lock-free+ +lock-taken+)))
       ;; Got it right off the bat?
       (maybe old)
     :retry
       ;; Mark it as contested, and sleep. (Exception: it was just released.)
       (when (or (eql +lock-contested+ old)
                 (not (eql +lock-free+
                           (sb-ext:compare-and-swap
                            (mutex-state mutex) +lock-taken+ +lock-contested+))))
         (when (eql 1 (with-pinned-objects (mutex)
                        (futex-wait (mutex-state-address mutex)
                                    (get-lisp-obj-address +lock-contested+)
                                    (or to-sec -1)
                                    (or to-usec 0))))
           ;; -1 = EWOULDBLOCK, possibly spurious wakeup
           ;;  0 = normal wakeup
           ;;  1 = ETIMEDOUT ***DONE***
           ;;  2 = EINTR, a spurious wakeup
           (return-from %%wait-for-mutex nil)))
       ;; Try to get it, still marking it as contested.
       (maybe
        (sb-ext:compare-and-swap (mutex-state mutex) +lock-free+ +lock-contested+))
       ;; Update timeout if necessary.
       (when stop-sec
         (setf (values to-sec to-usec)
               (sb-impl::relative-decoded-times stop-sec stop-usec)))
       ;; Spin.
       (go :retry))))

#+sb-thread
(defun %wait-for-mutex (mutex self timeout to-sec to-usec stop-sec stop-usec deadlinep)
  (declare (sb-ext:muffle-conditions sb-ext:compiler-note))
  (with-deadlocks (self mutex timeout)
    (with-interrupts (check-deadlock))
    (tagbody
     :again
       (return-from %wait-for-mutex
         (or (%%wait-for-mutex mutex self to-sec to-usec stop-sec stop-usec)
             (when deadlinep
               (signal-deadline)
               ;; FIXME: substract elapsed time from timeout...
               (setf (values to-sec to-usec stop-sec stop-usec deadlinep)
                     (decode-timeout timeout))
               (go :again)))))))

(define-deprecated-function :early "1.0.37.33" get-mutex (grab-mutex)
    (mutex &optional new-owner (waitp t) (timeout nil))
  (declare (ignorable waitp timeout))
  (let ((new-owner (or new-owner *current-thread*)))
    (or (%try-mutex mutex new-owner)
        #+sb-thread
        (when waitp
          (multiple-value-call #'%wait-for-mutex
            mutex new-owner timeout (decode-timeout timeout))))))

(defun grab-mutex (mutex &key (waitp t) (timeout nil))
  "Acquire MUTEX for the current thread. If WAITP is true (the default) and
the mutex is not immediately available, sleep until it is available.

If TIMEOUT is given, it specifies a relative timeout, in seconds, on how long
GRAB-MUTEX should try to acquire the lock in the contested case.

If GRAB-MUTEX returns T, the lock acquisition was successful. In case of WAITP
being NIL, or an expired TIMEOUT, GRAB-MUTEX may also return NIL which denotes
that GRAB-MUTEX did -not- acquire the lock.

Notes:

  - GRAB-MUTEX is not interrupt safe. The correct way to call it is:

      (WITHOUT-INTERRUPTS
        ...
        (ALLOW-WITH-INTERRUPTS (GRAB-MUTEX ...))
        ...)

    WITHOUT-INTERRUPTS is necessary to avoid an interrupt unwinding the call
    while the mutex is in an inconsistent state while ALLOW-WITH-INTERRUPTS
    allows the call to be interrupted from sleep.

  - (GRAB-MUTEX <mutex> :timeout 0.0) differs from
    (GRAB-MUTEX <mutex> :waitp nil) in that the former may signal a
    DEADLINE-TIMEOUT if the global deadline was due already on entering
    GRAB-MUTEX.

    The exact interplay of GRAB-MUTEX and deadlines are reserved to change in
    future versions.

  - It is recommended that you use WITH-MUTEX instead of calling GRAB-MUTEX
    directly.
"
  (declare (ignorable waitp timeout))
  (let ((self *current-thread*))
    (or (%try-mutex mutex self)
        #+sb-thread
        (when waitp
          (multiple-value-call #'%wait-for-mutex
            mutex self timeout (decode-timeout timeout))))))

(defun release-mutex (mutex &key (if-not-owner :punt))
  "Release MUTEX by setting it to NIL. Wake up threads waiting for
this mutex.

RELEASE-MUTEX is not interrupt safe: interrupts should be disabled
around calls to it.

If the current thread is not the owner of the mutex then it silently
returns without doing anything (if IF-NOT-OWNER is :PUNT), signals a
WARNING (if IF-NOT-OWNER is :WARN), or releases the mutex anyway (if
IF-NOT-OWNER is :FORCE)."
  (declare (type mutex mutex))
  ;; Order matters: set owner to NIL before releasing state.
  (let* ((self *current-thread*)
         (old-owner (sb-ext:compare-and-swap (mutex-%owner mutex) self nil)))
    (unless (eq self old-owner)
      (ecase if-not-owner
        ((:punt) (return-from release-mutex nil))
        ((:warn)
         (warn "Releasing ~S, owned by another thread: ~S" mutex old-owner))
        ((:force)))
      (setf (mutex-%owner mutex) nil)
      ;; FIXME: Is a :memory barrier too strong here?  Can we use a :write
      ;; barrier instead?
      (barrier (:memory)))
    #+(and sb-thread sb-futex)
    (when old-owner
      ;; FIXME: once ATOMIC-INCF supports struct slots with word sized
      ;; unsigned-byte type this can be used:
      ;;
      ;;     (let ((old (sb-ext:atomic-incf (mutex-state mutex) -1)))
      ;;       (unless (eql old +lock-free+)
      ;;         (setf (mutex-state mutex) +lock-free+)
      ;;         (with-pinned-objects (mutex)
      ;;           (futex-wake (mutex-state-address mutex) 1))))
      (let ((old (sb-ext:compare-and-swap (mutex-state mutex)
                                          +lock-taken+ +lock-free+)))
        (when (eql old +lock-contested+)
          (sb-ext:compare-and-swap (mutex-state mutex)
                                   +lock-contested+ +lock-free+)
          (with-pinned-objects (mutex)
            (futex-wake (mutex-state-address mutex) 1))))
      nil)))


;;;; Waitqueues/condition variables

#+(and sb-thread (not sb-futex))
(progn
  (defun %waitqueue-enqueue (thread queue)
    (setf (thread-waiting-for thread) queue)
    (let ((head (waitqueue-%head queue))
          (tail (waitqueue-%tail queue))
          (new (list thread)))
      (unless head
        (setf (waitqueue-%head queue) new))
      (when tail
        (setf (cdr tail) new))
      (setf (waitqueue-%tail queue) new)
      nil))
  (defun %waitqueue-drop (thread queue)
    (setf (thread-waiting-for thread) nil)
    (let ((head (waitqueue-%head queue)))
      (do ((list head (cdr list))
           (prev nil list))
          ((or (null list)
               (eq (car list) thread))
           (when list
             (let ((rest (cdr list)))
               (cond (prev
                      (setf (cdr prev) rest))
                     (t
                      (setf (waitqueue-%head queue) rest
                            prev rest)))
               (unless rest
                 (setf (waitqueue-%tail queue) prev)))))))
    nil)
  (defun %waitqueue-wakeup (queue n)
    (declare (fixnum n))
    (loop while (plusp n)
          for next = (let ((head (waitqueue-%head queue))
                           (tail (waitqueue-%tail queue)))
                       (when head
                         (if (eq head tail)
                             (setf (waitqueue-%head queue) nil
                                   (waitqueue-%tail queue) nil)
                             (setf (waitqueue-%head queue) (cdr head)))
                         (car head)))
          while next
          do (when (eq queue (sb-ext:compare-and-swap
                              (thread-waiting-for next) queue nil))
               (decf n)))
    nil))

(defmethod print-object ((waitqueue waitqueue) stream)
  (print-unreadable-object (waitqueue stream :type t :identity t)
    (format stream "~@[~A~]" (waitqueue-name waitqueue))))

(setf (documentation 'waitqueue-name 'function) "The name of the waitqueue. Setfable."
      (documentation 'make-waitqueue 'function) "Create a waitqueue.")

#+(and sb-thread sb-futex)
(locally (declare (sb-ext:muffle-conditions sb-ext:compiler-note))
  (define-structure-slot-addressor waitqueue-token-address
      :structure waitqueue
      :slot token))

(declaim (inline %condition-wait))
(defun %condition-wait (queue mutex
                        timeout to-sec to-usec stop-sec stop-usec deadlinep)
  #-sb-thread
  (declare (ignore queue mutex to-sec to-usec stop-sec stop-usec deadlinep))
  #-sb-thread
  (sb-ext:wait-for nil :timeout timeout) ; Yeah...
  #+sb-thread
  (let ((me *current-thread*))
    (barrier (:read))
    (unless (eq me (mutex-%owner mutex))
      (error "The current thread is not holding ~s." mutex))
    (let ((status :interrupted))
      ;; Need to disable interrupts so that we don't miss grabbing
      ;; the mutex on our way out.
      (without-interrupts
        (unwind-protect
             (progn
               #-sb-futex
               (progn
                 (%with-cas-lock ((waitqueue-%owner queue))
                   (%waitqueue-enqueue me queue))
                 (release-mutex mutex)
                 (setf status
                       (or (flet ((wakeup ()
                                    (barrier (:read))
                                    (unless (eq queue (thread-waiting-for me))
                                      :ok)))
                             (declare (dynamic-extent #'wakeup))
                             (allow-with-interrupts
                               (%%wait-for #'wakeup stop-sec stop-usec)))
                           :timeout)))
               #+sb-futex
               (with-pinned-objects (queue me)
                 (setf (waitqueue-token queue) me)
                 (release-mutex mutex)
                 ;; Now we go to sleep using futex-wait. If anyone else
                 ;; manages to grab MUTEX and call CONDITION-NOTIFY during
                 ;; this comment, it will change the token, and so futex-wait
                 ;; returns immediately instead of sleeping. Ergo, no lost
                 ;; wakeup. We may get spurious wakeups, but that's ok.
                 (setf status
                       (case (allow-with-interrupts
                               (futex-wait (waitqueue-token-address queue)
                                           (get-lisp-obj-address me)
                                           ;; our way of saying "no
                                           ;; timeout":
                                           (or to-sec -1)
                                           (or to-usec 0)))
                         ((1)
                          ;;  1 = ETIMEDOUT
                          :timeout)
                         (t
                          ;; -1 = EWOULDBLOCK, possibly spurious wakeup
                          ;;  0 = normal wakeup
                          ;;  2 = EINTR, a spurious wakeup
                          :ok)))))
          #-sb-futex
          (%with-cas-lock ((waitqueue-%owner queue))
            (if (eq queue (thread-waiting-for me))
                (%waitqueue-drop me queue)
                (unless (eq :ok status)
                  ;; CONDITION-NOTIFY thinks we've been woken up, but really
                  ;; we're unwinding. Wake someone else up.
                  (%waitqueue-wakeup queue 1))))
          ;; Update timeout for mutex re-aquisition unless we are
          ;; already past the requested timeout.
          (when (and (eq :ok status) to-sec)
            (setf (values to-sec to-usec)
                  (sb-impl::relative-decoded-times stop-sec stop-usec))
            (when (and (zerop to-sec) (not (plusp to-usec)))
              (setf status :timeout)))
          ;; If we ran into deadline, try to get the mutex before
          ;; signaling. If we don't unwind it will look like a normal
          ;; return from user perspective.
          (when (and (eq :timeout status) deadlinep)
            (let ((got-it (%try-mutex mutex me)))
              (allow-with-interrupts
                (signal-deadline)
                (cond (got-it
                       (return-from %condition-wait t))
                      (t
                       ;; The deadline may have changed.
                       (setf (values to-sec to-usec stop-sec stop-usec deadlinep)
                             (decode-timeout timeout))
                       (setf status :ok))))))
          ;; Re-acquire the mutex for normal return.
          (when (eq :ok status)
            (unless (or (%try-mutex mutex me)
                        (allow-with-interrupts
                          (%wait-for-mutex mutex me timeout
                                           to-sec to-usec
                                           stop-sec stop-usec deadlinep)))
              (setf status :timeout)))))
      ;; Determine actual return value. :ok means (potentially
      ;; spurious) wakeup => T. :timeout => NIL.
      (case status
        (:ok
         (if timeout
             (multiple-value-bind (sec usec)
                 (sb-impl::relative-decoded-times stop-sec stop-usec)
               (values t sec usec))
             t))
        (:timeout
         nil)
        (t
         ;; The only case we return normally without re-acquiring
         ;; the mutex is when there is a :TIMEOUT that runs out.
         (bug "%CONDITION-WAIT: invalid status on normal return: ~S" status))))))
(declaim (notinline %condition-wait))

(defun condition-wait (queue mutex &key timeout)
  "Atomically release MUTEX and start waiting on QUEUE until another thread
wakes us up using either CONDITION-NOTIFY or CONDITION-BROADCAST on
QUEUE, at which point we re-acquire MUTEX and return T.

Spurious wakeups are possible.

If TIMEOUT is given, it is the maximum number of seconds to wait,
including both waiting for the wakeup and the time to re-acquire
MUTEX. When neither a wakeup nor a re-acquisition occurs within the
given time, returns NIL without re-acquiring MUTEX.

If CONDITION-WAIT unwinds, it may do so with or without MUTEX being
held.

Important: Since CONDITION-WAIT may return without CONDITION-NOTIFY or
CONDITION-BROADCAST having occurred, the correct way to write code
that uses CONDITION-WAIT is to loop around the call, checking the
associated data:

  (defvar *data* nil)
  (defvar *queue* (make-waitqueue))
  (defvar *lock* (make-mutex))

  ;; Consumer
  (defun pop-data (&optional timeout)
    (with-mutex (*lock*)
      (loop until *data*
            do (or (condition-wait *queue* *lock* :timeout timeout)
                   ;; Lock not held, must unwind without touching *data*.
                   (return-from pop-data nil)))
      (pop *data*)))

  ;; Producer
  (defun push-data (data)
    (with-mutex (*lock*)
      (push data *data*)
      (condition-notify *queue*)))
"
  (assert mutex)
  (locally (declare (inline %condition-wait))
    (multiple-value-bind (to-sec to-usec stop-sec stop-usec deadlinep)
        (decode-timeout timeout)
      (values
       (%condition-wait queue mutex timeout
                        to-sec to-usec stop-sec stop-usec deadlinep)))))

(defun condition-notify (queue &optional (n 1))
  "Notify N threads waiting on QUEUE.

IMPORTANT: The same mutex that is used in the corresponding CONDITION-WAIT
must be held by this thread during this call."
  #-sb-thread
  (declare (ignore queue n))
  #-sb-thread
  (error "Not supported in unithread builds.")
  #+sb-thread
  (declare (type (and fixnum (integer 1)) n))
  #+sb-thread
  (progn
    #-sb-futex
    (with-cas-lock ((waitqueue-%owner queue))
      (%waitqueue-wakeup queue n))
    #+sb-futex
    (progn
    ;; No problem if >1 thread notifies during the comment in condition-wait:
    ;; as long as the value in queue-data isn't the waiting thread's id, it
    ;; matters not what it is -- using the queue object itself is handy.
    ;;
    ;; XXX we should do something to ensure that the result of this setf
    ;; is visible to all CPUs.
    ;;
    ;; ^-- surely futex_wake() involves a memory barrier?
      (setf (waitqueue-token queue) queue)
      (with-pinned-objects (queue)
        (futex-wake (waitqueue-token-address queue) n)))))

(defun condition-broadcast (queue)
  "Notify all threads waiting on QUEUE.

IMPORTANT: The same mutex that is used in the corresponding CONDITION-WAIT
must be held by this thread during this call."
  (condition-notify queue
                    ;; On a 64-bit platform truncating M-P-F to an int
                    ;; results in -1, which wakes up only one thread.
                    (ldb (byte 29 0)
                         sb-xc:most-positive-fixnum)))


;;;; Semaphores

(defstruct (semaphore (:copier nil)
                      (:constructor make-semaphore
                          (&key name ((:count %count) 0))))
  "Semaphore type. The fact that a SEMAPHORE is a STRUCTURE-OBJECT
should be considered an implementation detail, and may change in the
future."
  (name    nil :type (or null string) :read-only t)
  (%count    0 :type (integer 0))
  (waitcount 0 :type sb-vm:word)
  (mutex (make-mutex :name "semaphore lock") :read-only t)
  (queue (make-waitqueue) :read-only t))

(setf (documentation 'semaphore-name 'function)
      "The name of the semaphore INSTANCE. Setfable."
      (documentation 'make-semaphore 'function)
      "Create a semaphore with the supplied COUNT and NAME.")

(defstruct (semaphore-notification (:constructor make-semaphore-notification ())
                                   (:copier nil))
  "Semaphore notification object. Can be passed to WAIT-ON-SEMAPHORE and
TRY-SEMAPHORE as the :NOTIFICATION argument. Consequences are undefined if
multiple threads are using the same notification object in parallel."
  (%status nil :type boolean))

(setf (documentation 'make-semaphore-notification 'function)
      "Constructor for SEMAPHORE-NOTIFICATION objects. SEMAPHORE-NOTIFICATION-STATUS
is initially NIL.")

(declaim (inline semaphore-notification-status))
(defun semaphore-notification-status (semaphore-notification)
  "Returns T if a WAIT-ON-SEMAPHORE or TRY-SEMAPHORE using
SEMAPHORE-NOTIFICATION has succeeded since the notification object was created
or cleared."
  (barrier (:read))
  (semaphore-notification-%status semaphore-notification))

(declaim (inline clear-semaphore-notification))
(defun clear-semaphore-notification (semaphore-notification)
  "Resets the SEMAPHORE-NOTIFICATION object for use with another call to
WAIT-ON-SEMAPHORE or TRY-SEMAPHORE."
  (barrier (:write)
    (setf (semaphore-notification-%status semaphore-notification) nil)))

(declaim (inline semaphore-count))
(defun semaphore-count (instance)
  "Returns the current count of the semaphore INSTANCE."
  (barrier (:read))
  (semaphore-%count instance))

(declaim (ftype (sfunction (semaphore (integer 1) (or boolean real)
                            (or null semaphore-notification) symbol)
                           t)
                %decrement-semaphore))
(defun %decrement-semaphore (semaphore n wait notification context)
  (when (and notification (semaphore-notification-status notification))
    (with-simple-restart (continue "Clear notification status and continue.")
      (error "~@<Semaphore notification object status not cleared on ~
              entry to ~S on ~S.~:@>"
             context semaphore))
    (clear-semaphore-notification notification))

  ;; A more direct implementation based directly on futexes should be
  ;; possible.
  ;;
  ;; We need to disable interrupts so that we don't forget to
  ;; decrement the waitcount (which would happen if an asynch
  ;; interrupt should catch us on our way out from the loop.)
  ;;
  ;; FIXME: No timeout on initial mutex acquisition.
  (with-system-mutex ((semaphore-mutex semaphore) :allow-with-interrupts t)
    (flet ((success (new-count)
             (prog1
                 (setf (semaphore-%count semaphore) new-count)
               (when notification
                 (setf (semaphore-notification-%status notification) t)))))
      ;; Quick check: can we decrement right away? If not, return or
      ;; enter the wait loop.
      (cond
        ((let ((old-count (semaphore-%count semaphore)))
           (when (>= old-count n)
             (success (- old-count n)))))
        ((not wait)
         nil)
        (t
         (unwind-protect
              (binding* ((old-count nil)
                         (timeout (when (realp wait) wait))
                         ((to-sec to-usec stop-sec stop-usec deadlinep)
                          (when wait
                            (decode-timeout timeout))))
                ;; Need to use ATOMIC-INCF despite the lock, because
                ;; on our way out from here we might not be locked
                ;; anymore -- so another thread might be tweaking this
                ;; in parallel using ATOMIC-DECF. No danger over
                ;; overflow, since there it at most one increment per
                ;; thread waiting on the semaphore.
                (sb-ext:atomic-incf (semaphore-waitcount semaphore))
                (loop until (>= (setf old-count (semaphore-%count semaphore)) n)
                   do (multiple-value-bind (wakeup-p remaining-sec remaining-usec)
                          (%condition-wait
                           (semaphore-queue semaphore)
                           (semaphore-mutex semaphore)
                           timeout to-sec to-usec stop-sec stop-usec deadlinep)
                        (when (or (not wakeup-p)
                                  (and (eql remaining-sec 0)
                                       (eql remaining-usec 0)))
                          (return-from %decrement-semaphore nil)) ; timeout
                        (when remaining-sec
                          (setf to-sec remaining-sec
                                to-usec remaining-usec))))
                (success (- old-count n)))
           ;; Need to use ATOMIC-DECF as we may unwind without the
           ;; lock being held!
           (sb-ext:atomic-decf (semaphore-waitcount semaphore))))))))

(declaim (ftype (sfunction (semaphore &key
                                      (:n (integer 1))
                                      (:timeout (real (0)))
                                      (:notification semaphore-notification))
                           (or null (integer 0)))
                wait-on-semaphore))
(defun wait-on-semaphore (semaphore &key (n 1) timeout notification)
  "Decrement the count of SEMAPHORE by N if the count would not be negative.

Else blocks until the semaphore can be decremented. Returns the new count of
SEMAPHORE on success.

If TIMEOUT is given, it is the maximum number of seconds to wait. If the count
cannot be decremented in that time, returns NIL without decrementing the
count.

If NOTIFICATION is given, it must be a SEMAPHORE-NOTIFICATION object whose
SEMAPHORE-NOTIFICATION-STATUS is NIL. If WAIT-ON-SEMAPHORE succeeds and
decrements the count, the status is set to T."
  (%decrement-semaphore
   semaphore n (or timeout t) notification 'wait-on-semaphore))

(declaim (ftype (sfunction (semaphore &optional
                                      (integer 1) semaphore-notification)
                           (or null (integer 0)))
                try-semaphore))
(defun try-semaphore (semaphore &optional (n 1) notification)
  "Try to decrement the count of SEMAPHORE by N. If the count were to
become negative, punt and return NIL, otherwise return the new count of
SEMAPHORE.

If NOTIFICATION is given it must be a semaphore notification object
with SEMAPHORE-NOTIFICATION-STATUS of NIL. If the count is decremented,
the status is set to T."
  (%decrement-semaphore semaphore n nil notification 'try-semaphore))

(defun signal-semaphore (semaphore &optional (n 1))
  "Increment the count of SEMAPHORE by N. If there are threads waiting
on this semaphore, then N of them is woken up."
  (declare (type (integer 1) n))
  ;; Need to disable interrupts so that we don't lose a wakeup after
  ;; we have incremented the count.
  (with-system-mutex ((semaphore-mutex semaphore) :allow-with-interrupts t)
    (let ((waitcount (semaphore-waitcount semaphore))
          (count (incf (semaphore-%count semaphore) n)))
      (when (plusp waitcount)
        (condition-notify (semaphore-queue semaphore) (min waitcount count))))))


;;;; Job control, independent listeners

(defstruct (session (:copier nil))
  (lock (make-mutex :name "session lock"))
  (threads nil)
  (interactive-threads nil)
  (interactive-threads-queue (make-waitqueue)))

(defvar *session* nil)

;;; The debugger itself tries to acquire the session lock, don't let
;;; funny situations (like getting a sigint while holding the session
;;; lock) occur. At the same time we need to allow interrupts while
;;; *waiting* for the session lock for things like GET-FOREGROUND to
;;; be interruptible.
;;;
;;; Take care: we sometimes need to obtain the session lock while
;;; holding on to *ALL-THREADS-LOCK*, so we must _never_ obtain it
;;; _after_ getting a session lock! (Deadlock risk.)
;;;
;;; FIXME: It would be good to have ordered locks to ensure invariants
;;; like the above.
(defmacro with-session-lock ((session) &body body)
  `(with-system-mutex ((session-lock ,session) :allow-with-interrupts t)
     ,@body))

(defun new-session ()
  (make-session :threads (list *current-thread*)
                :interactive-threads (list *current-thread*)))

(defun init-job-control ()
  (/show0 "Entering INIT-JOB-CONTROL")
  (setf *session* (new-session))
  (/show0 "Exiting INIT-JOB-CONTROL"))

(defun %delete-thread-from-session (thread session)
  (with-session-lock (session)
    (let ((was-foreground (eq thread (foreground-thread session))))
      (setf (session-threads session)
            ;; FIXME: I assume these could use DELQ1.
            ;; DELQ never conses, but DELETE does. (FIXME)
            (delq thread (session-threads session))
            (session-interactive-threads session)
            (delq thread (session-interactive-threads session)))
      (when was-foreground
        (condition-broadcast (session-interactive-threads-queue session))))))

(defun call-with-new-session (fn)
  (%delete-thread-from-session *current-thread* *session*)
  (let ((*session* (new-session)))
    (funcall fn)))

(defmacro with-new-session (args &body forms)
  (declare (ignore args))               ;for extensibility
  (with-unique-names (fb-name)
    `(labels ((,fb-name () ,@forms))
      (call-with-new-session (function ,fb-name)))))

;;; Remove thread from its session, if it has one.
#+sb-thread
(defun handle-thread-exit (thread control-stack-start)
  (/show0 "HANDLING THREAD EXIT")
  (when *exit-in-process*
    (%exit))
  ;; Lisp-side cleanup
  (with-all-threads-lock
    (setf (thread-%alive-p thread) nil)
    (setf (thread-os-thread thread)
          (ldb (byte sb-vm:n-word-bits 0) -1))
    (setq *all-threads* (avl-delete control-stack-start *all-threads*))
    (when *session*
      (%delete-thread-from-session thread *session*))))

(defvar sb-ext:*invoke-debugger-hook* nil
  "This is either NIL or a designator for a function of two arguments,
   to be run when the debugger is about to be entered.  The function is
   run with *INVOKE-DEBUGGER-HOOK* bound to NIL to minimize recursive
   errors, and receives as arguments the condition that triggered
   debugger entry and the previous value of *INVOKE-DEBUGGER-HOOK*

   This mechanism is an SBCL extension similar to the standard *DEBUGGER-HOOK*.
   In contrast to *DEBUGGER-HOOK*, it is observed by INVOKE-DEBUGGER even when
   called by BREAK.")

(defun %exit-other-threads ()
  ;; Grabbing this lock prevents new threads from
  ;; being spawned, and guarantees that *ALL-THREADS*
  ;; is up to date.
  (with-deadline (:seconds nil :override t)
    (sb-impl::finalizer-thread-stop)
    (grab-mutex *make-thread-lock*)
    (let ((timeout sb-ext:*exit-timeout*)
          (code *exit-in-process*)
          (current *current-thread*)
          (joinees nil)
          (main nil))
      ;; Don't invoke the debugger on errors in cleanup forms in unwind-protect
      (setf sb-ext:*invoke-debugger-hook*
            (lambda (c h)
              (sb-debug::debugger-disabled-hook c h :quit nil)
              (abort-thread :allow-exit t)))
      (dolist (thread (list-all-threads))
        (cond ((eq thread current))
              ((main-thread-p thread)
               (setf main thread))
              (t
               (handler-case
                   (progn
                     (terminate-thread thread)
                     (push thread joinees))
                 (interrupt-thread-error ())))))
      (with-progressive-timeout (time-left :seconds timeout)
        (dolist (thread joinees)
          (join-thread thread :default t :timeout (time-left)))
        ;; Need to defer till others have joined, because when main
        ;; thread exits, we're gone. Can't use TERMINATE-THREAD -- would
        ;; get the exit code wrong.
        (when main
          (handler-case
              (interrupt-thread
               main
               (lambda ()
                 (setf *exit-in-process* (list code))
                 (throw 'sb-impl::%end-of-the-world t)))
            (interrupt-thread-error ()))
          ;; Normally this never finishes, as once the main-thread unwinds we
          ;; exit with the right code, but if times out before that happens,
          ;; we will exit after returning -- or rathe racing the main thread
          ;; to calling OS-EXIT.
          (join-thread main :default t :timeout (time-left)))))))

(defun terminate-session ()
  "Kill all threads in session except for this one.  Does nothing if current
thread is not the foreground thread."
  ;; FIXME: threads created in other threads may escape termination
  (let* ((session *session*)
         (to-kill (with-session-lock (session)
                    (and (eq *current-thread* (foreground-thread session))
                         (session-threads session)))))
    ;; do the kill after dropping the mutex; unwind forms in dying
    ;; threads may want to do session things
    (dolist (thread to-kill)
      (unless (eq thread *current-thread*)
        ;; terminate the thread but don't be surprised if it has
        ;; exited in the meantime
        (handler-case (terminate-thread thread)
          (interrupt-thread-error ()))))))

;;; called from top of invoke-debugger
(defun debugger-wait-until-foreground-thread (stream)
  "Returns T if thread had been running in background, NIL if it was
interactive."
  (declare (ignore stream))
  #-sb-thread nil
  #+sb-thread
  (prog1
      (with-session-lock (*session*)
        (let ((foreground (foreground-thread)))
          (unless (or (null foreground)
                      (eq foreground *current-thread*))
            (format *error-output* "~%The current thread is not at the foreground,~@
SB-THREAD:RELEASE-FOREGROUND has to be called in ~s~%for this thread to enter the debugger.~%"
                    foreground))
          (not (member *current-thread*
                       (session-interactive-threads *session*)))))
    (get-foreground)))

(defun get-foreground ()
  #-sb-thread t
  #+sb-thread
  (let ((session *session*)
        (was-foreground t))
    (loop
     (/show0 "Looping in GET-FOREGROUND")
     (with-session-lock (session)
       (symbol-macrolet
           ((interactive-threads (session-interactive-threads session)))
         (cond
           ((null interactive-threads)
            (setf was-foreground nil
                  interactive-threads (list *current-thread*)))
           ((not (eq (first interactive-threads) *current-thread*))
            (setf was-foreground nil)
            (unless (member *current-thread* interactive-threads)
              (setf interactive-threads
                    (append interactive-threads (list *current-thread*))))
            (condition-wait
             (session-interactive-threads-queue session)
             (session-lock session)))
           (t
            (unless was-foreground
              (format *query-io* "Resuming thread ~A~%" *current-thread*))
            (return-from get-foreground t))))))))

(defun release-foreground (&optional next)
  "Background this thread.  If NEXT is supplied, arrange for it to
have the foreground next."
  #-sb-thread (declare (ignore next))
  #-sb-thread nil
  #+sb-thread
  (let ((session *session*))
    (with-session-lock (session)
      (symbol-macrolet
          ((interactive-threads (session-interactive-threads session)))
        (setf interactive-threads
              (delete *current-thread* interactive-threads))
        (when (and next (thread-alive-p next))
          (setf interactive-threads
                (list* next (delete next interactive-threads))))
        (condition-broadcast (session-interactive-threads-queue session))))))

(defun interactive-threads (&optional (session *session*))
  "Return the interactive threads of SESSION defaulting to the current
session."
  (session-interactive-threads session))

(defun foreground-thread (&optional (session *session*))
  "Return the foreground thread of SESSION defaulting to the current
session."
  (first (interactive-threads session)))

#-win32
(defun make-listener-thread (tty-name)
  (aver (probe-file tty-name))
  (let* ((in (sb-unix:unix-open (namestring tty-name) sb-unix:o_rdwr #o666))
         (out (sb-unix:unix-dup in))
         (err (sb-unix:unix-dup in)))
    (labels ((thread-repl ()
               (sb-unix::unix-setsid)
               (let* ((sb-impl::*stdin*
                        (make-fd-stream in :input t :buffering :line
                                           :dual-channel-p t))
                      (sb-impl::*stdout*
                        (make-fd-stream out :output t :buffering :line
                                            :dual-channel-p t))
                      (sb-impl::*stderr*
                        (make-fd-stream err :output t :buffering :line
                                            :dual-channel-p t))
                      (sb-impl::*tty*
                        (make-fd-stream err :input t :output t
                                            :buffering :line
                                            :dual-channel-p t))
                      (sb-impl::*descriptor-handlers* nil))
                 (with-new-session ()
                   (unwind-protect
                        (sb-impl::toplevel-repl nil)
                     (flush-standard-output-streams))))))
      (make-thread #'thread-repl))))


;;;; The beef

;;; One must parse this name carefully: it is the initial "thread function trampoline",
;;; and not the "initial thread" "function trampoline".
;;; i.e. there is an initial thread, which DOES NOT start via this function.
;;; All threads other than the initial thread DO start via this function.
;;; The initial thread has its own way of doing things, which ends up calling
;;; INIT-INITIAL-THREAD.  It might be nice to come up with some better naming.
#+sb-thread
(defun initial-thread-function-trampoline (thread setup-sem real-function arguments)
  ;; Can't initiate GC before *current-thread* is set, otherwise the
  ;; locks grabbed by SUB-GC wouldn't function.
  ;; Other threads can GC with impunity.
  (setf *current-thread* thread ; is thread-local already
        (thread-os-thread thread) (current-thread-os-thread)
        (thread-stack-end thread) (get-lisp-obj-address sb-vm:*control-stack-end*)
        (thread-primitive-thread thread) (sap-int (current-thread-sap)))
  ;; *ALLOC-SIGNAL* is made thread-local by create_thread_struct()
  ;; so this assigns into TLS, not the global value.
  (setf sb-vm:*alloc-signal* *default-alloc-signal*)
  (with-mutex ((thread-result-lock thread))
    (with-all-threads-lock
        (let ((addr (get-lisp-obj-address sb-vm:*control-stack-start*)))
          ;; If ADDR exists, then we have a bug in the thread exit handler.
          ;; The workaround here would be to delete the old thread first,
          ;; but I'd rather find out about the bug than bury it.
          (aver (not (avl-find addr *all-threads*)))
          (setq *all-threads* (avl-insert *all-threads* addr thread))))
    (let ((session *session*)
          (session-cons (list thread)))
        (with-session-lock (session)
          (setf (cdr session-cons) (session-threads session)
                (session-threads session) session-cons)))
    (setf (thread-%alive-p thread) t)

    (when setup-sem
      (signal-semaphore setup-sem)
      ;; setup-sem was dx-allocated, set it to NIL so that the
      ;; backtrace doesn't get confused
      (setf setup-sem nil))

    ;; Using handling-end-of-the-world would be a bit tricky
    ;; due to other catches and interrupts, so we essentially
    ;; re-implement it here. Once and only once more.
    (catch 'sb-impl::toplevel-catcher
      (catch 'sb-impl::%end-of-the-world
        (catch '%abort-thread
          (restart-bind ((abort
                           (lambda ()
                             (throw '%abort-thread nil))
                           :report-function
                           (lambda (stream)
                             (format stream "~@<abort thread (~a)~@:>"
                                     *current-thread*))))
            (without-interrupts
              (unwind-protect
                   (with-local-interrupts
                     (sb-unix::unblock-deferrable-signals)
                     (setf (thread-result thread)
                           (prog1
                               (multiple-value-list
                                (unwind-protect
                                     (catch '%return-from-thread
                                       (sb-c::inspect-unwinding
                                        (apply real-function arguments)
                                        #'sb-di::catch-runaway-unwind))
                                  (when *exit-in-process*
                                    (sb-impl::call-exit-hooks))))
                             #+sb-safepoint
                             (sb-kernel::gc-safepoint))))
                ;; we're going down, can't handle interrupts
                ;; sanely anymore. gc remains enabled.
                (block-deferrable-signals)
                ;; we don't want to run interrupts in a dead
                ;; thread when we leave without-interrupts.
                ;; this potentially causes important
                ;; interupts to be lost: sigint comes to
                ;; mind.
                (setq *interrupt-pending* nil)
                #+sb-thruption
                (setq *thruption-pending* nil)
                (handle-thread-exit thread
                                    (get-lisp-obj-address
                                     sb-vm:*control-stack-start*)))))))))
  (values))

(defun make-thread (function &key name arguments ephemeral)
  "Create a new thread of NAME that runs FUNCTION with the argument
list designator provided (defaults to no argument). Thread exits when
the function returns. The return values of FUNCTION are kept around
and can be retrieved by JOIN-THREAD.

Invoking the initial ABORT restart established by MAKE-THREAD
terminates the thread.

See also: RETURN-FROM-THREAD, ABORT-THREAD."
  #-sb-thread (declare (ignore function name arguments ephemeral))
  #-sb-thread (error "Not supported in unithread builds.")
  #+sb-thread (assert (or (atom arguments)
                           (null (cdr (last arguments))))
                       (arguments)
                       "Argument passed to ~S, ~S, is an improper list."
                       'make-thread arguments)
  #+sb-thread
  (let ((thread (%make-thread :name name :%ephemeral-p ephemeral)))
    (declare (inline make-semaphore
                     make-waitqueue
                     make-mutex))
    (let* ((setup-sem (make-semaphore :name "Thread setup semaphore"))
           (real-function (coerce function 'function))
           (arguments     (ensure-list arguments))
           #+(or win32 darwin)
           (fp-modes (dpb 0 sb-vm:float-sticky-bits ;; clear accrued bits
                          (sb-vm:floating-point-modes))))
      (declare (dynamic-extent setup-sem))
      (dx-flet ((initial-thread-function ()
                  ;; Inherit parent thread's FP modes
                  #+(or win32 darwin)
                  (setf (sb-vm:floating-point-modes) fp-modes)
                  ;; As it is, this lambda must not cons until we are
                  ;; ready to run GC. Be careful.
                  (initial-thread-function-trampoline thread setup-sem
                                                      real-function arguments)))
        ;; Holding mutexes or waiting on sempahores inside WITHOUT-GCING will lock up
        (aver (not *gc-inhibit*))
        ;; Keep INITIAL-FUNCTION in the dynamic extent until the child
        ;; thread is initialized properly. Wrap the whole thing in
        ;; WITHOUT-INTERRUPTS (via WITH-SYSTEM-MUTEX) because we pass
        ;; INITIAL-FUNCTION to another thread.
        ;; (Does WITHOUT-INTERRUPTS really matter now that it's DXed?)
        (with-system-mutex (*make-thread-lock*)
          (if (zerop
               (%create-thread (get-lisp-obj-address #'initial-thread-function)))
              (setf thread nil)
              (wait-on-semaphore setup-sem)))))
    (or thread (error "Could not create a new thread."))))

(defun join-thread (thread &key (default nil defaultp) timeout)
  "Suspend current thread until THREAD exits. Return the result values
of the thread function.

If THREAD does not exit within TIMEOUT seconds and DEFAULT is
supplied, return two values: 1) DEFAULT 2) :TIMEOUT. If DEFAULT is not
supplied, signal a JOIN-THREAD-ERROR with JOIN-THREAD-PROBLEM equal
to :TIMEOUT.

If THREAD does not exit normally (i.e. aborted) and DEFAULT is
supplied, return two values: 1) DEFAULT 2) :ABORT. If DEFAULT is not
supplied, signal a JOIN-THREAD-ERROR with JOIN-THREAD-PROBLEM equal
to :ABORT.

If THREAD is the current thread, signal a JOIN-THREAD-ERROR with
JOIN-THREAD-PROBLEM equal to :SELF-JOIN.

Trying to join the main thread causes JOIN-THREAD to block until
TIMEOUT occurs or the process exits: when the main thread exits, the
entire process exits.

NOTE: Return convention in case of a timeout is experimental and
subject to change."
  (when (eq thread *current-thread*)
    (error 'join-thread-error :thread thread :problem :self-join))

  (let ((lock (thread-result-lock thread))
        (got-it nil)
        (problem :timeout))
    (without-interrupts
      (unwind-protect
           (cond
             ((not (setf got-it
                         (allow-with-interrupts
                           ;; Don't use the timeout if the thread is
                           ;; not alive anymore.
                           (grab-mutex lock :timeout (and (thread-alive-p thread)
                                                          timeout))))))
             ((listp (thread-result thread))
              (return-from join-thread
                (values-list (thread-result thread))))
             (t
              (setf problem :abort)))
        (when got-it
          (release-mutex lock))))
    (if defaultp
        (values default problem)
        (error 'join-thread-error :thread thread :problem problem))))

(defun destroy-thread (thread)
  (terminate-thread thread))

#-sb-xc-host
(declaim (sb-ext:deprecated
          :late ("SBCL" "1.2.15")
          (function destroy-thread :replacement terminate-thread)))

(defmacro with-interruptions-lock ((thread) &body body)
  `(with-system-mutex ((thread-interruptions-lock ,thread))
     ,@body))

;;; Called from the signal handler.
#-(or sb-thruption win32)
(defun run-interruption ()
  (let ((interruption (with-interruptions-lock (*current-thread*)
                        (pop (thread-interruptions *current-thread*)))))
    ;; If there is more to do, then resignal and let the normal
    ;; interrupt deferral mechanism take care of the rest. From the
    ;; OS's point of view the signal we are in the handler for is no
    ;; longer pending, so the signal will not be lost.
    (when (thread-interruptions *current-thread*)
      (kill-safely (thread-os-thread *current-thread*) sb-unix:sigpipe))
    (when interruption
      (funcall interruption))))

#+sb-thruption
(defun run-interruption (*current-internal-error-context*)
  (in-interruption () ;the non-thruption code does this in the signal handler
    (let ((interruption (with-interruptions-lock (*current-thread*)
                          (pop (thread-interruptions *current-thread*)))))
      (when interruption
        (funcall interruption)
        ;; I tried implementing this function as an explicit LOOP, because
        ;; if we are currently processing the thruption queue, why not do
        ;; all of them in one go instead of one-by-one?
        ;;
        ;; I still think LOOPing would be basically the right thing
        ;; here.  But suppose some interruption unblocked deferrables.
        ;; Will the next one be happy with that?  The answer is "no", at
        ;; least in the sense that there are tests which check that
        ;; deferrables are blocked at the beginning of a thruption, and
        ;; races that make those tests fail.  Whether the tests are
        ;; misguided or not, it seems easier/cleaner to loop implicitly
        ;; -- and it's also what AK had implemented in the first place.
        ;;
        ;; The implicit loop is achieved by returning to C, but having C
        ;; call back to us immediately.  The runtime will reset the sigmask
        ;; in the mean time.
        ;; -- DFL
        (setf *thruption-pending* t)))))

(defun interrupt-thread (thread function)
  "Interrupt THREAD and make it run FUNCTION.

The interrupt is asynchronous, and can occur anywhere with the exception of
sections protected using SB-SYS:WITHOUT-INTERRUPTS.

FUNCTION is called with interrupts disabled, under
SB-SYS:ALLOW-WITH-INTERRUPTS. Since functions such as GRAB-MUTEX may try to
enable interrupts internally, in most cases FUNCTION should either enter
SB-SYS:WITH-INTERRUPTS to allow nested interrupts, or
SB-SYS:WITHOUT-INTERRUPTS to prevent them completely.

When a thread receives multiple interrupts, they are executed in the order
they were sent -- first in, first out.

This means that a great degree of care is required to use INTERRUPT-THREAD
safely and sanely in a production environment. The general recommendation is
to limit uses of INTERRUPT-THREAD for interactive debugging, banning it
entirely from production environments -- it is simply exceedingly hard to use
correctly.

With those caveats in mind, what you need to know when using it:

 * If calling FUNCTION causes a non-local transfer of control (ie. an
   unwind), all normal cleanup forms will be executed.

   However, if the interrupt occurs during cleanup forms of an UNWIND-PROTECT,
   it is just as if that had happened due to a regular GO, THROW, or
   RETURN-FROM: the interrupted cleanup form and those following it in the
   same UNWIND-PROTECT do not get executed.

   SBCL tries to keep its own internals asynch-unwind-safe, but this is
   frankly an unreasonable expectation for third party libraries, especially
   given that asynch-unwind-safety does not compose: a function calling
   only asynch-unwind-safe function isn't automatically asynch-unwind-safe.

   This means that in order for an asynch unwind to be safe, the entire
   callstack at the point of interruption needs to be asynch-unwind-safe.

 * In addition to asynch-unwind-safety you must consider the issue of
   reentrancy. INTERRUPT-THREAD can cause function that are never normally
   called recursively to be re-entered during their dynamic contour,
   which may cause them to misbehave. (Consider binding of special variables,
   values of global variables, etc.)

Taken together, these two restrict the \"safe\" things to do using
INTERRUPT-THREAD to a fairly minimal set. One useful one -- exclusively for
interactive development use is using it to force entry to debugger to inspect
the state of a thread:

  (interrupt-thread thread #'break)

Short version: be careful out there."
  #+(and (not sb-thread) win32)
  #+(and (not sb-thread) win32)
  (declare (ignore thread))
  (with-interrupt-bindings
    (with-interrupts (funcall function)))
  #-(and (not sb-thread) win32)
  (let ((os-thread (thread-os-thread thread)))
    (cond ((= os-thread (ldb (byte sb-vm:n-word-bits 0) -1))
           (error 'interrupt-thread-error :thread thread))
          (t
           (let (invoked)
             (with-interruptions-lock (thread)
               ;; Append to the end of the interruptions queue. It's
               ;; O(N), but it does not hurt to slow interruptors down a
               ;; bit when the queue gets long.
               (setf (thread-interruptions thread)
                     (append (thread-interruptions thread)
                             (list (lambda ()
                                     (setf invoked t)
                                     (barrier (:memory))
                                     (without-interrupts
                                       (allow-with-interrupts
                                         (funcall function))))))))
             (when (and (minusp (wake-thread os-thread))
                        ;; The interrupt queue has been processed by
                        ;; some other interrupt.
                        (progn (barrier (:memory))
                               (not invoked)))
               (error 'interrupt-thread-error :thread thread)))))))

(defun terminate-thread (thread)
  "Terminate the thread identified by THREAD, by interrupting it and
causing it to call SB-EXT:ABORT-THREAD with :ALLOW-EXIT T.

The unwind caused by TERMINATE-THREAD is asynchronous, meaning that
eg. thread executing

  (let (foo)
     (unwind-protect
         (progn
            (setf foo (get-foo))
            (work-on-foo foo))
       (when foo
         ;; An interrupt occurring inside the cleanup clause
         ;; will cause cleanups from the current UNWIND-PROTECT
         ;; to be dropped.
         (release-foo foo))))

might miss calling RELEASE-FOO despite GET-FOO having returned true if
the interrupt occurs inside the cleanup clause, eg. during execution
of RELEASE-FOO.

Thus, in order to write an asynch unwind safe UNWIND-PROTECT you need
to use WITHOUT-INTERRUPTS:

  (let (foo)
    (sb-sys:without-interrupts
      (unwind-protect
          (progn
            (setf foo (sb-sys:allow-with-interrupts
                        (get-foo)))
            (sb-sys:with-local-interrupts
              (work-on-foo foo)))
       (when foo
         (release-foo foo)))))

Since most libraries using UNWIND-PROTECT do not do this, you should never
assume that unknown code can safely be terminated using TERMINATE-THREAD."
  (interrupt-thread thread (lambda () (abort-thread :allow-exit t))))

(define-alien-routine "thread_yield" int)

(setf (documentation 'thread-yield 'function)
      "Yield the processor to other threads.")

;;; internal use only.  If you think you need to use these, either you
;;; are an SBCL developer, are doing something that you should discuss
;;; with an SBCL developer first, or are doing something that you
;;; should probably discuss with a professional psychiatrist first
#+sb-thread
(progn

  (sb-ext:define-load-time-global sb-vm::*free-tls-index* 0)
  ;; Keep in sync with 'compiler/generic/parms.lisp'
  #+ppc ; only PPC uses a separate symbol for the TLS index lock
  (!define-load-time-global sb-vm::*tls-index-lock* 0)

  (defun %symbol-value-in-thread (symbol thread)
    ;; Prevent the thread from dying completely while we look for the TLS
    ;; area...
    (with-all-threads-lock
      (if (thread-alive-p thread)
          (let ((val (sap-ref-lispobj (int-sap (thread-primitive-thread thread))
                                      (symbol-tls-index symbol))))
            (case (get-lisp-obj-address val)
              (#.sb-vm:no-tls-value-marker-widetag (values nil :no-tls-value))
              (#.sb-vm:unbound-marker-widetag (values nil :unbound-in-thread))
              (t (values val :ok))))
          (values nil :thread-dead))))

  (defun %set-symbol-value-in-thread (symbol thread value)
    ;; Prevent the thread from dying completely while we look for the TLS
    ;; area...
    (with-all-threads-lock
      (if (thread-alive-p thread)
          (let ((offset (symbol-tls-index symbol)))
            (cond ((zerop offset)
                   (values nil :no-tls-value))
                  (t
                   (setf (sap-ref-lispobj (int-sap (thread-primitive-thread thread))
                                          offset)
                         value)
                   (values value :ok))))
          (values nil :thread-dead))))

  ;; Get values from the TLS area of the current thread.
  ;; Disregard duplicates and immediate objects.
  (defun %thread-local-references ()
    ;; TLS-INDEX-START is a word number relative to thread base.
    ;; *FREE-TLS-INDEX* - which is only manipulated by machine code  - is an
    ;; offset from thread base to the next usable TLS cell as a byte offset
    ;; (raw value) manifesting in Lisp as a fixnum.
    ;; The sign bit of sb-vm::*free-tls-index* is a semaphore,
    ;; except on PPC where it isn't, but masking is fine in any case.
    (do ((index (- (ash (logand sb-vm::*free-tls-index* sb-xc:most-positive-fixnum)
                        sb-vm:n-fixnum-tag-bits)
                   sb-vm:n-word-bytes)
                (- index sb-vm:n-word-bytes))
         ;; (There's no reason this couldn't work on any thread now.)
         (sap (int-sap (thread-primitive-thread *current-thread*)))
         (list))
        ((< index (ash tls-index-start sb-vm:word-shift)) list)
      (let ((obj (sap-ref-lispobj sap index)))
        (when (and obj ; don't bother returning NIL
                   (sb-vm:is-lisp-pointer (get-lisp-obj-address obj))
                   (not (memq obj list)))
          (push obj list))))))

(defun symbol-value-in-thread (symbol thread &optional (errorp t))
  "Return the local value of SYMBOL in THREAD, and a secondary value of T
on success.

If the value cannot be retrieved (because the thread has exited or because it
has no local binding for NAME) and ERRORP is true signals an error of type
SYMBOL-VALUE-IN-THREAD-ERROR; if ERRORP is false returns a primary value of
NIL, and a secondary value of NIL.

Can also be used with SETF to change the thread-local value of SYMBOL.

SYMBOL-VALUE-IN-THREAD is primarily intended as a debugging tool, and not as a
mechanism for inter-thread communication."
  (declare (symbol symbol) (thread thread))
  #+sb-thread
  (multiple-value-bind (res status) (%symbol-value-in-thread symbol thread)
    (if (eq :ok status)
        (values res t)
        (if errorp
            (error 'symbol-value-in-thread-error
                   :name symbol
                   :thread thread
                   :info (list :read status))
            (values nil nil))))
  #-sb-thread
  (if (boundp symbol)
      (values (symbol-value symbol) t)
      (if errorp
          (error 'symbol-value-in-thread-error
                 :name symbol
                 :thread thread
                 :info (list :read :unbound-in-thread))
          (values nil nil))))

(defun (setf symbol-value-in-thread) (value symbol thread &optional (errorp t))
  (declare (symbol symbol) (thread thread))
  #+sb-thread
  (multiple-value-bind (res status) (%set-symbol-value-in-thread symbol thread value)
    (if (eq :ok status)
        (values res t)
        (if errorp
            (error 'symbol-value-in-thread-error
                   :name symbol
                   :thread thread
                   :info (list :write status))
            (values nil nil))))
  #-sb-thread
  (if (boundp symbol)
      (values (setf (symbol-value symbol) value) t)
      (if errorp
          (error 'symbol-value-in-thread-error
                 :name symbol
                 :thread thread
                 :info (list :write :unbound-in-thread))
          (values nil nil))))



;;;; Stepping

(defun thread-stepping ()
  (sap-ref-lispobj (current-thread-sap)
                   (* sb-vm::thread-stepping-slot sb-vm:n-word-bytes)))

(defun (setf thread-stepping) (value)
  (setf (sap-ref-lispobj (current-thread-sap)
                         (* sb-vm::thread-stepping-slot sb-vm:n-word-bytes))
        value))
