;;; HASH TABLES

#-sb-thread (sb-ext:exit :code 104)
(use-package "SB-THREAD")
(use-package "SB-SYS")

;;; Keep moving everything that can move during each GC
#+gencgc (setf (generation-number-of-gcs-before-promotion 0) 1000000)

;; These have to be global because rehash occurs in any thread
(defglobal *rehash-count* 0)
(defglobal *watched-table* nil)

(sb-int:encapsulate 'sb-impl::rehash-without-growing 'count
                    (compile nil
                             '(lambda (f tbl)
                               ;; Only count rehashes on the table of interest.
                               (when (eq tbl *watched-table*) (incf *rehash-count*))
                               (funcall f tbl))))

(defun is-address-sensitive (tbl)
  (let ((data (sb-kernel:get-header-data (sb-impl::hash-table-pairs tbl))))
    (logtest data sb-vm:vector-addr-hashing-subtype)))

(with-test (:name (hash-table :eql-hash-symbol-not-eq-based))
  ;; If you ask for #'EQ as the test, then everything is address-sensitive,
  ;; though this is not technically a requirement.
  (let ((ht (make-hash-table :test 'eq)))
    (setf (gethash (make-symbol "GOO") ht) 1)
    (assert (is-address-sensitive ht)))
  (dolist (test '(eql equal equalp))
    (let ((ht (make-hash-table :test test)))
      (setf (gethash (make-symbol "GOO") ht) 1)
      (assert (not (is-address-sensitive ht))))))

(defclass ship () ())

(with-test (:name (hash-table :equal-hash-std-object-not-eq-based))
  (dolist (test '(eq eql))
    (let ((ht (make-hash-table :test test)))
      (setf (gethash (make-instance 'ship) ht) 1)
      (assert (is-address-sensitive ht))))
  (dolist (test '(equal equalp))
    (let ((ht (make-hash-table :test test)))
      (setf (gethash (make-instance 'ship) ht) 1)
      (assert (not (is-address-sensitive ht))))))

(defvar *errors* nil)

(defun oops (e)
  (setf *errors* e)
  (format t "~&oops: ~A in ~S~%" e *current-thread*)
  (sb-debug:print-backtrace)
  (catch 'done))

(with-test (:name (hash-table :unsynchronized)
                  ;; FIXME: This test occasionally eats out craploads
                  ;; of heap instead of expected error early. Not 100%
                  ;; sure if it would finish as expected, but since it
                  ;; hits swap on my system I'm not likely to find out
                  ;; soon. Disabling for now. -- nikodemus
            :broken-on :sbcl)
  ;; We expect a (probable) error here: parellel readers and writers
  ;; on a hash-table are not expected to work -- but we also don't
  ;; expect this to corrupt the image.
  (let* ((hash (make-hash-table))
         (*errors* nil)
         (threads (list (make-kill-thread
                         (lambda ()
                           (catch 'done
                             (handler-bind ((serious-condition 'oops))
                               (loop
                                 ;;(princ "1") (force-output)
                                 (setf (gethash (random 100) hash) 'h)))))
                         :name "writer")
                        (make-kill-thread
                         (lambda ()
                           (catch 'done
                             (handler-bind ((serious-condition 'oops))
                               (loop
                                 ;;(princ "2") (force-output)
                                 (remhash (random 100) hash)))))
                         :name "reader")
                        (make-kill-thread
                         (lambda ()
                           (catch 'done
                             (handler-bind ((serious-condition 'oops))
                               (loop
                                 (sleep (random 1.0))
                                 (sb-ext:gc)))))
                         :name "collector"))))
    (unwind-protect
         (sleep 10)
      (mapc #'terminate-thread threads))))

(defmacro with-test-setup ((array (table constructor)) &body body)
  ;; Using fixnums as hash-table keys does not engender a thorough enough test
  ;; as they will not cause the table to need rehash due to GC.
  ;; Using symbols won't work either because they hash stably under EQL
  ;; (but not under EQ) so let's use a bunch of cons cells.
  `(let* ((,array (coerce (loop for i from 0 repeat 100 collect (cons i i)) 'vector))
          (,table ,constructor))
     (setq *watched-table* ,table)
     ,@body
     (format t "~&::: INFO: Rehash count = ~D~%" *rehash-count*)
     (setq *watched-table* nil *rehash-count* 0)))

;;; Do *NOT* use (gc :full) in the following tests - a full GC causes all objects
;;; to be promoted into the highest normal generation, which achieves nothing,
;;; and runs the collector less often (because it's slower) relative to the total
;;; test time, making the test less usesful. It's fine for everything in gen0
;;; to stay in gen0, which basically never promotes due to the ludicrously high
;;; threshold set for number of GCs between promotions.

(defparameter *sleep-delay-max* .025)

(with-test (:name (hash-table :synchronized)
            :broken-on :win32)
 (with-test-setup (keys (hash (make-hash-table :synchronized t)))
  (let* ((*errors* nil)
         (threads (list (make-join-thread
                         (lambda ()
                           (catch 'done
                             (handler-bind ((serious-condition 'oops))
                               (loop
                                 ;;(princ "1") (force-output)
                                 (setf (gethash (aref keys (random 100)) hash) 'h)))))
                         :name "writer")
                        (make-join-thread
                         (lambda ()
                           (catch 'done
                             (handler-bind ((serious-condition 'oops))
                               (loop
                                 ;;(princ "2") (force-output)
                                 (remhash (aref keys (random 100)) hash)))))
                         :name "reader")
                        (make-join-thread
                         (lambda ()
                           (catch 'done
                             (handler-bind ((serious-condition 'oops))
                               (loop
                                 (sleep (random *sleep-delay-max*))
                                 (sb-ext:gc)))))
                         :name "collector"))))
    (unwind-protect (sleep 5)
      (mapc #'terminate-thread threads))
    (assert (not *errors*)))))

(with-test (:name (hash-table :parallel-readers)
                  :broken-on :win32)
 (with-test-setup (keys (hash (make-hash-table)))
   (let ((*errors* nil)
         (expected (make-array 100 :initial-element nil)))
    (loop repeat 50
          do (let ((i (random 100)))
               (setf (gethash (aref keys i) hash) i)
               (setf (aref expected i) t)))
     (flet ((reader ()
              (catch 'done
                (handler-bind ((serious-condition 'oops))
                  (loop
                      (let* ((i (random 100))
                             (x (gethash (aref keys i) hash)))
                        (cond ((aref expected i) (assert (eq x i)))
                              (t (assert (not x))))))))))
       (let ((threads (list (make-kill-thread #'reader :name "reader 1")
                            (make-kill-thread #'reader :name "reader 2")
                            (make-kill-thread #'reader :name "reader 3")
                            (make-kill-thread
                             (lambda ()
                               (catch 'done
                                 (handler-bind ((serious-condition 'oops))
                                   (loop
                                     (sleep (random *sleep-delay-max*))
                                     (sb-ext:gc)))))
                             :name "collector"))))
         (unwind-protect (sleep 5)
           (mapc #'terminate-thread threads))
         (assert (not *errors*)))))))

(with-test (:name (hash-table :single-accessor :parallel-gc)
                  :broken-on :win32)
 (with-test-setup (keys (hash (make-hash-table)))
  (let ((*errors* nil))
    (let ((threads (list (make-kill-thread
                          (lambda ()
                            (handler-bind ((serious-condition 'oops))
                              (loop
                                (let ((n (aref keys (random 100))))
                                  (if (gethash n hash)
                                      (remhash n hash)
                                      (setf (gethash n hash) 'h))))))
                          :name "accessor")
                         (make-kill-thread
                          (lambda ()
                            (handler-bind ((serious-condition 'oops))
                              (loop
                                (sleep (random *sleep-delay-max*))
                                (sb-ext:gc))))
                          :name "collector"))))
      (unwind-protect (sleep 5)
        (mapc #'terminate-thread threads))
      (assert (not *errors*))))))
