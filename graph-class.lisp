(in-package :graph-db)

(defvar *graphs* (make-hash-table :test 'equal :synchronized t))

(defclass graph ()
  ((graph-name :accessor graph-name :initarg :graph-name)
   (location :accessor location :initarg :location)
   (txn-log :accessor txn-log :initarg :txn-log)
   (txn-file :accessor txn-file :initarg :txn-file)
   (txn-lock :accessor txn-lock :initarg :txn-lock :initform (make-recursive-lock))
   (replication-key :accessor replication-key :initarg :replication-key)
   (replication-port :accessor replication-port :initarg :replication-port)
   (vertex-table :accessor vertex-table :initarg :vertex-table)
   (edge-table :accessor edge-table :initarg :edge-table)
   (heap :accessor heap :initarg :heap)
   (indexes :accessor indexes :initarg :indexes)
   (schema :accessor schema :initarg :schema)
   (cache :accessor cache :initarg :cache)
   (ve-index-in :accessor ve-index-in :initarg :ve-index-in)
   (ve-index-out :accessor ve-index-out :initarg :ve-index-out)
   (vev-index :accessor vev-index :initarg :vev-index)
   (vertex-index :accessor vertex-index :initarg :vertex-index)
   (edge-index :accessor edge-index :initarg :edge-index)
   (views-lock :accessor views-lock :initarg :views-lock
               :initform (make-recursive-lock))
   (views :accessor views :initarg :views)
   (write-stats :accessor write-stats :initarg :write-stats
                :initform (make-hash-table :test 'eq :synchronized t))
   (read-stats :accessor read-stats :initarg :read-stats
               :initform (make-hash-table :test 'eq :synchronized t))))

(defclass master-graph (graph)
  ((replication-mbox :accessor replication-mbox :initarg :replication-mbox)
   (replication-listener :accessor replication-listener :initarg :replication-listener)
   (stop-replication-p :accessor stop-replication-p :initarg :stop-replication-p :initform nil)
   (slaves :accessor slaves :initarg :slaves :initform ())
   (slaves-lock :accessor slaves-lock :initarg :slaves-lock :initform (make-recursive-lock))))

(defclass slave-graph (graph)
  ((master-host :accessor master-host :initarg :master-host)
   (slave-socket :accessor slave-socket :initarg :slave-socket)
   (stop-replication-p :accessor stop-replication-p :initarg :stop-replication-p :initform nil)
   (slave-thread :accessor slave-thread :initarg :slave-thread :initform nil)
   (master-txn-id :accessor master-txn-id :initarg :master-txn-id)))

(defgeneric graph-p (thing)
  (:method ((graph graph)) graph)
  (:method (thing) nil))

(defgeneric master-graph-p (thing)
  (:method ((graph master-graph)) graph)
  (:method (thing) nil))

(defgeneric slave-graph-p (thing)
  (:method ((graph slave-graph)) graph)
  (:method (thing) nil))

(defgeneric init-schema (graph))
(defgeneric update-schema (graph-or-name))
(defgeneric snapshot (graph))
(defgeneric init-txn-log (graph))
(defgeneric scan-for-unindexed-nodes (graph))
(defgeneric start-replication (graph &key package))
(defgeneric stop-replication (graph))

(defun lookup-graph (name)
  (gethash name *graphs*))


