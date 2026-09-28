;;; fake-zenz-server.el --- Fake zenz-server for ERT tests -*- lexical-binding: t -*-

;;; Commentary:

;; Run with: emacs -Q --batch -l tests/fake-zenz-server.el
;;
;; Speaks the zenz-server JSON Lines protocol without a model.  For a
;; request with reading KANA and N candidates it returns KANA-1 .. KANA-N,
;; except for these readings:
;;
;;   ふぃるた  candidates that the client must filter out
;;   おそい    sleeps 1 second before answering
;;   えらー    returns an error response
;;   しぬ      exits without answering
;;   ぶんみゃく returns "LEFT|RIGHT" as the only candidate
;;
;; FAKE_ZENZ_PROTOCOL overrides the protocol version in the hello line.
;; FAKE_ZENZ_FAIL makes the server exit with an error before the hello.

;;; Code:

(defun fake-zenz--print (object)
  "Write OBJECT as one JSON line to stdout."
  (let ((json (json-serialize object)))
    (princ (if (multibyte-string-p json) json (decode-coding-string json 'utf-8)))
    (princ "\n")))

(defun fake-zenz--candidates (kana left right n)
  "Return the candidate vector for KANA, LEFT, RIGHT and N."
  (pcase kana
    ("ふぃるた" (vector "" "ふぃるた" "a;b" "(foo)" "改行\nあり" "良い" "良い" "既存"))
    ("ぶんみゃく" (vector (format "%s|%s" left right)))
    (_ (apply #'vector
              (mapcar (lambda (i) (format "%s-%d" kana i)) (number-sequence 1 n))))))

(when (getenv "FAKE_ZENZ_FAIL")
  (message "error: failed to load model: fake")
  (kill-emacs 1))

(fake-zenz--print
 `((hello . "zenz-server")
   (protocol . ,(string-to-number (or (getenv "FAKE_ZENZ_PROTOCOL") "2")))))

(condition-case nil
    (while t
      (let* ((request (json-parse-string (read-from-minibuffer "")
                                         :object-type 'alist :null-object nil))
             (id (alist-get 'id request))
             (kana (alist-get 'kana request))
             (left (or (alist-get 'left request) ""))
             (right (or (alist-get 'right request) ""))
             (n (or (alist-get 'n request) 1)))
        (pcase kana
          ("しぬ" (kill-emacs 3))
          ("えらー" (fake-zenz--print `((id . ,id) (error . "fake error"))))
          (_
           (when (equal kana "おそい")
             (sleep-for 1))
           (fake-zenz--print
            `((id . ,id) (candidates . ,(fake-zenz--candidates kana left right n))))))))
  (end-of-file nil))

;;; fake-zenz-server.el ends here
