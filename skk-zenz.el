;;; skk-zenz.el --- Neural kana-kanji conversion for DDSKK with zenz -*- lexical-binding: t -*-

;; Copyright (C) 2026 Hiroyuki Ishikura

;; Author: Hiroyuki Ishikura
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (ddskk "17.1"))
;; Keywords: i18n, input method, japanese
;; SPDX-License-Identifier: MIT

;;; Commentary:

;; skk-zenz adds conversion candidates from the zenz language model to
;; DDSKK.  The model runs locally in `zenz-server', a separate process
;; that skk-zenz starts on first use and talks to over a pipe.
;;
;; Enable it with:
;;
;;   (require 'skk-zenz)
;;   (skk-zenz-mode 1)
;;
;; `skk-zenz-mode' adds two entries to `skk-search-prog-list':
;;
;; - At the head, `(skk-zenz-search :long)' converts readings of at
;;   least `skk-zenz-min-length' characters before any dictionary.
;; - At the tail, `(skk-zenz-search :fallback)' offers candidates after
;;   the dictionary candidates run out, before dictionary registration.
;;
;; Words confirmed from zenz candidates for long readings are not added
;; to the personal dictionary; words from fallback candidates are learned
;; as usual (see `skk-zenz-learn-fallback').  See docs/ARCHITECTURE.md
;; for the design.

;;; Code:

(require 'skk)
(require 'seq)
(require 'subr-x)

(defgroup skk-zenz nil
  "Kana-kanji conversion with the zenz language model."
  :group 'skk
  :prefix "skk-zenz-")

(defconst skk-zenz-protocol-version 1
  "Protocol version this client speaks.  Must match `zenz-server'.")

(defconst skk-zenz--directory
  (file-name-directory (or load-file-name buffer-file-name default-directory))
  "Directory skk-zenz was loaded from.")

(defcustom skk-zenz-server-program
  (let ((local (expand-file-name "build/zenz-server" skk-zenz--directory)))
    (if (file-executable-p local) local "zenz-server"))
  "Path to the `zenz-server' executable."
  :type 'string)

(defcustom skk-zenz-model-file
  (let ((local (expand-file-name "models/zenz-v3.2-small-Q5_K_M.gguf"
                                 skk-zenz--directory)))
    (and (file-readable-p local) local))
  "Path to the zenz GGUF model.
If nil, `zenz-server' uses the ZENZ_MODEL environment variable."
  :type '(choice (const :tag "Use $ZENZ_MODEL" nil) file))

(defcustom skk-zenz-server-args nil
  "Extra command line arguments for `zenz-server', such as (\"--threads\" \"8\")."
  :type '(repeat string))

(defcustom skk-zenz-min-length 10
  "Minimum reading length for `(skk-zenz-search :long)'.
Readings at least this long are converted by zenz before any dictionary.
Shorter readings reach zenz only after the dictionaries.  If nil, zenz is
never consulted first."
  :type '(choice (const :tag "Never first" nil) natnum))

(defcustom skk-zenz-long-candidates 3
  "Number of candidates to request for long readings."
  :type 'natnum)

(defcustom skk-zenz-fallback-candidates 5
  "Number of candidates to request after the dictionaries run out."
  :type 'natnum)

(defcustom skk-zenz-context-length 40
  "Maximum number of characters of context to send on each side.
The left context is the text before the conversion target.  The right
context is the text after it, up to the end of the line.  Zero disables
context."
  :type 'natnum)

(defcustom skk-zenz-reading-regexp "\\`[ぁ-ゖゝゞー、。・！？]+\\'"
  "Regexp that a reading must match to be sent to zenz.
Okuri-ari readings never match because they end with an ASCII letter."
  :type 'regexp)

(defcustom skk-zenz-annotation "zenz"
  "Annotation attached to zenz candidates, or nil for none."
  :type '(choice (const :tag "None" nil) string))

(defcustom skk-zenz-learn-fallback t
  "If non-nil, words confirmed from fallback candidates are learned.
Fallback candidates are those offered after the dictionary candidates.
Such words are added to the personal dictionary without the zenz
annotation, so the next conversion of the reading finds them there.
Words confirmed from candidates for long readings (see
`skk-zenz-min-length') are never learned."
  :type 'boolean)

(defcustom skk-zenz-timeout 1.0
  "Seconds to wait for a conversion before giving up."
  :type 'number)

(defcustom skk-zenz-startup-timeout 5.0
  "Seconds to wait for `zenz-server' to load the model."
  :type 'number)

(defcustom skk-zenz-retry-interval 30
  "Seconds to wait before starting `zenz-server' again after a failure."
  :type 'number)

(defcustom skk-zenz-debug nil
  "If non-nil, log protocol traffic and failures to *Messages*."
  :type 'boolean)

(defvar skk-zenz--process nil
  "The `zenz-server' process, or nil.")

(defvar skk-zenz--ready nil
  "Non-nil once the server has sent a compatible hello line.")

(defvar skk-zenz--next-id 0
  "ID of the last request sent.")

(defvar skk-zenz--responses (make-hash-table)
  "Responses received but not yet consumed, keyed by request ID.")

(defvar skk-zenz--last-failure nil
  "Time of the last server failure, as returned by `float-time'.")

(defvar-local skk-zenz--candidates nil
  "Candidates zenz returned for the last reading, as (READING TRIGGER WORDS).
Used to decide whether a confirmed word is learned.")

(defconst skk-zenz--long-form '(skk-zenz-search :long)
  "Entry `skk-zenz-mode' adds to the head of `skk-search-prog-list'.")

(defconst skk-zenz--fallback-form '(skk-zenz-search :fallback)
  "Entry `skk-zenz-mode' adds to the tail of `skk-search-prog-list'.")

(defun skk-zenz--log (format-string &rest args)
  "Log FORMAT-STRING with ARGS when `skk-zenz-debug' is non-nil."
  (when skk-zenz-debug
    (apply #'message (concat "skk-zenz: " format-string) args)))

(defun skk-zenz--fail (reason)
  "Record a server failure for REASON and tell the user."
  (setq skk-zenz--last-failure (float-time))
  (message "skk-zenz: %s" reason))

(defun skk-zenz--stderr-tail ()
  "Return the last line the server wrote to stderr, or nil."
  (let ((buf (get-buffer " *zenz-server stderr*")))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (let ((text (string-trim (buffer-string))))
          (unless (string-empty-p text)
            (car (last (split-string text "\n")))))))))

;;; Process management

(defun skk-zenz--command ()
  "Return the command line for `zenz-server'."
  (append (list skk-zenz-server-program)
          skk-zenz-server-args
          (and skk-zenz-model-file
               (list "--model" (expand-file-name skk-zenz-model-file)))))

(defun skk-zenz--start ()
  "Start `zenz-server' without waiting for it to become ready."
  (let ((stderr (get-buffer-create " *zenz-server stderr*"))
        (buffer (get-buffer-create " *zenz-server*")))
    (with-current-buffer stderr (erase-buffer))
    (with-current-buffer buffer (erase-buffer))
    (setq skk-zenz--ready nil)
    (clrhash skk-zenz--responses)
    (setq skk-zenz--process
          (make-process :name "zenz-server"
                        :buffer buffer
                        :command (skk-zenz--command)
                        :connection-type 'pipe
                        :coding 'utf-8-unix
                        :noquery t
                        :stderr stderr
                        :filter #'skk-zenz--filter
                        :sentinel #'skk-zenz--sentinel))))

(defun skk-zenz--filter (proc string)
  "Collect output STRING from PROC and handle each complete line."
  (let ((buffer (process-buffer proc)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (goto-char (point-max))
        (insert string)
        (goto-char (point-min))
        (while (search-forward "\n" nil t)
          (let ((line (buffer-substring-no-properties (point-min) (1- (point)))))
            (delete-region (point-min) (point))
            (skk-zenz--handle-line proc line)))))))

(defun skk-zenz--handle-line (proc line)
  "Handle one LINE of output from PROC."
  (skk-zenz--log "<- %s" line)
  (let ((msg (condition-case nil
                 (json-parse-string line :object-type 'alist
                                    :array-type 'list
                                    :null-object nil
                                    :false-object nil)
               (json-error nil))))
    (cond
     ((not (consp msg))
      (skk-zenz--log "ignoring unexpected output: %s" line))
     ((assq 'hello msg)
      (let ((version (alist-get 'protocol msg)))
        (if (eql version skk-zenz-protocol-version)
            (setq skk-zenz--ready t)
          (skk-zenz--fail (format "protocol mismatch (server %s, client %s); rebuild zenz-server"
                                  version skk-zenz-protocol-version))
          (delete-process proc))))
     (t
      (let ((id (alist-get 'id msg)))
        (when (integerp id)
          (puthash id msg skk-zenz--responses)))))))

(defun skk-zenz--sentinel (proc event)
  "Handle EVENT for PROC."
  (unless (process-live-p proc)
    (when (eq proc skk-zenz--process)
      (let ((was-ready skk-zenz--ready))
        (setq skk-zenz--process nil
              skk-zenz--ready nil)
        ;; Startup failures are reported by `skk-zenz--ensure-process'.
        (when was-ready
          (skk-zenz--fail (format "zenz-server exited: %s%s"
                                  (string-trim event)
                                  (if-let* ((tail (skk-zenz--stderr-tail)))
                                      (concat " (" tail ")")
                                    ""))))))))

(defun skk-zenz--ensure-process ()
  "Return a ready `zenz-server' process, starting it if needed.
Return nil if the server cannot be started or failed recently."
  (cond
   ((and (process-live-p skk-zenz--process) skk-zenz--ready)
    skk-zenz--process)
   ((and skk-zenz--last-failure
         (< (- (float-time) skk-zenz--last-failure) skk-zenz-retry-interval))
    nil)
   (t
    (let ((started (float-time)))
      (unless (process-live-p skk-zenz--process)
        (condition-case err
            (skk-zenz--start)
          (error
           (skk-zenz--fail (format "cannot start %s: %s"
                                   skk-zenz-server-program (error-message-string err))))))
      (let ((proc skk-zenz--process)
            (deadline (+ (float-time) skk-zenz-startup-timeout)))
        (while (and (process-live-p proc)
                    (not skk-zenz--ready)
                    (< (float-time) deadline))
          (accept-process-output proc 0.05 nil t))
        (cond
         (skk-zenz--ready proc)
         ((process-live-p proc)
          (skk-zenz--fail "zenz-server did not become ready in time")
          (skk-zenz-stop)
          nil)
         (proc
          ;; A protocol mismatch has already been reported.
          (unless (and skk-zenz--last-failure (>= skk-zenz--last-failure started))
            (skk-zenz--fail (format "zenz-server failed to start%s"
                                    (if-let* ((tail (skk-zenz--stderr-tail)))
                                        (concat ": " tail)
                                      ""))))
          nil)))))))

(defun skk-zenz-stop ()
  "Stop `zenz-server'."
  (interactive)
  (let ((proc skk-zenz--process))
    (setq skk-zenz--process nil
          skk-zenz--ready nil)
    (when (process-live-p proc)
      (delete-process proc))))

(defun skk-zenz-restart ()
  "Restart `zenz-server' and clear any recorded failure."
  (interactive)
  (skk-zenz-stop)
  (setq skk-zenz--last-failure nil)
  (when (skk-zenz--ensure-process)
    (message "skk-zenz: zenz-server is ready")))

(defun skk-zenz--json-encode (object)
  "Encode OBJECT as a JSON string.
Emacs 30 and later return a unibyte UTF-8 string from `json-serialize';
decode it so the process coding system encodes it exactly once."
  (let ((json (json-serialize object)))
    (if (multibyte-string-p json)
        json
      (decode-coding-string json 'utf-8))))

(defun skk-zenz--request (kana left right n)
  "Ask the server for N candidates for KANA with LEFT and RIGHT context.
Return a list of strings, or nil on failure or timeout."
  (when-let* ((proc (skk-zenz--ensure-process)))
    (let* ((id (setq skk-zenz--next-id (1+ skk-zenz--next-id)))
           (line (skk-zenz--json-encode
                  `((id . ,id) (kana . ,kana) (left . ,left) (right . ,right) (n . ,n))))
           (deadline (+ (float-time) skk-zenz-timeout))
           response)
      (skk-zenz--log "-> %s" line)
      (process-send-string proc (concat line "\n"))
      (while (and (not (setq response (gethash id skk-zenz--responses)))
                  (process-live-p proc)
                  (< (float-time) deadline))
        (accept-process-output proc 0.01 nil t))
      ;; Requests are sequential, so anything else here is a late reply.
      (clrhash skk-zenz--responses)
      (cond
       ((null response)
        (skk-zenz--log "no response for %S within %ss" kana skk-zenz-timeout)
        nil)
       ((alist-get 'error response)
        (message "skk-zenz: %s" (alist-get 'error response))
        nil)
       (t
        (seq-filter #'stringp (alist-get 'candidates response)))))))

;;; SKK integration

(defun skk-zenz--marker-position (marker)
  "Return the position of MARKER if it points into the current buffer."
  (and (markerp marker)
       (eq (marker-buffer marker) (current-buffer))
       (marker-position marker)))

(defun skk-zenz--left-context ()
  "Return the text before the conversion target, without the ▽/▼ marker."
  (let ((start (skk-zenz--marker-position skk-henkan-start-point)))
    (if (or (null start) (<= skk-zenz-context-length 0))
        ""
      (let ((end (if (memq (char-before start) '(?▽ ?▼)) (1- start) start)))
        (buffer-substring-no-properties
         (max (point-min) (- end skk-zenz-context-length)) end)))))

(defun skk-zenz--right-context ()
  "Return the text after the conversion target, up to the end of the line."
  (if (<= skk-zenz-context-length 0)
      ""
    (let* ((beg (or (skk-zenz--marker-position skk-henkan-end-point) (point)))
           (end (min (+ beg skk-zenz-context-length)
                     (save-excursion (goto-char beg) (line-end-position)))))
      (buffer-substring-no-properties beg (max beg end)))))

(defun skk-zenz--eligible-p (key trigger)
  "Return non-nil if reading KEY should be sent to zenz for TRIGGER."
  (and (stringp key)
       (null skk-okuri-char)
       (string-match-p skk-zenz-reading-regexp key)
       (let ((long (and skk-zenz-min-length
                        (>= (length key) skk-zenz-min-length))))
         (pcase trigger
           (:long long)
           ;; Long readings were already handled by the :long entry.
           (_ (not (and long (member skk-zenz--long-form skk-search-prog-list))))))))

(defun skk-zenz--existing-words ()
  "Return the candidates already in `skk-henkan-list', without annotations."
  (mapcar (lambda (candidate)
            (car (skk-treat-strip-note-from-word
                  (if (consp candidate) (car candidate) candidate))))
          skk-henkan-list))

(defun skk-zenz--filter-candidates (key candidates)
  "Remove CANDIDATES that SKK cannot show safely or that add nothing for KEY."
  (let ((existing (skk-zenz--existing-words))
        result)
    (dolist (candidate candidates)
      (unless (or (string-empty-p candidate)
                  (string= candidate key)
                  ;; ";" starts an annotation, and "(...)" would be evaluated.
                  (string-match-p "[;\n\uFFFD]" candidate)
                  (skk-lisp-prog-p candidate)
                  (member candidate existing)
                  (member candidate result))
        (push candidate result)))
    (nreverse result)))

;;;###autoload
(defun skk-zenz-search (&optional trigger)
  "Return zenz candidates for `skk-henkan-key', for `skk-search-prog-list'.
TRIGGER is :long for the entry at the head of the list and :fallback for
the entry at the tail."
  (let ((key skk-henkan-key)
        (trigger (or trigger :fallback)))
    (when (skk-zenz--eligible-p key trigger)
      (let* ((n (if (eq trigger :long)
                    skk-zenz-long-candidates
                  skk-zenz-fallback-candidates))
             (words (skk-zenz--filter-candidates
                     key
                     (skk-zenz--request key (skk-zenz--left-context)
                                        (skk-zenz--right-context) n))))
        (setq skk-zenz--candidates (list key trigger words))
        (if skk-zenz-annotation
            (mapcar (lambda (word) (concat word ";" skk-zenz-annotation)) words)
          words)))))

(defun skk-zenz--word-trigger (word)
  "Return the trigger (:long or :fallback) if confirmed WORD came from zenz.
WORD may carry an annotation.  Return nil for words from elsewhere."
  (let* ((pair (skk-treat-strip-note-from-word word))
         (candidate (car pair))
         (note (cdr pair)))
    (pcase-let ((`(,key ,trigger ,words) skk-zenz--candidates))
      (and (equal key skk-henkan-key)
           (member candidate words)
           ;; With annotations on, an unannotated word came from a dictionary.
           (or (null skk-zenz-annotation) (equal note skk-zenz-annotation))
           trigger))))

(defun skk-zenz--exclude-word-p (word)
  "Return non-nil if confirmed WORD should not be learned.
Used in `skk-search-excluding-word-pattern-function'."
  (pcase (skk-zenz--word-trigger word)
    (:long t)
    (:fallback (not skk-zenz-learn-fallback))))

(defun skk-zenz--strip-annotation (args)
  "Remove the zenz annotation from the word in ARGS of `skk-update-jisyo'.
DDSKK stores the confirmed word with its annotation, which would make
learned words show the zenz annotation when they later come from the
personal dictionary."
  (let ((word (car args)))
    (if (and skk-zenz-annotation (stringp word) (skk-zenz--word-trigger word))
        (cons (car (skk-treat-strip-note-from-word word)) (cdr args))
      args)))

;;;###autoload
(define-minor-mode skk-zenz-mode
  "Toggle zenz candidates in DDSKK conversion.
When enabled, long readings are converted by zenz first, and other
readings get zenz candidates after the dictionary candidates."
  :global t
  :group 'skk-zenz
  (if skk-zenz-mode
      (progn
        (unless (member skk-zenz--long-form skk-search-prog-list)
          (push skk-zenz--long-form skk-search-prog-list))
        (unless (member skk-zenz--fallback-form skk-search-prog-list)
          (setq skk-search-prog-list
                (append skk-search-prog-list (list skk-zenz--fallback-form))))
        (add-hook 'skk-search-excluding-word-pattern-function
                  #'skk-zenz--exclude-word-p)
        (advice-add 'skk-update-jisyo :filter-args #'skk-zenz--strip-annotation))
    (setq skk-search-prog-list
          (seq-remove (lambda (form)
                        (member form (list skk-zenz--long-form skk-zenz--fallback-form)))
                      skk-search-prog-list))
    (remove-hook 'skk-search-excluding-word-pattern-function
                 #'skk-zenz--exclude-word-p)
    (advice-remove 'skk-update-jisyo #'skk-zenz--strip-annotation)
    (skk-zenz-stop)))

(provide 'skk-zenz)
;;; skk-zenz.el ends here
