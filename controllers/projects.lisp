(in-package :tagit)

(defroute (:get "/api/projects/users/([0-9a-f-]+)") (req res args)
  (catch-errors (res)
    (let ((user-id (car args)))
      (unless (string= (user-id req) user-id)
        (error 'insufficient-privileges :msg "You are trying to access another user's projects. For shame."))
      (alet* ((projects (get-user-projects user-id)))
        (send-json res projects)))))

(defroute (:post "/api/projects/users/([0-9a-f-]+)") (req res args)
  (catch-errors (res)
    (alet* ((user-id (car args))
            (project-data (post-var req "data")))
      (unless (string= (user-id req) user-id)
        (error 'insufficient-privileges :msg "You are trying to access another user's projects. For shame."))
      (alet ((project (add-project user-id project-data)))
        (send-json res project)))))

(defroute (:put "/api/projects/([0-9a-f-]+)") (req res args)
  (catch-errors (res)
    (alet* ((user-id (user-id req))
            (project-id (car args))
            (project-data (post-var req "data")))
      (alet ((project (edit-project user-id project-id project-data)))
        (send-json res project)))))

(defroute (:delete "/api/projects/([0-9a-f-]+)") (req res args)
  (catch-errors (res)
    (alet* ((project-id (car args))
            (user-id (user-id req))
            (nil (delete-project user-id project-id)))
      (send-json res t))))
