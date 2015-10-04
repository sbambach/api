(in-package :turtl)

(defvalidator validate-board
  (("id" :type id :required t)
   ("user_id" :type id :required t)
   ("parent_id" :type id)
   ("keys" :type sequence :required t :coerce simple-vector)
   ("body" :type cl-async-util:bytes-or-string))
  :old t)

(defvalidator validate-board-persona-link
  (("id" :type id :required t)
   ("board_id" :type id :required t)
   ("from" :type id :required t)
   ("to" :type string :required t)
   ("perms" :type integer :required t)))

;;; ----------------------------------------------------------------------------
;;; util
;;; ----------------------------------------------------------------------------

(defafun get-board-by-id (future) (board-id &key get-notes (get-privs t))
  "Grab a board by id."
  (alet* ((sock (db-sock))
          (query (r:r (:get (:table "boards") board-id)))
          (board (r:run sock query)))
    (r:disconnect sock)
    (if board
        (alet ((notes (when get-notes (get-board-notes board-id)))
               (privs (when get-privs (get-board-privs board-id))))
          (when notes (setf (gethash "notes" board) notes))
          (when privs (setf (gethash "privs" board) privs))
          (finish future board))
        (finish future nil))))

;;; ----------------------------------------------------------------------------
;;; crud stuff
;;; ----------------------------------------------------------------------------

(defafun add-board (future) (user-id board-data)
  "Save a board with a user."
  (setf (gethash "user_id" board-data) user-id)
  (let ((cid (gethash "cid" board-data)))
    (validate-board (board-data future)
      (alet* ((sock (db-sock))
              (query (r:r (:insert
                            (:table "boards")
                            board-data)))
              (nil (r:run sock query))
              (sync-ids (add-sync-record user-id
                                         "board"
                                         (gethash "id" board-data)
                                         "add"
                                         :client-id cid
                                         :rel-ids (list user-id))))
        (r:disconnect sock)
        (setf (gethash "sync_ids" board-data) sync-ids)
        (finish future board-data)))))

(defafun edit-board (future) (user-id board-id board-data)
  "Edit an existing board."
  ;; first, check if the user owns the board. any non-owner edits have to be
  ;; done via different (more specific) methods than just "LOL replace all teh
  ;; dataz immy boardt!"
  (alet* ((perms (get-user-board-permissions user-id board-id))
          (current-board (get-board-by-id board-id)))
    (if (<= 3 perms)
        (validate-board (board-data future)
          (setf (gethash "user_id" board-data) (gethash "user_id" current-board))
          (alet* ((sock (db-sock))
                  (query (r:r (:replace
                                (:get (:table "boards") board-id)
                                board-data)))
                  (nil (r:run sock query))
                  (user-ids (get-affected-users-from-board-ids (list board-id)))
                  (sync-ids (add-sync-record user-id "board" board-id "edit" :rel-ids user-ids)))
            (r:disconnect sock)
            (setf (gethash "sync_ids" board-data) sync-ids)
            (finish future board-data)))
        (signal-error future (make-instance 'insufficient-privileges
                                            :msg "Sorry, you are editing a board you don't own.")))))

(adefun delete-board (user-id board-id)
  "Delete a board."
  (alet* ((board (and board-id (get-board-by-id board-id)))
          (perms (if board
                     (get-user-board-permissions user-id nil :board board)
                     0)))
    (if board
        (if (<= 3 perms)
            (alet* ((user-ids (get-affected-users-from-board-ids (list board-id)))
                    (sock (db-sock))
                    (query (r:r (:delete (:get (:table "boards") board-id))))
                    (nil (r:run sock query))
                    (query (r:r (:delete
                                  (:get-all (:table "boards_personas_link") board-id :index (db-index "boards_personas_link" "board_id")))))
                    (nil (r:run sock query))
                    (nil (delete-keychain-entries user-id board-id))
                    (sync-ids (add-sync-record user-id "board" board-id "delete" :rel-ids user-ids)))
              (r:disconnect sock)
              sync-ids)
            (error (make-instance 'insufficient-privileges
                                  :msg "Sorry, you are deleting a board you don't own.")))
        #())))

;;; ----------------------------------------------------------------------------
;;; syncing
;;; ----------------------------------------------------------------------------

(adefun get-all-boards (user-id persona-ids &key get-invites)
  "Given a user id and list of persona ids, get all boards this user has access
   to."
  (alet* ((board-ids (get-all-user-board-ids user-id :persona-ids persona-ids :get-invites get-invites))
          (boards (if (zerop (length board-ids))
                      #()
                      (get-boards-by-ids board-ids :get-personas t :get-invites get-invites))))
    boards))

(adefun expand-board-ids (board-ids)
  "Given a set of board ids, also grab all parents of the given board ids."
  (alet* ((sock (db-sock))
          (query (r:r
                   (:attr
                     (:attr
                       (:eq-join
                         (:get-all
                           (:table "boards")
                           board-ids)
                         "parent_id"
                         (:table "boards"))
                       "right")
                     "id")))
          (cursor (r:run sock query))
          (ids (r:to-array sock cursor)))
    (r:stop/disconnect sock cursor)
    (concatenate 'vector (if (listp board-ids)
                             (coerce board-ids 'vector)
                             board-ids) ids)))

(adefun get-affected-users-from-board-ids (board-ids &key get-invites)
  "For all given board-ids (list), find users that will be affected by changes
   to those boards or items in those boards. Returns a list of user-ids."
  (unless board-ids
    (return-from get-affected-users-from-board-ids))
  (alet* ((board-ids (expand-board-ids board-ids))
          (sock (db-sock))
          (query (r:r
                   (:attr
                     (:attr
                       (:eq-join
                         (:filter
                           (:get-all
                             (:table "boards_personas_link")
                             board-ids
                             :index (db-index "boards_personas_link" "board_id"))
                           (r:fn (l)
                             (if get-invites
                                 t
                                 (:== (:default (:attr l "invite") nil) nil))))
                         "to"
                         (:table "personas"))
                       "right")
                     "user_id")))
          (cursor (r:run sock query))
          (shared-user-ids (r:to-array sock cursor))
          (nil (r:stop sock cursor))
          (query (r:r
                   (:attr
                     (:get-all
                       (:table "boards")
                       board-ids)
                     "user_id")))
          (cursor (r:run sock query))
          (board-user-ids (r:to-array sock cursor))
          (nil (r:stop sock cursor)))
    (r:disconnect sock)
    (concatenate 'vector shared-user-ids board-user-ids)))

(defafun get-all-user-board-ids (future) (user-id &key shared persona-ids get-invites)
  "Gets ALL a user's board IDs, with option to specify grabbing shared boards."
  (alet* ((persona-ids (if persona-ids
                           persona-ids
                           (if shared
                               (get-user-persona-ids user-id)
                               #())))
          (sock (db-sock)))
    (flet ((get-user-board-ids (append)
             (alet* ((query (r:r (:attr
                                   (:get-all
                                     (:table "boards")
                                     user-id
                                     :index (db-index "boards" "user_id"))
                                   "id")))
                     (cursor (r:run sock query))
                     (board-ids (r:to-array sock cursor)))
               (r:stop/disconnect sock cursor)
               (finish future (concatenate 'vector board-ids append)))))
      (if (zerop (length persona-ids))
          (get-user-board-ids #())
          (alet* ((query (r:r (:attr
                                (:filter
                                  (:get-all
                                    (:table "boards_personas_link")
                                    (coerce persona-ids 'list)
                                    :index (db-index "boards_personas_link" "to"))
                                  (r:fn (l)
                                    (if get-invites
                                        t
                                        (:== (:default (:attr l "invite") nil) nil))))
                                "board_id")))
                  (cursor (r:run sock query))
                  (board-ids (r:to-array sock cursor)))
            (r:stop sock cursor)
            (get-user-board-ids board-ids))))))

(adefun get-boards-by-ids (board-ids &key get-personas get-invites)
  "Given a list of board IDs, grab all associated boards (and optionally their
   linked personas)."
  (alet* ((sock (db-sock))
          (query (r:r (:get-all
                         (:table "boards")
                         board-ids)))
          (cursor (r:run sock query))
          (boards (r:to-array sock cursor))
          (nil (r:stop sock cursor)))
    (finally
      (if get-personas
          (alet* ((query (r:r (:eq-join
                                (:filter
                                  (:get-all
                                    (:table "boards_personas_link")
                                    board-ids
                                    :index (db-index "boards_personas_link" "board_id"))
                                  (r:fn (l)
                                    (if get-invites
                                        t
                                        (:== (:default (:attr l "invite") nil) nil))))
                                "to"
                                (:table "personas"))))
                  (cursor (r:run sock query))
                  (privs/personas (r:to-array sock cursor))
                  (nil (r:stop sock cursor))
                  (board-index (hash)))
            (loop for board across boards
                  for board-id = (gethash "id" board) do
              (setf (gethash board-id board-index) board))
            (loop for entry across privs/personas
                  for link = (hget entry '("left"))
                  for board-id = (gethash "board_id" link)
                  for persona = (gethash "right" entry)
                  for board = (gethash board-id board-index) do
              (push persona (gethash "personas" board))
              (remhash "token_server" link)
              (unless (gethash "privs" board)
                (setf (gethash "privs" board) (hash)))
              (let ((privs (gethash "privs" board))
                    (persona-id (gethash "id" persona)))
                (setf (gethash persona-id privs) link)))
            boards)
          boards)
      (r:disconnect sock))))

;;; ----------------------------------------------------------------------------
;;; permissions
;;; ----------------------------------------------------------------------------
(adefun get-user-board-perms (user-id &key min-perms)
  "Grab all a user's boards, including shared, with permissions."
  (alet* ((persona-ids (get-user-persona-ids user-id))
          (user-board-ids (get-all-user-board-ids user-id))
          (sock (db-sock))
          ;; TODO: "fake id" is stupid hack, don't run query at all if no personas
          (qry (r:r (:pluck
                      (:zip
                        (:eq-join
                          (:get-all
                            (:table "boards_personas_link")
                            (or (coerce persona-ids 'list)
                                '("fake id"))
                            :index (db-index "boards_personas_link" "to"))
                          "board_id"
                          (:table "boards")))
                      (list "user_id" "board_id" "perms"))))
          (cursor (r:run sock qry))
          (shared (r:to-array sock cursor))
          (index (hash)))
    (r:stop/disconnect sock cursor)
    ;; set permissions for shared boards
    (loop for entry across shared
          for id = (gethash "board_id" entry)
          for perms = (gethash "perms" entry) do
      (when (or (not min-perms)
                (<= min-perms perms))
        (setf (gethash id index) (hash ("id" id)
                                       ("owner" (gethash "user_id" entry))
                                       ("perms" perms)))))
    ;; set user-owned to the "owned" permission (3) in the index
    (loop for id across user-board-ids
          for perms = 3 do
      (when (or (not min-perms)
                (<= min-perms perms))
        (setf (gethash id index) (hash ("id" id)
                                       ("owner" user-id)
                                       ("perms" perms)))))
    index))

(adefun get-user-board-permissions (user/persona-id board-id &key board)
  "Returns an integer used to determine a user/persona's permissions for the
   given board.

   0 == no permissions
   1 == read permissions
   2 == update permissions
   3 == owner"
  (alet* ((board (if board
                     board
                     (get-board-by-id board-id :get-privs t))))
    (if (hash-table-p board)
        (let* ((user-id (gethash "user_id" board))
               (privs (gethash "privs" board))
               (persona-privs (when (hash-table-p privs)
                                (gethash user/persona-id privs)))
               (persona-privs (when (hash-table-p persona-privs)
                                (gethash "perms" persona-privs)))
               (user-privs (cond ((string= user-id user/persona-id)
                                  3)
                                 ((and (numberp persona-privs)
                                       (< 0 persona-privs))
                                  persona-privs)
                                 (t
                                  0))))
          user-privs)
        0)))

(defafun get-board-privs (future) (board-id &key (indexed t))
  "Get privilege entries for a board (board <--> persona links)."
  (alet* ((sock (db-sock))
          (query (r:r (:get-all
                        (:table "boards_personas_link")
                        (list board-id)
                        :index (db-index "boards_personas_link" "board_id"))))
          (cursor (r:run sock query))
          (privs (r:to-array sock cursor)))
    (r:stop/disconnect sock cursor)
    (if indexed
        ;; we want an object: {persona: {..entry...}, persona: {..entry..}}
        (let ((index-hash (make-hash-table :test #'equal)))
          (loop for priv across privs do
            (setf (gethash (gethash "to" priv) index-hash) priv))
          (finish future index-hash))
        ;; return array of privs
        (finish future privs))))

;;; ----------------------------------------------------------------------------
;;; sharing
;;; ----------------------------------------------------------------------------

(adefun add-board-persona-link (user-id link-data)
  "Quick crud function to insert a board <--> persona link (or a board invite)."
  (alet* ((nil (validate-board-persona-link (link-data)))
          (sock (db-sock))
          (query (r:r (:insert
                        (:table "boards_personas_link")
                        link-data)))
          (nil (r:run sock query))
          (board-id (gethash "board_id" link-data))
          (user-ids (get-affected-users-from-board-ids (list board-id) :get-invites t))
          (user-ids (concatenate 'vector (vector user-id) user-ids))
          (sync-ids (add-sync-record user-id
                                     "board"
                                     board-id
                                     "edit"
                                     :rel-ids user-ids)))
    (r:disconnect sock)
    (setf (gethash "sync_ids" link-data) sync-ids)
    link-data))

(adefun get-board-persona-links (board-id)
  "Get all a board's persona links/invites."
  (alet* ((sock (db-sock))
          (query (r:r (:get-all
                        (:table "boards_personas_link")
                        board-id
                        :index (db-index "boards_personas_link" "board_id"))))
          (cursor (r:run sock query))
          (links (r:to-array sock cursor)))
    (r:stop/disconnect sock cursor)
    links))

(defafun get-board-persona-link (future) (board-id to-persona-id)
  "Given a board id and a persona being shared with, pull out the ID of the
   persona that owns the share."
  (alet* ((sock (db-sock))
          ;; TODO: index
          (query (r:r (:limit
                        (:filter
                          (:table "boards_personas_link")
                          (r:fn (board)
                            (:&& (:== (:attr board "board_id") board-id)
                                 (:== (:attr board "to") to-persona-id))))
                        1)))
          (cursor (r:run sock query))
          (links (r:to-array sock cursor)))
    (r:stop/disconnect sock cursor)
    (if (zerop (length links))
        (finish future nil)
        (finish future (aref links 0)))))

(defafun set-board-persona-permissions (future) (user-id board-id from-persona-id to-persona-id permission-value &key invite invite-remote)
  "Gives a persona permissions to view/update a board."
  (alet ((perms (get-user-board-permissions user-id board-id))
         ;; clamp permission value to 0 <= p <= 2
         (permission-value (min (max permission-value 0) 2)))
    (if (<= 3 perms)
        (if (zerop permission-value)
            (multiple-promise-bind (clear-perms sync-ids)
                (clear-board-persona-permissions user-id board-id from-persona-id to-persona-id)
              (finish future clear-perms nil sync-ids))
            (alet* ((sock (db-sock))
                    ;; create a link record for this share. note the
                    ;; deterministic `id`
                    (priv-entry `(("id" . ,(sha256 (concatenate 'string
                                                                board-id ":"
                                                                from-persona-id ":"
                                                                to-persona-id)))
                                  ("board_id" . ,board-id)
                                  ("from" . ,from-persona-id)
                                  ("to" . ,to-persona-id)
                                  ("perms" . ,permission-value)))
                    (priv-entry (cond (invite
                                        (append
                                          priv-entry
                                          `(("invite" . t))))
                                      (invite-remote
                                        (append
                                          priv-entry
                                          `(("email" . ,invite-remote))))
                                      (t
                                        priv-entry)))
                    (priv-record (convert-alist-hash priv-entry))
                    (query (r:r
                             (:insert
                               (:table "boards_personas_link")
                               priv-record
                               :upsert t)))
                    (nil (r:run sock query))
                    (user-ids (get-affected-users-from-board-ids (list board-id)))
                    (sync-ids (add-sync-record user-id "board" board-id "edit" :rel-ids user-ids)))
              (r:disconnect sock)
              (finish future permission-value priv-entry sync-ids)))
        (signal-error future (make-instance 'insufficient-privileges
                                            :msg "Sorry, you are editing a board you aren't a member of.")))))

(defafun get-link-from-persona-id (future) (board-id to-persona-id &key from-persona-id link)
  "Do our best to get a from persona ID."
  (if (stringp from-persona-id)
      (finish future from-persona-id)
      (alet* ((link (if link
                        link
                        (get-board-persona-link board-id to-persona-id))))
        (if link
            (finish future (gethash "from" link))
            (finish future nil)))))

(defafun clear-board-persona-permissions (future) (user-id board-id from-persona-id to-persona-id)
  "Clear out a persona's board permissions (revoke access)."
  (alet* ((from-persona-id (get-link-from-persona-id board-id to-persona-id :from-persona-id from-persona-id))
          ;; grab user ids *before* removing link, otherwise the deleted user
          ;; is left out in the cold >=]
          (user-ids (get-affected-users-from-board-ids (list board-id)))
          (sync-ids (add-sync-record user-id "board" board-id "edit" :rel-ids user-ids))
          (id (sha256 (concatenate 'string
                                   board-id ":"
                                   from-persona-id ":"
                                   to-persona-id)))
          (sock (db-sock))
          ;; TODO: delete based on ID. since we changed the id scheme a while
          ;; ago, some records have the new ids, some the old. for this reason
          ;; we must delete based on our data that derives the id instead of the
          ;; id itself.
          (query (r:r (:delete
                        (:filter
                          (:get-all
                            (:table "boards_personas_link")
                            board-id
                            :index (db-index "boards_personas_link" "board_id"))
                          (r:fn (l)
                            ;; TODO: why bother specifying from?
                            (:&& (:== from-persona-id (:attr l "from"))
                                 (:== to-persona-id (:attr l "to"))))))))
          (nil (r:run sock query)))
    (r:disconnect sock)
    (finish future 0 sync-ids)))

(defafun get-board-privs-entry (future) (board-id privs-entry-id)
  "Returns a privileges entry for the given privs entry id (usually a persona or
   invite id)."
  (alet* ((entry (get-board-persona-link board-id privs-entry-id)))
    (finish future entry)))

;;; ----------------------------------------------------------------------------
;;; obsolete
;;; ----------------------------------------------------------------------------

(defafun add-board-remote-invite (future) (user-id board-id from-persona-id invite-id permission-value to-email)
  "Creates a remote (ie email) invite permission record on a board so the
   recipient of an invite can join the board without knowing what their account
   will be in advance."
  (alet* ((email (obscure-email to-email)))
    (multiple-promise-bind (perm priv-entry sync-ids)
        (set-board-persona-permissions user-id board-id from-persona-id invite-id permission-value :invite-remote email)
      (finish future perm priv-entry sync-ids))))

(defafun accept-board-invite (future) (user-id board-id to-persona-id &key invite-id)
  "Mark a board invitation/privilege entry as accepted. Accepts a persona, but
   also an invite-id in the event the invite was sent over email, in which case
   its record id is updated with the given persona-id."
  (with-valid-persona (to-persona-id user-id future)
    (alet* ((entry-id (or invite-id to-persona-id))
            (sock (db-sock))
            (link (get-board-persona-link board-id entry-id)))
      (if link
          (alet* ((from-persona-id (get-link-from-persona-id board-id to-persona-id :link link))
                  (id (sha256 (concatenate 'string
                                           board-id ":"
                                           from-persona-id ":"
                                           to-persona-id)))
                  (nil (r:run sock (r:r (:delete (:get (:table "boards_personas_link") (gethash "id" link))))))
                  (nil (progn
                         (setf (gethash "id" link) id
                               (gethash "to" link) to-persona-id)
                         (remhash "invite" link)
                         (remhash "email" link)))
                  (query (r:r (:insert
                                (:table "boards_personas_link")
                                link)))
                  (nil (r:run sock query))
                  (user-ids (get-affected-users-from-board-ids (list board-id)))
                  (sync-ids (add-sync-record user-id "board" board-id "edit" :rel-ids user-ids)))
            (r:disconnect sock)
            (finish future sync-ids))
          (signal-error future (make-instance 'insufficient-privileges
                                              :msg "You are not invited to this board."))))))

(defafun leave-board-share (future) (user-id board-id persona-id &key invite-id)
  "Allows a user who is not board owner to remove themselves from the board. If
   an invite-id is specified, it will replace the persona-id (after persona
   verification, of course) when referencing which privs entry to lear out."
  (with-valid-persona (persona-id user-id future)
    (multiple-promise-bind (nil sync-ids)
        (clear-board-persona-permissions user-id board-id nil (or invite-id persona-id))
      (finish future sync-ids))))

