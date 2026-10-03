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
;; as usual (see `skk-zenz-learn-fallback').
;;
;; With `skk-zenz-rerank' set, the mode also merges the dictionary
;; programs into one `skk-zenz-rerank-search' entry, which reorders
;; dictionary candidates by how well zenz thinks they fit the context.
;; See docs/ARCHITECTURE.md for the design.

;;; Code:

(require 'skk)
(require 'cl-lib)
(require 'seq)
(require 'subr-x)

(defgroup skk-zenz nil
  "Kana-kanji conversion with the zenz language model."
  :group 'skk
  :prefix "skk-zenz-")

(defconst skk-zenz-protocol-version 2
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

(defcustom skk-zenz-long-candidates 5
  "Number of candidates to request for long readings."
  :type 'natnum)

(defcustom skk-zenz-fallback-candidates 5
  "Number of candidates to request after the dictionaries run out."
  :type 'natnum)

(defcustom skk-zenz-max-score-gap 8.0
  "Drop zenz candidates whose score trails the best by more than this.
Scores are log-probabilities.  Candidates far behind the best are mostly
broken text.  If nil, all candidates are kept."
  :type '(choice (const :tag "Keep all" nil) number))

(defcustom skk-zenz-context-length 40
  "Maximum number of characters of context to send on each side.
The left context is the text before the conversion target.  The right
context is the text after it, up to the end of the line.  Zero disables
context."
  :type 'natnum)

(defcustom skk-zenz-context-skip-non-japanese t
  "If non-nil, the left context skips lines without Japanese.
The line holding the conversion target is always used.  Earlier lines are
taken only if they contain kana or kanji, so code between paragraphs, such
as an Org source block, gives way to the text above it.  At most
`skk-zenz--context-max-lines' earlier lines are examined.  If nil, the left
context is simply the characters before the target."
  :type 'boolean)

(defcustom skk-zenz-reading-regexp "\\`[ぁ-ゖゝゞー、。・！？]+\\'"
  "Regexp that a reading must match to be sent to zenz.
Okuri-ari readings never match because they end with an ASCII letter, so
zenz does not convert them.  For reranking okuri-ari candidates, the
stem reading joined with the okurigana must match instead."
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

(defcustom skk-zenz-rerank nil
  "If non-nil, `skk-zenz-mode' reranks dictionary candidates with zenz.
Enabling the mode then replaces the first run of dictionary programs in
`skk-search-prog-list' (see `skk-zenz-rerank-programs') with one
`skk-zenz-rerank-search' entry, and disabling it restores them.  Set this
before enabling the mode."
  :type 'boolean)

(defcustom skk-zenz-rerank-programs
  '(skk-search-jisyo-file skk-search-cdb-jisyo skk-search-server
    skk-okuri-search skk-search-extra-jisyo-files)
  "Search functions whose entries `skk-zenz-rerank' merges and reranks."
  :type '(repeat function))

(defcustom skk-zenz-rerank-method 'promote
  "How zenz scores reorder dictionary candidates.
`promote' moves the candidate zenz likes best to the front when its score
beats that of the first candidate by more than
`skk-zenz-rerank-threshold'; the other candidates keep their order.
`mix' sorts candidates by zenz score minus `skk-zenz-rerank-weight' times
log(1 + dictionary rank)."
  :type '(choice (const :tag "Promote the best candidate" promote)
                 (const :tag "Sort by score and rank" mix)))

(defcustom skk-zenz-rerank-threshold 1.0
  "Log-probability margin needed to promote a candidate.
Used when `skk-zenz-rerank-method' is `promote'.  Larger values change
the first candidate less often."
  :type 'number)

(defcustom skk-zenz-rerank-weight 1.0
  "Weight of the dictionary rank when `skk-zenz-rerank-method' is `mix'.
Larger values keep candidates closer to dictionary order."
  :type 'number)

(defcustom skk-zenz-rerank-limit 20
  "Number of leading dictionary candidates that zenz scores.
Later candidates keep their positions."
  :type 'natnum)

(defcustom skk-zenz-rerank-timeout 0.3
  "Seconds to wait for scores before keeping dictionary order."
  :type 'number)

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

(defconst skk-zenz--context-max-lines 20
  "Earlier lines examined for the left context.
Used when `skk-zenz-context-skip-non-japanese' is non-nil.")

(defconst skk-zenz--japanese-regexp "[ぁ-ゖァ-ヺ一-鿿々]"
  "Regexp matching a kana or kanji character.")

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

(defvar skk-zenz--rerank-form nil
  "The `skk-zenz-rerank-search' entry `skk-zenz-mode' added, or nil.")

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

;; `skk-zenz--call' clears responses it did not ask for, so callers must
;; not nest requests.
(defun skk-zenz--call (request timeout)
  "Send REQUEST to the server and wait up to TIMEOUT seconds for the reply.
REQUEST is an alist of request fields other than `id'.  Return the
response as an alist, or nil on failure, timeout, or an error response."
  (when-let* ((proc (skk-zenz--ensure-process)))
    (let* ((id (setq skk-zenz--next-id (1+ skk-zenz--next-id)))
           (line (skk-zenz--json-encode (cons (cons 'id id) request)))
           (deadline (+ (float-time) timeout))
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
        (skk-zenz--log "no response for %S within %ss" (alist-get 'kana request) timeout)
        nil)
       ((alist-get 'error response)
        (message "skk-zenz: %s" (alist-get 'error response))
        nil)
       (t response)))))

(defun skk-zenz--drop-weak (candidates scores)
  "Return CANDIDATES without those far behind the best one.
SCORES are the log-probabilities of CANDIDATES, best first.  See
`skk-zenz-max-score-gap'.  If SCORES do not match CANDIDATES, keep all."
  (if (or (null skk-zenz-max-score-gap)
          (/= (length candidates) (length scores))
          (not (numberp (car scores))))
      candidates
    (let ((lowest (- (car scores) skk-zenz-max-score-gap)))
      (cl-loop for candidate in candidates
               for score in scores
               ;; The server writes an infinite score as null.
               when (and (numberp score) (>= score lowest))
               collect candidate))))

(defun skk-zenz--request (kana left right n)
  "Ask the server for N candidates for KANA with LEFT and RIGHT context.
Return a list of strings, or nil on failure or timeout."
  (when-let* ((response (skk-zenz--call
                         `((kana . ,kana) (left . ,left) (right . ,right) (n . ,n))
                         skk-zenz-timeout)))
    (seq-filter #'stringp
                (skk-zenz--drop-weak (alist-get 'candidates response)
                                     (alist-get 'scores response)))))

(defun skk-zenz--score (kana left right texts)
  "Return zenz scores of TEXTS as conversions of KANA in context.
LEFT and RIGHT are the context.  The result lists one log-probability per
text, in order, or is nil on failure or timeout."
  (when-let* ((response (skk-zenz--call
                         `((op . "score") (kana . ,kana) (left . ,left) (right . ,right)
                           (candidates . ,(vconcat texts)))
                         skk-zenz-rerank-timeout))
              (scores (alist-get 'scores response)))
    (when (= (length scores) (length texts))
      ;; The server writes an infinite score as null.
      (mapcar (lambda (score) (if (numberp score) score -1.0e+INF)) scores))))

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
        (if skk-zenz-context-skip-non-japanese
            (skk-zenz--japanese-left-context end)
          (buffer-substring-no-properties
           (max (point-min) (- end skk-zenz-context-length)) end))))))

(defun skk-zenz--japanese-left-context (end)
  "Return the left context ending at END, skipping lines without Japanese.
The text from the beginning of END's line to END is always used.  Earlier
lines are prepended while they fit, but only those containing kana or
kanji; at most `skk-zenz--context-max-lines' of them are examined.  The
result holds at most `skk-zenz-context-length' characters."
  (save-excursion
    (goto-char end)
    (let ((text (buffer-substring-no-properties (line-beginning-position) end))
          (examined 0))
      (forward-line 0)
      (while (and (< (length text) skk-zenz-context-length)
                  (< examined skk-zenz--context-max-lines)
                  (not (bobp)))
        (forward-line -1)
        (setq examined (1+ examined))
        (let ((line (buffer-substring-no-properties (point) (line-end-position))))
          (when (string-match-p skk-zenz--japanese-regexp line)
            (setq text (concat line "\n" text)))))
      (substring text (max 0 (- (length text) skk-zenz-context-length))))))

(defun skk-zenz--right-context (&optional skip)
  "Return the text after the conversion target, up to the end of the line.
SKIP characters right after the target, such as okurigana, are left out."
  (if (<= skk-zenz-context-length 0)
      ""
    (let* ((target-end (or (skk-zenz--marker-position skk-henkan-end-point) (point)))
           (eol (save-excursion (goto-char target-end) (line-end-position)))
           (beg (min (+ target-end (or skip 0)) eol))
           (end (min (+ beg skk-zenz-context-length) eol)))
      (buffer-substring-no-properties beg end))))

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

;;; Reranking

(defun skk-zenz--rerank-reading (key)
  "Return (READING . OKURIGANA) for scoring candidates of reading KEY.
For an okuri-nashi KEY, READING is KEY and OKURIGANA is empty.  For an
okuri-ari KEY such as \"かk\", READING joins the stem reading and
`skk-henkan-okurigana' (\"かく\"), and OKURIGANA is appended to each
candidate (\"書\" is scored as \"書く\").  Return nil if KEY may not be
reranked."
  (when (stringp key)
    (if (string-match "\\`\\([^a-z]+\\)[a-z]\\'" key)
        (let ((stem (match-string 1 key))
              (okurigana skk-henkan-okurigana))
          (when (and (stringp okurigana) (not (string-empty-p okurigana)))
            (let ((reading (concat stem okurigana)))
              (and (string-match-p skk-zenz-reading-regexp reading)
                   (cons reading okurigana)))))
      (and (null skk-okuri-char)
           (string-match-p skk-zenz-reading-regexp key)
           (cons key "")))))

(defun skk-zenz--scorable-text (word)
  "Return the text of dictionary candidate WORD to score, or nil.
Annotations are removed.  Lisp forms, which SKK evaluates, are not scored."
  (when (stringp word)
    (let ((text (car (skk-treat-strip-note-from-word word))))
      (unless (or (string-empty-p text)
                  (skk-lisp-prog-p text)
                  (string-match-p "\n" text))
        text))))

(defun skk-zenz--rerank-words (words scores)
  "Return WORDS reordered by SCORES, following `skk-zenz-rerank-method'.
SCORES is an alist of (WORD . SCORE); words without a score keep their
positions."
  (let ((score-of (lambda (word) (cdr (assq word scores)))))
    (pcase skk-zenz-rerank-method
      ('mix
       (let* ((vec (vconcat words))
              (slots (seq-filter (lambda (i) (funcall score-of (aref vec i)))
                                 (number-sequence 0 (1- (length vec)))))
              ;; `sort' is stable, so ties keep dictionary order.
              (ranked (sort (mapcar (lambda (i)
                                      (cons (- (funcall score-of (aref vec i))
                                               (* skk-zenz-rerank-weight (log (1+ i))))
                                            (aref vec i)))
                                    slots)
                            (lambda (a b) (> (car a) (car b))))))
         (cl-loop for slot in slots
                  for entry in ranked
                  do (aset vec slot (cdr entry)))
         (append vec nil)))
      (_
       (let ((first-score (funcall score-of (car words)))
             best best-score)
         (dolist (word words)
           (let ((score (funcall score-of word)))
             (when (and score (or (null best-score) (> score best-score)))
               (setq best word
                     best-score score))))
         (if (and first-score
                  (not (eq best (car words)))
                  (> (- best-score first-score) skk-zenz-rerank-threshold))
             (cons best (seq-remove (lambda (word) (eq word best)) words))
           words))))))

(defun skk-zenz--rerank (key words)
  "Return dictionary candidates WORDS for reading KEY reordered by zenz.
Return WORDS unchanged if KEY is not eligible or scoring fails."
  (if-let* (((cdr words))
            (reading (skk-zenz--rerank-reading key)))
      (let ((okurigana (cdr reading))
            (texts nil)
            (pairs nil))
        ;; Score each distinct text once; WORDS may hold the same text with
        ;; different annotations.
        (dolist (word (seq-take words skk-zenz-rerank-limit))
          (when-let* ((text (skk-zenz--scorable-text word)))
            (setq text (concat text okurigana))
            (unless (member text texts)
              (push text texts))
            (push (cons word text) pairs)))
        (setq texts (nreverse texts))
        (let ((scores (and (cdr texts)
                           ;; The okurigana follows the conversion target in
                           ;; the buffer and is part of the scored text.
                           (skk-zenz--score (car reading) (skk-zenz--left-context)
                                            (skk-zenz--right-context (length okurigana))
                                            texts))))
          (if (null scores)
              words
            (let* ((by-text (cl-mapcar #'cons texts scores))
                   (result (skk-zenz--rerank-words
                            words
                            (mapcar (lambda (pair)
                                      (cons (car pair) (cdr (assoc (cdr pair) by-text))))
                                    pairs))))
              (unless (equal result words)
                (skk-zenz--log "reranked %s: %S" key (seq-take result 5)))
              result))))
    words))

;;;###autoload
(defun skk-zenz-rerank-search (programs)
  "Merge the candidates of search PROGRAMS and rerank them with zenz.
PROGRAMS is a list of `skk-search-prog-list' entries, usually dictionary
searches.  All of them are evaluated at once, their candidates merged in
order without duplicates, and the result reordered by how well each
candidate fits the context according to zenz (see
`skk-zenz-rerank-method').  If zenz is unavailable, the merged candidates
are returned in dictionary order."
  (let (words)
    (dolist (program programs)
      ;; `skk-nunion' modifies its first argument; copy what programs return.
      (setq words (skk-nunion words (copy-sequence (eval program)))))
    (skk-zenz--rerank skk-henkan-key words)))

(defun skk-zenz--dictionary-form-p (form)
  "Return non-nil if search program FORM calls one of `skk-zenz-rerank-programs'."
  (memq (car-safe form) skk-zenz-rerank-programs))

(defun skk-zenz--wrap-dictionaries (programs)
  "Return PROGRAMS with the first run of dictionary programs merged.
The run is replaced by one `skk-zenz-rerank-search' entry, which is also
stored in `skk-zenz--rerank-form'.  Return PROGRAMS unchanged if it has
no dictionary program or already calls `skk-zenz-rerank-search'."
  (let ((start (cl-position-if #'skk-zenz--dictionary-form-p programs)))
    (if (or (null start)
            (seq-some (lambda (form) (eq (car-safe form) 'skk-zenz-rerank-search))
                      programs))
        programs
      (let ((end (or (cl-position-if-not #'skk-zenz--dictionary-form-p programs
                                         :start start)
                     (length programs))))
        (setq skk-zenz--rerank-form
              `(skk-zenz-rerank-search ',(seq-subseq programs start end)))
        (append (seq-take programs start)
                (list skk-zenz--rerank-form)
                (seq-drop programs end))))))

(defun skk-zenz--unwrap-dictionaries (programs)
  "Return PROGRAMS with the entry in `skk-zenz--rerank-form' expanded again."
  (prog1 (mapcan (lambda (form)
                   (if (eq form skk-zenz--rerank-form)
                       (copy-sequence (cadr (cadr form)))
                     (list form)))
                 programs)
    (setq skk-zenz--rerank-form nil)))

;;; Learning

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
readings get zenz candidates after the dictionary candidates.  If
`skk-zenz-rerank' is non-nil, dictionary candidates are also reordered
by zenz."
  :global t
  :group 'skk-zenz
  (if skk-zenz-mode
      (progn
        (unless (member skk-zenz--long-form skk-search-prog-list)
          (push skk-zenz--long-form skk-search-prog-list))
        (unless (member skk-zenz--fallback-form skk-search-prog-list)
          (setq skk-search-prog-list
                (append skk-search-prog-list (list skk-zenz--fallback-form))))
        (when skk-zenz-rerank
          (setq skk-search-prog-list (skk-zenz--wrap-dictionaries skk-search-prog-list)))
        (add-hook 'skk-search-excluding-word-pattern-function
                  #'skk-zenz--exclude-word-p)
        (advice-add 'skk-update-jisyo :filter-args #'skk-zenz--strip-annotation))
    (setq skk-search-prog-list
          (skk-zenz--unwrap-dictionaries
           (seq-remove (lambda (form)
                         (member form (list skk-zenz--long-form skk-zenz--fallback-form)))
                       skk-search-prog-list)))
    (remove-hook 'skk-search-excluding-word-pattern-function
                 #'skk-zenz--exclude-word-p)
    (advice-remove 'skk-update-jisyo #'skk-zenz--strip-annotation)
    (skk-zenz-stop)))

(provide 'skk-zenz)
;;; skk-zenz.el ends here
