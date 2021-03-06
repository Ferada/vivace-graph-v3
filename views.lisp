(in-package :graph-db)

(defvar *view-rv* nil)

(defstruct view-group
  class-name
  (dirty-p (sb-concurrency:make-gate :open t)) ;; Not currently used
  (table (make-hash-table :test 'eql :synchronized t))
  (lock (make-rw-lock)))

(defstruct (view
             (:print-function
              (lambda (v s d)
                (declare (ignore d))
                (format s "#<VIEW '~S' OF '~S' IN '~S'~% ~S~% ~S>"
                        (view-name v) (view-class-name v) (view-graph-name v)
                        (view-map-code v) (view-reduce-code v)))))
  name
  class-name
  map-fn
  map-code
  reduce-fn
  reduce-code
  graph-name
  heap
  pointer
  skip-list
  (lock (make-rw-lock))
  lookup-fn)

(defun yield (key value)
  ;;(dbg "PUSHING (~S ~S) ON TO *VIEW-RV*" key value)
  (push (list key value) *view-rv*))

(defmethod view-group-exists-p ((group-name symbol) (graph graph))
  (gethash group-name (views graph)))

(defmethod list-views ((graph graph))
  (let ((views nil))
    (maphash (lambda (k v)
               (maphash (lambda (k1 v1)
                          (push (cons (view-group-class-name v)
                                      (view-name v1))
                                views))
                        (view-group-table v)))
             (views graph))
    views))

(defmethod lookup-view-group ((group-name symbol) (graph graph))
  (gethash group-name (views graph)))

(defmethod lookup-view-group ((group-name symbol) (graph-name symbol))
  (lookup-view-group group-name (lookup-graph graph-name)))

(defmacro with-write-locked-view-group ((name graph) &body body)
  `(let ((view-group (lookup-view-group ,name ,graph)))
     (with-write-lock ((view-group-lock view-group))
       ,@body)))

(defmacro with-read-locked-view-group ((name graph) &body body)
  `(let ((view-group (lookup-view-group ,name ,graph)))
     (with-read-lock ((view-group-lock view-group))
       ,@body)))

(defun view-key-serialize (key)
  (let ((payload (serialize (first key))))
    (let ((d (concatenate 'vector (second key) payload)))
      d)))

(defun view-key-deserialize (array)
  (multiple-value-bind (payload length)
      (deserialize (subseq array 16))
    (let ((d (list payload (subseq array 0 16))))
      (values d (+ length 16)))))

(defmethod restore-views ((graph graph))
  (let ((views-file (format nil "~A/views.dat" (location graph)))
        (view-table (make-hash-table :synchronized t)))
    (when (probe-file views-file)
      (let ((blob (cl-store:restore views-file)))
        (dolist (view-data blob)
          (let* ((view-group-name (car view-data))
                 (view-group (make-view-group :class-name view-group-name)))
            (setf (gethash view-group-name view-table) view-group)
            (dolist (view (rest view-data))
              (dbg "RESTORING ~S VIEW ~S" view-group-name (cdr (assoc :name view)))
              (let* ((view-name (cdr (assoc :name view)))
                     (v (make-view :name view-name
                                   :class-name view-group-name
                                   :graph-name (graph-name graph)
                                   :lookup-fn (cdr (assoc :lookup-fn view))
                                   :map-code (cdr (assoc :map-code view))
                                   :reduce-code (cdr (assoc :reduce-code view))
                                   :heap (indexes graph)
                                   :pointer (cdr (assoc :pointer view)))))
                (when (view-pointer v)
                  (setf (view-skip-list v)
                        (open-skip-list :address (cdr (assoc :pointer view))
                                        :heap (indexes graph)
                                        :duplicates-allowed-p nil
                                        :key-equal 'view-key-equal
                                        :key-comparison 'view-less-than
                                        :value-equal 'equal
                                        :key-serializer 'view-key-serialize
                                        :key-deserializer 'view-key-deserialize
                                        :value-serializer 'serialize
                                        :value-deserializer 'deserialize)))
                (setf (gethash view-name (view-group-table view-group)) v)))))))
    (setf (views graph) view-table)))

(defmethod save-views ((graph graph))
  (with-recursive-lock-held ((views-lock graph))
    (let ((views-file (format nil "~A/views.dat" (location graph)))
          (blob nil))
      (maphash
       (lambda (class-name view-group)
         (let ((views nil))
           (maphash
            (lambda (view-name view)
              (let ((view-alist nil))
                (setq view-alist (acons :name view-name view-alist))
                (setq view-alist (acons :lookup-fn (view-lookup-fn view) view-alist))
                (setq view-alist (acons :map-code (view-map-code view) view-alist))
                (setq view-alist (acons :reduce-code (view-reduce-code view) view-alist))
                (setq view-alist (acons :pointer (view-pointer view) view-alist))
                (push view-alist views)))
            (view-group-table view-group))
           (push (cons class-name views) blob)))
       (views graph))
      ;;(dbg "SAVING VIEWS: ~S" blob)
      (cl-store:store blob views-file)
      blob)))

(defmethod delete-view ((graph graph) (class-name symbol) (view-name symbol))
  "Delete this view's index"
  (with-write-locked-view-group (class-name graph)
    (let ((view (lookup-view graph class-name view-name)))
      (when (skip-list-p (view-skip-list view))
        (delete-skip-list (view-skip-list view)))
      (remhash view-name (gethash class-name (views graph)))))
  (save-views graph))

(defmethod get-view-table-for-class ((graph graph) (class-name symbol))
  (let ((view-group (gethash class-name (views graph))))
    (unless (view-group-p view-group)
      (setq view-group
            (setf (gethash class-name (views graph))
                  (make-view-group :class-name class-name)))
      (save-views graph))
    (view-group-table view-group)))

(defmethod get-view-table-for-class ((graph-name symbol) (class-name symbol))
  (let ((graph (lookup-graph graph-name)))
    (if graph
        (get-view-table-for-class graph class-name)
        (error "Graph '~S' not loaded" graph-name))))

(defmethod lookup-view ((graph graph) (class-name symbol) (view-name symbol))
  (let ((view-group (lookup-view-group class-name graph)))
    (gethash view-name (view-group-table view-group))))

(defmethod all-views ((graph graph))
  (let ((views nil))
    (dolist (class-name (all-node-types graph))
      (when (lookup-view-group class-name graph)
        (let ((view-group (gethash class-name (views graph))))
          (when view-group
            (sb-ext:with-locked-hash-table ((view-group-table view-group))
              (loop for view-name being the hash-keys in (view-group-table view-group)
                   do
                   (push (cons class-name view-name) views)))))))
    views))

(defmethod lookup-views ((graph graph) (class-name symbol))
  (when (lookup-view-group class-name graph)
    (let ((view-group (gethash class-name (views graph))))
      (when view-group
        (sb-ext:with-locked-hash-table ((view-group-table view-group))
          (loop for view-name being the hash-keys in (view-group-table view-group)
             collecting view-name))))))

;; Not currently used
(defmethod set-view-group-dirty ((graph graph) (class-name symbol))
  (let ((view-group (lookup-view-group class-name graph)))
    (sb-concurrency:close-gate (view-group-dirty-p view-group))))

;; Not currently used
(defmethod set-view-group-clean ((graph graph) (class-name symbol))
  (let ((view-group (lookup-view-group class-name graph)))
    (sb-concurrency:open-gate (view-group-dirty-p view-group))))

(defmethod compile-view-code ((view view))
  (setf (view-map-fn view)
        (eval (read-from-string (view-map-code view))))
  (when (view-reduce-code view)
    (setf (view-reduce-fn view)
          (eval (read-from-string (view-reduce-code view))))))

(defun reduce-equal (key1 key2)
  ;;(dbg "REDUCE-EQUAL ~S < ~S" key1 key2)
  (and (equal (first key1) (first key2))
       (equalp (second key1) (second key2))))

(defun reduce-comp (key1 key2)
  ;;(dbg "REDUCE-COMP ~S < ~S" key1 key2)
  (cond ((less-than (first key1) (first key2))
         t)
        ((and (equal (first key1) (first key2))
         (key-vector< (second key1) (second key2)))
         t)
        (t nil)))

(defmethod add-to-view ((graph graph) (view view) (node node))
  "Add node to view."
  (compile-view-code view)
  (let ((*view-rv* nil))
    ;;(log:debug "VIEW: Calling ~S on ~S" (view-map-fn view) node)
    (funcall (view-map-fn view) node)
    ;;(log:debug "VIEW-RV: ~S" *view-rv*)
    (mapcar (lambda (rv)
              (destructuring-bind (key val) rv
                ;;(log:debug "VIEW: Adding ~S:~S to ~S" key val (view-skip-list view))
                (add-to-skip-list (view-skip-list view)
                                  (list key (id node))
                                  val)
                (when (functionp (view-reduce-fn view))
                  (let* ((agg-key (list key +null-key+))
                         (agg-node
                          (find-in-skip-list (view-skip-list view) agg-key)))
                    ;;(log:debug "REDUCE: ADDING TO SL: ~S -> ~S" agg-key agg-node)
                    (if agg-node
                        (let ((agg-val
                               (funcall (view-reduce-fn view)
                                        (list (%sn-key agg-node) key)
                                        (list (%sn-value agg-node) val))))
                          (update-in-skip-list (view-skip-list view)
                                               agg-key agg-val))
                        (add-to-skip-list (view-skip-list view)
                                          agg-key val)))
                  (let* ((agg-key (list +reduce-master-key+ +max-key+))
                         (agg-node
                          (find-in-skip-list (view-skip-list view) agg-key)))
                    ;;(log:debug "REDUCE: ADDING TO SL: ~S -> ~S" agg-key agg-node)
                    (if agg-node
                        (let ((agg-val
                               (funcall (view-reduce-fn view)
                                        (list (%sn-key agg-node) key)
                                        (list (%sn-value agg-node) val))))
                          (update-in-skip-list (view-skip-list view)
                                               agg-key agg-val))
                        (add-to-skip-list (view-skip-list view)
                                          agg-key val)))
                  )))
            *view-rv*)))

(defmethod get-non-aggregate-pairs ((skip-list skip-list) key)
  (let ((keys nil) (values nil))
    (let ((cursor (make-range-cursor skip-list
                                     (list key +null-key+)
                                     (list key +max-key+))))
      (loop for node = (cursor-next cursor :eoc)
         until (eql node :eoc)
           do
           (unless (equalp +null-key+ (second (%sn-key node)))
             (push (first (%sn-key node)) keys)
             (push (%sn-value node) values))))
    (values keys values)))

(defmethod get-all-aggregate-pairs ((skip-list skip-list))
  (let ((keys nil) (values nil))
    (let ((cursor (make-cursor skip-list)))
      (loop for node = (cursor-next cursor :eoc)
         until (eql node :eoc)
         do
           (when (equalp +null-key+ (second (%sn-key node)))
             (push (first (%sn-key node)) keys)
             (push (%sn-value node) values))))
    (values keys values)))

(defmethod remove-from-view ((graph graph) (view view) (node node))
  "Remove node from view."
  (compile-view-code view)
  (let ((*view-rv* nil))
    (funcall (view-map-fn view) node)
    ;;(dbg "VIEW-RV: ~S" *view-rv*)
    (mapcar
     (lambda (rv)
       (destructuring-bind (key val) rv
         (remove-from-skip-list (view-skip-list view) (list key (id node)))
         (when (functionp (view-reduce-fn view))
           (let ((agg-key (list key +null-key+)))
             (remove-from-skip-list (view-skip-list view) agg-key)
             (multiple-value-bind (keys values)
                 (get-non-aggregate-pairs (view-skip-list view) key)
               (when keys
                 (let ((agg-val (funcall (view-reduce-fn view) keys values)))
                   (add-to-skip-list (view-skip-list view) agg-key agg-val)))))
           (let* ((agg-key (list +reduce-master-key+ +max-key+))
                  (agg-node (find-in-skip-list (view-skip-list view) agg-key)))
             (multiple-value-bind (keys values)
                 (get-all-aggregate-pairs (view-skip-list view))
               (when keys
                 (let ((agg-val (funcall (view-reduce-fn view) keys values)))
                   (if agg-node
                       (update-in-skip-list (view-skip-list view) agg-key agg-val)
                       (add-to-skip-list (view-skip-list view) agg-key val)))))))))
     *view-rv*)))

(defmethod %add-to-views ((graph graph) (node node) (class-name symbol))
  (dolist (view-name (lookup-views graph class-name))
    ;;(dbg "Adding ~S to view ~S:~S" node class-name view-name)
    (add-to-view graph (lookup-view graph class-name view-name) node)))

(defmethod add-to-views ((graph graph) (node node))
  "Add node to indices for its class's named views"
  (dolist (class (append (list (class-of node))
                         (find-graph-parent-classes (class-of node))))
    (let ((class-name (class-name class)))
      (when (lookup-view-group class-name graph)
        (with-write-locked-view-group (class-name graph)
          (%add-to-views graph node class-name))))))

(defmethod %remove-from-views ((graph graph) (node node) (class-name symbol))
  (dolist (view-name (lookup-views graph class-name))
    (remove-from-view graph
                      (lookup-view graph class-name view-name)
                      node)))

(defmethod remove-from-views ((graph graph) (node node))
  "Remove node from indices for its class's named views"
  (dolist (class (append (list (class-of node))
                         (find-graph-parent-classes (class-of node))))
    (let ((class-name (class-name class)))
      (when (lookup-view-group class-name graph)
        (with-write-locked-view-group (class-name graph)
          (%remove-from-views graph node class-name))))))

(defmethod %update-in-views ((graph graph) (new-node node) (old-node node)
                             (class-name symbol))
  (dolist (view-name (lookup-views graph class-name))
    (let ((view (lookup-view graph class-name view-name)))
      (remove-from-view graph view old-node)
      (add-to-view graph view new-node))))

(defmethod update-in-views ((graph graph) (new-node node) (old-node node))
  "Add node to indices for its class's named views"
  (dolist (class (append (list (class-of new-node))
                         (find-graph-parent-classes (class-of new-node))))
    (let ((class-name (class-name class)))
      (when (lookup-view-group class-name graph)
        (with-write-locked-view-group (class-name graph)
          (%update-in-views graph new-node old-node class-name))))))

(defun view-key-equal (key1 key2)
  (equal (first key1) (first key2)))

(defun view-less-than (key1 key2)
  (less-than (first key1) (first key2)))

(defmethod regenerate-view ((graph graph) (class-name symbol) (view-name symbol))
  "Regenerate this view's index"
  (with-write-locked-view-group (class-name graph)
    (let ((view (lookup-view graph class-name view-name)))
      ;; First, if exists, delete skip list
      (when (skip-list-p (view-skip-list view))
        (delete-skip-list (view-skip-list view)))
      ;; Then, create a new skip list
      (let ((sl (make-skip-list
                 :heap (indexes graph)
                 :duplicates-allowed-p nil
                 ;;:key-equal 'view-key-equal
                 ;;:key-comparison 'view-less-than
                 :key-equal 'reduce-equal
                 :key-comparison 'reduce-comp
                 :head-key (list +min-sentinel+ +null-key+)
                 :head-value nil
                 :tail-key (list +max-sentinel+ +max-key+)
                 :tail-value nil
                 :value-equal 'equal
                 :key-serializer 'view-key-serialize
                 :key-deserializer 'view-key-deserialize
                 :value-serializer 'serialize
                 :value-deserializer 'deserialize)))
        (setf (view-skip-list view) sl
              (view-pointer view) (%sl-address sl)
              (view-heap view) (indexes graph)))
      (save-views graph)
      (cond ((subtypep class-name 'vertex)
             (map-vertices (lambda (vertex)
                             (add-to-view graph view vertex))
                           graph :vertex-type class-name))
            ((subtypep class-name 'edge)
             (map-edges (lambda (edge)
                          (add-to-view graph view edge))
                        graph :edge-type class-name))
            (t
             (error "~S is not a subtype of either edge or vertex!" class-name)))
      view)))

(defmethod regenerate-all-views ((graph graph))
  (map nil
       (lambda (pair)
         (destructuring-bind (class-name . view-name) pair
           (regenerate-view graph class-name view-name)))
       (all-views graph)))

(defmethod map-view (fn (class-name symbol) (view-name symbol)
                     &key (graph *graph*) key start-key end-key count skip
                     collect-p include-deleted-p)
  (when (lookup-view-group class-name graph)
    (with-read-locked-view-group (class-name graph)
      (let* ((view (lookup-view graph class-name view-name))
             (lookup-fn (view-lookup-fn view))
             (skip-list (view-skip-list view))
             (cursor (if (and (null start-key) (null key) (null end-key))
                         (make-cursor skip-list)
                         (make-range-cursor skip-list
                                            (list (cond (key key)
                                                        (start-key start-key)
                                                        (t +min-sentinel+))
                                                  +null-key+)
                                            (list (cond (key key)
                                                        (end-key end-key)
                                                        (t +max-sentinel+))
                                                  +max-key+))))
             (result nil) (found-count 0) (cursor-count 0))
        (loop
           for node = (cursor-next cursor)
           until (or (null node) (and count (= found-count count)))
           do
           ;;(dbg "~S" node)
           (when (or (null skip) (> cursor-count skip))
             (incf cursor-count)
             (let ((pnode (funcall lookup-fn (second (%sn-key node)))))
               (unless (or include-deleted-p (null pnode) (deleted-p pnode))
                 (incf found-count)
                 (if collect-p
                     (push (funcall fn
                                    (first (%sn-key node))
                                    (second (%sn-key node))
                                    (%sn-value node))
                           result)
                     (funcall fn
                              (first (%sn-key node))
                              (second (%sn-key node))
                              (%sn-value node)))))))
        (when collect-p
          (values (nreverse result) found-count))))))

(defun default-map-fn (key id val)
  (list (cons :key key) (cons :id id) (cons :value val)))

(defmethod map-reduced-view (fn (class-name symbol) (view-name symbol) &key
                             (graph *graph*) start-key end-key count
                             skip collect-p)
  (when (lookup-view-group class-name graph)
    (with-read-locked-view-group (class-name graph)
      (let* ((view (lookup-view graph class-name view-name))
             (skip-list (view-skip-list view))
             (cursor (make-cursor skip-list))
             (result nil) (found-count 0) (total-count 0))
        (loop
           for node = (cursor-next cursor)
           while (and node
                      (or (null end-key)
                          (equal (first (%sn-key node)) end-key)
                          (less-than (first (%sn-key node)) end-key)))
           do
           (when (and (equalp +null-key+ (second (%sn-key node)))
                      (or (null start-key)
                          (or (equal (first (%sn-key node)) start-key)
                              (less-than start-key (first (%sn-key node))))))
             (incf total-count)
             (when (or (null skip) (> total-count skip))
               (if collect-p
                   (push
                    (funcall fn (first (%sn-key node)) nil (%sn-value node))
                    result)
                   (funcall fn (first (%sn-key node)) nil (%sn-value node)))
               (incf found-count)))
           (when (and count (= count found-count))
             (return)))
        (when collect-p
          (values (nreverse result) found-count))))))

(defmethod invoke-graph-view ((class-name symbol) (view-name symbol)
                              &key (graph *graph*) key start-key end-key count
                              skip group-p (reduce-p t))
  (when (lookup-view-group class-name graph)
    (with-read-locked-view-group (class-name graph)
      (let ((view (lookup-view graph class-name view-name)))
        (if (or (null (view-reduce-code view)) (null reduce-p))
            ;; Simple map view
            (map-view 'default-map-fn
                      class-name view-name
                      :key key :count count :skip skip
                      :start-key start-key :end-key end-key
                      :collect-p t :graph graph)
            ;; Reduce view
            (cond ((and group-p key)
                   (let ((node (find-in-skip-list (view-skip-list view)
                                                  (list key +null-key+))))
                     (when node
                       (default-map-fn (first (%sn-key node)) nil (%sn-value node)))))
                  (key
                   (map-view 'default-map-fn
                             class-name view-name
                             :key key :count count :skip skip
                             :collect-p t :graph graph))
                  (group-p
                   (map-reduced-view 'default-map-fn
                                     class-name view-name
                                     :start-key start-key
                                     :end-key end-key
                                     :skip skip :count count
                                     :collect-p t))
                  (t
                   (let ((node (find-in-skip-list (view-skip-list view)
                                                  (list +reduce-master-key+
                                                        +max-key+))))
                     (when node
                       (default-map-fn nil nil (%sn-value node)))))))))))

#|
(def-view email (customer :offerly)
  (:map
   (lambda (vertex)
     (emit (email vertex) (id vertex)))))

(def-view want-count (in-want-list :offerly)
  (:map
   (lambda (edge)
     (emit (to edge) 1)))
  (:reduce
   (lambda (keys vals)
     (declare (ignore keys))
     (apply '+ vals))))
|#

(defmacro def-view (name parents &body body)
  (with-gensyms (view-name class-name graph-name graph lookup-fn)
    (let ((map-code (cadr (assoc :map body)))
          (reduce-code (cadr (assoc :reduce body))))
      `(let* ((,view-name ',name)
              (,class-name ',(first parents))
              (,graph-name ',(second parents))
              (,graph (lookup-graph ,graph-name))
              (,lookup-fn ',(intern (format nil "LOOKUP-~A" (first parents))))
              (view (make-view :name ,view-name
                               :class-name ,class-name
                               :graph-name ,graph-name
                               :lookup-fn ,lookup-fn
                               :heap (indexes ,graph)
                               :map-code ,(format nil "~S" map-code)
                               :reduce-code ,(when reduce-code
                                                   (format nil "~S" reduce-code))
                               :map-fn nil
                               :reduce-fn nil)))
         (dbg "MAKING ~S" view)
         (let* ((table (get-view-table-for-class ,graph-name ,class-name)))
           (with-write-locked-view-group (,class-name ,graph-name)
             (setf (gethash ,view-name table) view)
             (save-views ,graph)
             (regenerate-view ,graph ,class-name ,view-name)
             ))))))
