;;; telega-touch.el --- Touch screen (Android) tweaks for telega  -*- lexical-binding:t -*-

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

;; `telega-touch-mode' is a global minor mode improving telega
;; usability on touch screens (Android with Termux/Termux:X11, tablets,
;; touch laptops).  Emacs' mouse model assumes a precise pointer that
;; hovers; a finger taps, never hovers.  This mode adapts telega
;; buffers to that model:
;;
;;  - a single tap activates buttons and links (no double-tap needed)
;;  - a tap anywhere on a chat line in the root buffer opens that chat
;;  - smooth mouse-wheel/touchpad scrolling instead of page jumps
;;  - tooltips are suppressed, as they can never be dismissed by hand
;;  - a long press is sent by touch systems as mouse-3, which already
;;    opens telega's context menus, so nothing extra is needed there
;;
;; On touch devices the mode is auto-enabled at telega load, see
;; `telega-touch-auto-enable'.

;;; Code:
(require 'cl-lib)

(require 'telega-core)
(require 'telega-customize)

(eval-when-compile
  ;; Compile-time only, to avoid byte-compiler warnings
  (require 'telega-root)
  (require 'telega-chat))

(declare-function telega-chat-at "telega-core" (&optional pos))
(declare-function telega-chat-button-action "telega-root" (chat))

(defvar telega-root-mode-map)
(defvar telega-touch-mode)	; defined by `define-minor-mode' below

(defcustom telega-touch-auto-enable t
  "Non-nil to enable `telega-touch-mode' on touch devices at telega load.
Touch devices are detected by `telega-touch-device-p'."
  :package-version '(telega . "0.8.671")
  :type 'boolean
  :group 'telega-modes)

(defcustom telega-lite-auto-enable-on-touch t
  "Non-nil to also enable `telega-lite-mode' when a touch device is detected.
Phones and tablets are usually weak, so lite mode is a good default
there.  Only has effect together with `telega-touch-auto-enable'."
  :package-version '(telega . "0.8.671")
  :type 'boolean
  :group 'telega-modes)

(defun telega-touch-device-p ()
  "Return non-nil if Emacs runs on a touch device.
Detection is heuristic: Termux (Android) sets `TERMUX_VERSION'
environment variable, and touch terminals advertise themselves
via the `touch-screen' terminal parameter."
  (or (getenv "TERMUX_VERSION")
      (cl-loop for frame in (frame-list)
               thereis (terminal-parameter frame 'touch-screen))))

(defun telega-touch--root-mouse-1 (event)
  "Handle touch tap EVENT in the root buffer.
Tap on a button (chat title, folder, filter) is handled by Emacs
itself; this command makes a tap on any other part of a chat line
open that chat, same as pressing RET on it."
  (interactive "e")
  (mouse-set-point event)
  ;; Do not interfere when the tap landed on some button - buttons
  ;; are activated via `mouse-1-click-follows-link'
  (unless (button-at (point))
    (when-let ((chat (telega-chat-at (point))))
      (telega-chat-button-action chat))))

(defun telega-touch--setup-buffer ()
  "Apply touch tweaks to the current telega buffer."
  ;; A tap both positions point and shall follow the thing tapped
  (setq-local mouse-1-click-follows-link t)
  ;; Touchpads/touchscreens emit wheel events; make them scroll
  ;; line-by-line following the finger instead of jumping pages
  (setq-local scroll-conservatively 101)
  (setq-local mouse-wheel-progressive-speed nil)
  ;; Re-ensure the rootbuf binding, as `telega-touch-mode' could be
  ;; enabled before telega.el defined `telega-root-mode-map'
  (when (and telega-touch-mode (derived-mode-p 'telega-root-mode))
    (define-key telega-root-mode-map [mouse-1]
      #'telega-touch--root-mouse-1)))

(defun telega-touch--apply-buffers (setup)
  "Run SETUP function in each existing telega buffer."
  (dolist (buf (buffer-list))
    (with-current-buffer buf
      (when (derived-mode-p 'telega-root-mode 'telega-chat-mode)
        (funcall setup)))))

;;;###autoload
(define-minor-mode telega-touch-mode
  "Toggle telega touch screen (Android) usability mode.
Makes single taps activate buttons and links, taps on chat lines
open chats in the root buffer, enables smooth wheel scrolling and
disables tooltips.  See also `telega-lite-mode'."
  :init-value nil
  :global t
  :group 'telega-modes

  ;; Root buffer: tap anywhere on a chat line opens the chat.
  ;; NOTE: `telega-root-mode-map' exists only once telega is loaded;
  ;; passing nil to `define-key' removes the binding
  (when (boundp 'telega-root-mode-map)
    (define-key telega-root-mode-map [mouse-1]
      (when telega-touch-mode
        #'telega-touch--root-mouse-1)))

  (if telega-touch-mode
      (progn
        (add-hook 'telega-root-mode-hook #'telega-touch--setup-buffer)
        (add-hook 'telega-chat-mode-hook #'telega-touch--setup-buffer)
        (telega-touch--apply-buffers #'telega-touch--setup-buffer)
        ;; Tooltips pop up under a stale finger position and there is
        ;; no hover on a touch screen
        (when (fboundp 'tooltip-mode)
          (tooltip-mode 0)))

    (remove-hook 'telega-root-mode-hook #'telega-touch--setup-buffer)
    (remove-hook 'telega-chat-mode-hook #'telega-touch--setup-buffer)
    (telega-touch--apply-buffers
     (lambda ()
       (kill-local-variable 'mouse-1-click-follows-link)
       (kill-local-variable 'scroll-conservatively)
       (kill-local-variable 'mouse-wheel-progressive-speed)))
    ;; NOTE: tooltip is not turned back on - it is a global Emacs
    ;; setting, user can restore it with M-x tooltip-mode
    ))

(defun telega-touch-maybe-enable ()
  "Enable touch tweaks if we are on a touch device.
Called at telega load time, see `telega-touch-auto-enable'."
  (when (and telega-touch-auto-enable (telega-touch-device-p))
    (telega-touch-mode 1)
    (when (and telega-lite-auto-enable-on-touch
               (fboundp 'telega-lite-mode))
      (telega-lite-mode 1))))

(provide 'telega-touch)
;;; telega-touch.el ends here
