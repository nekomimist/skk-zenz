;;; skk-zenz-test.el --- Tests for skk-zenz -*- lexical-binding: t -*-

;;; Commentary:

;; Most tests use tests/fake-zenz-server.el and need no model.  The test
;; tagged `model' uses the real server and model and is skipped unless
;; both exist.

;;; Code:

(require 'ert)
;; An installed DDSKK provides skk-autoloads (make install) or
;; ddskk-autoloads (package.el); the Makefile generates the former for a
;; source checkout.
(unless (require 'skk-autoloads nil t)
  (load "ddskk-autoloads" t t))
(require 'skk)
(require 'skk-zenz)

(defconst skk-zenz-test--directory
  (file-name-directory (or load-file-name buffer-file-name)))

(defconst skk-zenz-test--emacs
  (expand-file-name invocation-name invocation-directory))

(defmacro skk-zenz-test--with-server (env &rest body)
  "Run BODY with a fresh fake server started with environment ENV."
  (declare (indent 1))
  `(let ((skk-zenz-server-program skk-zenz-test--emacs)
         (skk-zenz-server-args
          (list "-Q" "--batch" "-l"
                (expand-file-name "fake-zenz-server.el" skk-zenz-test--directory)))
         (skk-zenz-model-file nil)
         (skk-zenz-annotation "zenz")
         (skk-zenz-min-length 10)
         (skk-zenz-context-length 40)
         (skk-zenz-timeout 3.0)
         (skk-zenz-startup-timeout 10.0)
         (skk-zenz-retry-interval 30)
         (skk-search-prog-list (list skk-zenz--long-form
                                     '(skk-search-jisyo-file skk-jisyo 0 t)
                                     skk-zenz--fallback-form))
         (process-environment (append ,env process-environment))
         (inhibit-message t))
     (skk-zenz-stop)
     (setq skk-zenz--last-failure nil)
     (unwind-protect
         (progn ,@body)
       (skk-zenz-stop)
       (setq skk-zenz--last-failure nil))))

(defmacro skk-zenz-test--with-henkan (text key &rest body)
  "Run BODY in a buffer holding TEXT during conversion of KEY.
TEXT must contain \"▼\" followed by KEY; point is left after KEY."
  (declare (indent 2))
  `(with-temp-buffer
     (insert ,text)
     (goto-char (point-min))
     (search-forward "▼")
     (let ((skk-henkan-key ,key)
           (skk-okuri-char nil)
           (skk-henkan-list nil)
           (skk-henkan-start-point (point-marker))
           (skk-henkan-end-point (progn (forward-char (length ,key)) (point-marker))))
       ,@body)))

(defun skk-zenz-test--search (key &optional trigger text)
  "Run `skk-zenz-search' for KEY with TRIGGER in a buffer holding TEXT."
  (skk-zenz-test--with-henkan (or text (concat "▼" key)) key
    (skk-zenz-search trigger)))

;;; Context

(ert-deftest skk-zenz-test-context ()
  (skk-zenz-test--with-henkan "前の文▼かいとう後ろの文\n次の行" "かいとう"
    (let ((skk-zenz-context-length 40))
      (should (equal (skk-zenz--left-context) "前の文"))
      (should (equal (skk-zenz--right-context) "後ろの文")))
    (let ((skk-zenz-context-length 2))
      (should (equal (skk-zenz--left-context) "の文"))
      (should (equal (skk-zenz--right-context) "後ろ")))
    (let ((skk-zenz-context-length 0))
      (should (equal (skk-zenz--left-context) ""))
      (should (equal (skk-zenz--right-context) "")))))

(ert-deftest skk-zenz-test-context-at-buffer-edges ()
  (skk-zenz-test--with-henkan "▼かな" "かな"
    (should (equal (skk-zenz--left-context) ""))
    (should (equal (skk-zenz--right-context) ""))))

;;; Eligibility

(ert-deftest skk-zenz-test-eligibility ()
  (let ((skk-zenz-min-length 5)
        (skk-okuri-char nil)
        (skk-search-prog-list (list skk-zenz--long-form skk-zenz--fallback-form)))
    (should (skk-zenz--eligible-p "きょうはいい" :long))
    (should-not (skk-zenz--eligible-p "きょう" :long))
    (should (skk-zenz--eligible-p "きょう" :fallback))
    ;; Long readings are left to the :long entry.
    (should-not (skk-zenz--eligible-p "きょうはいい" :fallback))
    (let ((skk-search-prog-list (list skk-zenz--fallback-form)))
      (should (skk-zenz--eligible-p "きょうはいい" :fallback)))
    (let ((skk-zenz-min-length nil))
      (should-not (skk-zenz--eligible-p "きょうはいい" :long))
      (should (skk-zenz--eligible-p "きょうはいい" :fallback)))
    ;; Okuri-ari, abbrev, and non-kana readings are not sent.
    (should-not (skk-zenz--eligible-p "かk" :fallback))
    (let ((skk-okuri-char "k"))
      (should-not (skk-zenz--eligible-p "か" :fallback)))
    (should-not (skk-zenz--eligible-p "abc" :fallback))
    (should-not (skk-zenz--eligible-p "" :fallback))
    (should-not (skk-zenz--eligible-p nil :fallback))))

;;; Search with the fake server

(ert-deftest skk-zenz-test-search-returns-annotated-candidates ()
  (skk-zenz-test--with-server nil
    (should (equal (skk-zenz-test--search "かな" :fallback)
                   '("かな-1;zenz" "かな-2;zenz" "かな-3;zenz" "かな-4;zenz" "かな-5;zenz")))
    (let ((skk-zenz-annotation nil)
          (skk-zenz-fallback-candidates 2))
      (should (equal (skk-zenz-test--search "かな" :fallback) '("かな-1" "かな-2"))))))

(ert-deftest skk-zenz-test-search-long-reading ()
  (skk-zenz-test--with-server nil
    (let ((key "きょうはいいてんきですね"))
      (should (equal (skk-zenz-test--search key :long)
                     (mapcar (lambda (i) (format "%s-%d;zenz" key i)) '(1 2 3))))
      (should-not (skk-zenz-test--search key :fallback))
      (should-not (skk-zenz-test--search "かな" :long)))))

(ert-deftest skk-zenz-test-search-sends-context ()
  (skk-zenz-test--with-server nil
    (should (equal (skk-zenz-test--search "ぶんみゃく" :fallback "左▼ぶんみゃく右\n下")
                   '("左|右;zenz")))))

(ert-deftest skk-zenz-test-search-filters-candidates ()
  (skk-zenz-test--with-server nil
    (skk-zenz-test--with-henkan "▼ふぃるた" "ふぃるた"
      (let ((skk-henkan-list '("既存;注釈")))
        (should (equal (skk-zenz-search :fallback) '("良い;zenz")))))))

(ert-deftest skk-zenz-test-search-records-candidates ()
  (skk-zenz-test--with-server nil
    (skk-zenz-test--with-henkan "▼かな" "かな"
      (let ((skk-zenz-fallback-candidates 2))
        (skk-zenz-search :fallback)
        (should (equal skk-zenz--candidates '("かな" :fallback ("かな-1" "かな-2"))))))))

;;; Failures

(ert-deftest skk-zenz-test-timeout ()
  (skk-zenz-test--with-server nil
    (let ((skk-zenz-timeout 0.2)
          (start (float-time)))
      (should-not (skk-zenz-test--search "おそい" :fallback))
      (should (< (- (float-time) start) 0.9)))
    ;; The late reply is discarded and the next request still works.
    (should (equal (skk-zenz-test--search "かな" :fallback)
                   '("かな-1;zenz" "かな-2;zenz" "かな-3;zenz" "かな-4;zenz" "かな-5;zenz")))))

(ert-deftest skk-zenz-test-error-response ()
  (skk-zenz-test--with-server nil
    (should-not (skk-zenz-test--search "えらー" :fallback))
    (should (skk-zenz-test--search "かな" :fallback))))

(ert-deftest skk-zenz-test-server-exit-and-retry ()
  (skk-zenz-test--with-server nil
    (should-not (skk-zenz-test--search "しぬ" :fallback))
    ;; Give the sentinel a chance to run.
    (accept-process-output nil 0.2)
    (should skk-zenz--last-failure)
    ;; Within the retry interval the server is not restarted.
    (should-not (skk-zenz-test--search "かな" :fallback))
    (should-not skk-zenz--process)
    (setq skk-zenz--last-failure nil)
    (should (skk-zenz-test--search "かな" :fallback))))

(ert-deftest skk-zenz-test-startup-failure ()
  (skk-zenz-test--with-server '("FAKE_ZENZ_FAIL=1")
    (should-not (skk-zenz-test--search "かな" :fallback))
    (should skk-zenz--last-failure)))

(ert-deftest skk-zenz-test-missing-program ()
  (skk-zenz-test--with-server nil
    (let ((skk-zenz-server-program "/nonexistent/zenz-server"))
      (should-not (skk-zenz-test--search "かな" :fallback))
      (should skk-zenz--last-failure))))

(ert-deftest skk-zenz-test-protocol-mismatch ()
  (skk-zenz-test--with-server '("FAKE_ZENZ_PROTOCOL=999")
    (should-not (skk-zenz-test--search "かな" :fallback))
    (should skk-zenz--last-failure)
    (should-not skk-zenz--ready)))

;;; Learning exclusion

(ert-deftest skk-zenz-test-learning ()
  (let ((skk-zenz-annotation "zenz")
        (skk-zenz-learn-fallback t)
        (skk-henkan-key "かな")
        (skk-zenz--candidates '("かな" :long ("仮名" "カナ")))
        (skk-search-excluding-word-pattern-function nil))
    (add-hook 'skk-search-excluding-word-pattern-function #'skk-zenz--exclude-word-p)
    ;; Words from long-reading candidates are never learned.
    (should-not (skk-update-jisyo-p "仮名;zenz"))
    (let ((skk-zenz-learn-fallback nil))
      (should-not (skk-update-jisyo-p "仮名;zenz")))
    ;; Same word from a dictionary (no zenz annotation) is learned.
    (should (skk-update-jisyo-p "仮名"))
    (should (skk-update-jisyo-p "仮名;辞書の注釈"))
    (should (skk-update-jisyo-p "金;zenz"))
    (let ((skk-henkan-key "べつ"))
      (should (skk-update-jisyo-p "仮名;zenz")))
    (let ((skk-zenz-annotation nil))
      (should-not (skk-update-jisyo-p "仮名"))
      (should (skk-update-jisyo-p "金")))
    ;; Words from fallback candidates are learned unless disabled.
    (let ((skk-zenz--candidates '("かな" :fallback ("仮名"))))
      (should (skk-update-jisyo-p "仮名;zenz"))
      (let ((skk-zenz-learn-fallback nil))
        (should-not (skk-update-jisyo-p "仮名;zenz"))))))

(ert-deftest skk-zenz-test-strip-annotation ()
  (let ((skk-zenz-annotation "zenz")
        (skk-henkan-key "かな")
        (skk-zenz--candidates '("かな" :fallback ("仮名"))))
    (should (equal (skk-zenz--strip-annotation '("仮名;zenz" nil)) '("仮名" nil)))
    ;; Words that did not come from zenz keep their annotation.
    (should (equal (skk-zenz--strip-annotation '("仮名;辞書" nil)) '("仮名;辞書" nil)))
    (should (equal (skk-zenz--strip-annotation '("金;zenz")) '("金;zenz")))
    (let ((skk-zenz-annotation nil))
      (should (equal (skk-zenz--strip-annotation '("仮名")) '("仮名"))))))

;;; Minor mode

(ert-deftest skk-zenz-test-mode-installs-and-removes ()
  (let ((skk-search-prog-list '((skk-search-jisyo-file skk-jisyo 0 t)))
        (skk-search-excluding-word-pattern-function nil)
        (skk-zenz-mode nil))
    (skk-zenz-mode 1)
    (unwind-protect
        (progn
          (should (equal (car skk-search-prog-list) skk-zenz--long-form))
          (should (equal (car (last skk-search-prog-list)) skk-zenz--fallback-form))
          (should (memq #'skk-zenz--exclude-word-p
                        skk-search-excluding-word-pattern-function))
          (should (advice-member-p #'skk-zenz--strip-annotation 'skk-update-jisyo))
          ;; Enabling twice does not add duplicates.
          (skk-zenz-mode 1)
          (should (= (length skk-search-prog-list) 3)))
      (skk-zenz-mode -1))
    (should (equal skk-search-prog-list '((skk-search-jisyo-file skk-jisyo 0 t))))
    (should-not (memq #'skk-zenz--exclude-word-p
                      skk-search-excluding-word-pattern-function))
    (should-not (advice-member-p #'skk-zenz--strip-annotation 'skk-update-jisyo))))

;;; SKK integration

(defun skk-zenz-test--type (prefix keys)
  "Insert PREFIX, type KEYS in SKK mode, and confirm the candidate.
Return (BUFFER-TEXT HENKAN-LIST) with the list as it was before confirming."
  (let ((buffer (generate-new-buffer "*skk-zenz-test*")))
    (unwind-protect
        (progn
          (switch-to-buffer buffer)
          (insert prefix)
          (skk-mode 1)
          (execute-kbd-macro (kbd keys))
          (let ((henkan-list skk-henkan-list))
            (skk-kakutei)
            (list (buffer-string) henkan-list)))
      (kill-buffer buffer))))

(ert-deftest skk-zenz-test-skk-integration ()
  (skip-unless (fboundp 'skk-cus-setup))
  (let* ((dir (make-temp-file "skk-zenz-test" t))
         (skk-user-directory dir)
         (skk-jisyo (expand-file-name "jisyo" dir))
         (skk-backup-jisyo (expand-file-name "jisyo.bak" dir))
         (skk-record-file (expand-file-name "record" dir))
         (skk-init-file (expand-file-name "init" dir))
         (skk-large-jisyo (expand-file-name "L.jisyo" dir))
         (skk-jisyo-code 'utf-8)
         (skk-show-annotation nil)
         (skk-show-inline nil)
         (skk-show-tooltip nil)
         (skk-egg-like-newline t))
    (with-temp-file skk-large-jisyo
      (insert ";; okuri-ari entries.\n;; okuri-nasi entries.\nきしゃ /汽車/\n"))
    ;; DDSKK pauses to announce files it creates, so create them up front.
    (dolist (file (list skk-jisyo skk-record-file))
      (write-region "" nil file))
    (unwind-protect
        (skk-zenz-test--with-server nil
          (let ((skk-search-prog-list
                 (list skk-zenz--long-form
                       '(skk-search-jisyo-file skk-jisyo 0 t)
                       '(skk-search-jisyo-file skk-large-jisyo 10000)
                       skk-zenz--fallback-form))
                (skk-search-excluding-word-pattern-function
                 (list #'skk-zenz--exclude-word-p))
                (skk-zenz-learn-fallback t))
            (advice-add 'skk-update-jisyo :filter-args #'skk-zenz--strip-annotation)
            ;; Dictionary hit: zenz is not consulted.
            (should (equal (skk-zenz-test--type "" "K i s h a SPC")
                           '("汽車" ("汽車"))))
            ;; Past the dictionary candidates, zenz candidates follow.
            (should (equal (car (skk-zenz-test--type "" "K i s h a SPC SPC"))
                           "きしゃ-1"))
            ;; Dictionary miss: context comes from the buffer, without ▼.
            (should (equal (skk-zenz-test--type "左" "B u n m y a k u SPC")
                           '("左左|" ("左|;zenz"))))
            ;; Long reading: zenz first.
            (should (equal (car (cadr (skk-zenz-test--type
                                       "" "K y o u h a i i t e n k i d e s u n e SPC")))
                           "きょうはいいてんきですね-1;zenz"))
            ;; Dictionary and fallback words were learned, without the zenz
            ;; annotation; the long-reading word was not.
            (let ((jisyo (with-current-buffer (skk-get-jisyo-buffer skk-jisyo 'nomsg)
                           (buffer-string))))
              (should (string-match-p "^きしゃ /きしゃ-1/汽車/$" jisyo))
              (should (string-match-p "^ぶんみゃく /左|/$" jisyo))
              (should-not (string-match-p "zenz\\|てんき" jisyo)))))
      (advice-remove 'skk-update-jisyo #'skk-zenz--strip-annotation)
      (when-let* ((buffer (skk-get-jisyo-buffer skk-jisyo 'nomsg)))
        (with-current-buffer buffer (set-buffer-modified-p nil))
        (kill-buffer buffer))
      (delete-directory dir t))))

;;; Real server (opt-in)

(ert-deftest skk-zenz-test-real-server ()
  :tags '(model)
  (let ((program (expand-file-name "../build/zenz-server" skk-zenz-test--directory))
        (model (getenv "ZENZ_MODEL")))
    (skip-unless (and (file-executable-p program) model (file-readable-p model)))
    (skk-zenz-test--with-server nil
      (let ((skk-zenz-server-program program)
            (skk-zenz-server-args nil)
            (skk-zenz-model-file model))
        (should (equal (car (skk-zenz-test--search "かいとう" :fallback "試験問題の▼かいとう"))
                       "解答;zenz"))
        (should (equal (car (skk-zenz-test--search "かいとう" :fallback
                                                   "冷凍食品を電子レンジで▼かいとう"))
                       "解凍;zenz"))))))

;;; skk-zenz-test.el ends here
