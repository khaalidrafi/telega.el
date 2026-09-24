;;; telega-lite.el --- Lite mode for telega  -*- lexical-binding:t -*-

;; Copyright (C) 2018-2026 by Zajcev Evgeny.

;; Author: telega.el contributors
;; Created: Wed Sep 24 2026
;; Keywords: comm

;; telega is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; telega is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with telega.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; `telega-lite-mode' is a global minor mode that trades eye-candy for
;; speed.  It is designed for weak hardware (old laptops, phones and
;; tablets running Emacs, e.g. Android with Termux) where rendering
;; images, SVG avatars and animations dominates CPU time.
;;
;; Enable it BEFORE loading telega for the full effect, because some
;; telega options compute their default values from `telega-use-images'
;; at load time:
;;
;;   (telega-lite-mode 1)   ; in your init.el, before (require 'telega)
;;
;; Enabling/disabling it at runtime still re-renders the existing
;; telega buffers, so the change is visible immediately.

;;; Code:
(require 'cl-lib)
(require 'ewoc)

;; NOTE: telega-lite.el could be autoloaded without the rest of telega
;; being loaded yet (e.g. enabled from init.el), so the code below is
;; careful to only use heavy modules when telega is actually up
(require 'telega-core)
(require 'telega-customize)

(eval-when-compile
  ;; Pull root/filter machinery at compile time only, to avoid
  ;; byte-compiler warnings about unknown functions and macros
  (require 'telega-root)
  (require 'telega-filter))

(declare-function telega-root-aux-redisplay "telega-root" (&optional item))
(declare-function telega-filters--redisplay "telega-filter")
(declare-function telega-chatbuf--redisplay-node "telega-chat" (node))

(defvar telega-root--view)
(defvar telega-filters--dirty)

(defcustom telega-lite-presets
  '((telega-use-images . nil)                 ; no photos/stickers/previews
    (telega-emoji-use-images . nil)           ; emoji as font glyphs, not SVG
    (telega-use-svg-base-uri . nil)           ; no embedded SVG machinery
    (telega-use-one-line-preview-for . nil)   ; no photo/video one-line previews
    (telega-root-show-avatars . nil)          ; SVG avatar generation is one
    (telega-user-show-avatars . nil)          ; of the biggest CPU sinks,
    (telega-chat-show-avatars . nil)          ; kill them all
    (telega-completions-username-show-avatars . nil)
    (telega-active-locations-show-avatars . nil)
    (telega-sticker-animated-play . nil)      ; no animated stickers
    (telega-emoji-animated-play . nil)
    (telega-animation-play-inline . nil)
    (telega-animation-download-saved . nil)
    (telega-status-animate-interval . 1.5)    ; less rootbuf redisplay timers
    (telega-idle-delay . 1.0)
    (telega-chat-history-limit . 10)          ; less messages per opened chat
    (telega-chat-buffers-limit . 5)           ; less live chat buffers
    (telega-webpage-history-max . 10))        ; less shared links to render
  "Alist of (VARIABLE . VALUE) pairs applied by `telega-lite-mode'.
Customize it to fine tune what lite mode changes."
  :package-version '(telega . "0.8.671")
  :type '(alist :key-type symbol :value-type sexp)
  :group 'telega)

(defcustom telega-lite-disable-blink-cursor t
  "Non-nil to stop the blinking cursor while `telega-lite-mode' is on.
Blinking cursor schedules constant redisplay, which is pure waste
on slow hardware.  Original state is restored when lite mode is
turned off."
  :type 'boolean
  :group 'telega)

(defvar telega-lite--saved-values nil
  "Saved original values of `telega-lite-presets' variables.
Used to restore them when `telega-lite-mode' is disabled.")
(put 'telega-lite--saved-values 'risky-local-variable t)

(defvar telega-lite--saved-blink-cursor nil
  "Blinking cursor state before `telega-lite-mode' was enabled.")

(defun telega-lite--redisplay ()
  "Re-render telega's buffers, so lite settings take effect at once.
Does nothing if telega itself is not loaded/started."
  ;; `telega-root--buffer' is undefined when only telega-lite.el got
  ;; autoloaded (lite mode enabled before telega load)
  (when (and (fboundp 'telega-root--buffer) (telega-root--buffer))
    (with-current-buffer (telega-root--buffer)
      (telega-save-cursor
        ;; Status line, mode-line filters and folders may embed images
        (telega-root-aux-redisplay)
        (let ((telega-filters--dirty t))
          (telega-filters--redisplay))
        ;; Every chat button with its avatars and message previews
        (dolist (ewoc-spec (nthcdr 2 telega-root--view))
          (with-telega-root-view-ewoc (plist-get ewoc-spec :name) ewoc
            (ewoc-refresh ewoc))))))

  ;; Every rendered message in every opened chat buffer
  (when (fboundp 'telega-chatbuf--redisplay-node)
    (dolist (cbuf (telega-chat-buffers))
      (with-current-buffer cbuf
        (when (and (local-variable-p 'telega-chatbuf--ewoc)
                   telega-chatbuf--ewoc)
          (telega-save-cursor
            (let ((node (ewoc-nth telega-chatbuf--ewoc 0)))
              (while node
                (telega-chatbuf--redisplay-node node)
                (setq node (ewoc-next telega-chatbuf--ewoc node))))))))))

;;;###autoload
(define-minor-mode telega-lite-mode
  "Toggle telega lite mode, a low overhead configuration of telega.
When enabled, telega renders chats and messages as plain text:
no images, no SVG avatars, no animations, with slower timers and
smaller history limits.  See `telega-lite-presets' for the exact
list of the variables affected.

NOTE: enable it before loading telega for the full effect, as some
telega options derive their defaults from `telega-use-images' at
load time."
  :init-value nil
  :global t
  :group 'telega-modes

  (cond (telega-lite-mode
         ;; Do not clobber saved values when re-enabling
         (unless telega-lite--saved-values
           (setq telega-lite--saved-values
                 ;; NOTE: some preset variables may be still undefined
                 ;; when lite mode is enabled before telega load
                 (mapcar (lambda (preset)
                           (list (car preset)
                                 (if (boundp (car preset))
                                     (default-value (car preset)))))
                         telega-lite-presets))
           (when (and telega-lite-disable-blink-cursor
                      (fboundp 'blink-cursor-mode))
             ;; `blink-cursor-mode' variable is undefined until
             ;; blink-cursor.el gets loaded
             (setq telega-lite--saved-blink-cursor
                   (and (boundp 'blink-cursor-mode) blink-cursor-mode))
             (blink-cursor-mode 0)))
         (dolist (preset telega-lite-presets)
           ;; NOTE: `set' is used instead of `setq-default', as the
           ;; symbol to set is computed
           (set (car preset) (cdr preset))))

        (t
         (dolist (saved telega-lite--saved-values)
           (set (car saved) (cadr saved)))
         (setq telega-lite--saved-values nil)
         (when (and telega-lite--saved-blink-cursor
                    (fboundp 'blink-cursor-mode))
           (blink-cursor-mode 1))
         (setq telega-lite--saved-blink-cursor nil)))

  (telega-lite--redisplay))

(provide 'telega-lite)
;;; telega-lite.el ends here
