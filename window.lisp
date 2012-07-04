;; Copyright (C) 2003-2008 Shawn Betts
;; Copyright (C) 2010-2012 Alexander aka CosmonauT Vynnyk
;;
;;  This file is part of dswm.
;;
;; dswm is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 2, or (at your option)
;; any later version.

;; dswm is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this software; see the file COPYING.  If not, write to
;; the Free Software Foundation, Inc., 59 Temple Place, Suite 330,
;; Boston, MA 02111-1307 USA

;; Commentary:
;;
;; Window functionality.
;;
;; Code:

(in-package #:dswm)

(export '(*default-window-name*
          define-window-slot
          set-normal-gravity
          set-maxsize-gravity
          set-transient-gravity
          set-window-geometry
	  next-urgent
	  delete-window
	  delete
	  kill-window
	  kill
	  title
	  rename-window
	  select-window
	  select
	  select-window-by-name
	  select-window-by-number
	  other-window
	  other
	  renumber
	  number
	  repack-window-numbers
	  windowlist
	  window-send-string
	  insert
	  mark
	  clear-window-marks
	  clear-marks
	  echo-windows
	  windows
	  refresh
	  place-existing-windows))

(defclass window ()
  ((xwin    :initarg :xwin    :accessor window-xwin)
   (width   :initarg :width   :accessor window-width)
   (height  :initarg :height  :accessor window-height)
   ;; these are only used to hold the requested map location.
   (x       :initarg :x       :accessor window-x)
   (y       :initarg :y       :accessor window-y)
   (gravity :initform nil     :accessor window-gravity)
   (group   :initarg :group   :accessor window-group)
   (number  :initarg :number  :accessor window-number)
   (parent                    :accessor window-parent)
   (title   :initarg :title   :accessor window-title)
   (user-title :initform nil  :accessor window-user-title)
   (tags    :initform nil     :accessor window-tags)
   (class   :initarg :class   :accessor window-class)
   (type    :initarg :type    :accessor window-type)
   (res     :initarg :res     :accessor window-res)
   (role    :initarg :role    :accessor window-role)
   (unmap-ignores :initarg :unmap-ignores :accessor window-unmap-ignores)
   (state   :initarg :state   :accessor window-state)
   (normal-hints :initarg :normal-hints :accessor window-normal-hints)
   (marked  :initform nil     :accessor window-marked)
   (plist   :initarg :plist   :accessor window-plist)
   (fullscreen :initform nil  :accessor window-fullscreen)
   (hints :initform nil :initarg :wm-hints :accessor window-hints)))

(defmethod print-object ((object window) stream)
  (format stream "#S(~a ~s #x~x)" (type-of object) (window-name object) (window-id object)))

;;; Window Management API

(defgeneric update-decoration (window)
  (:documentation "Update the window decoration."))
(defgeneric focus-window (window)
  (:documentation "Give the specified window keyboard focus."))
(defgeneric raise-window (window)
  (:documentation "Bring the window to the top of the window stack."))
(defgeneric window-visible-p (window)
  (:documentation "Return T if the window is visible"))
(defgeneric window-sync (window what-changed)
  (:documentation "Some window slot has been updated and the window
may need to sync itself. WHAT-CHANGED is a hint at what changed."))
(defgeneric window-head (window)
  (:documentation "Report what window the head is currently on."))

;; Urgency / demands attention

(defun register-urgent-window (window)
  "Add WINDOW to its screen's list of urgent windows"
  (if (eq (screen-current-window (window-screen window)) window)
      ;; window is already current, clear the urgent state to let it know we know.
      (window-clear-urgency window)
      (progn
        (push window (screen-urgent-windows (window-screen window)))
        (update-mode-lines (window-screen window))
        (values t))))

(defun unregister-urgent-window (window)
  "Remove WINDOW to its screen's list of urgent windows"
  (setf (screen-urgent-windows (window-screen window))
        (delete window (screen-urgent-windows (window-screen window))))
  (update-mode-lines (window-screen window)))

(defun window-clear-urgency (window)
  "Clear the urgency bit and/or _NET_WM_STATE_DEMANDS_ATTENTION on
WINDOW"
  (let* ((hints (xlib:wm-hints (window-xwin window)))
         (flags (when hints (xlib:wm-hints-flags hints))))
    (when flags
      (setf (xlib:wm-hints-flags hints)
            ;; XXX: as of clisp 2.46 flags is a list, not a number.
            (if (listp flags)
                (remove :urgency flags)
                (logand (lognot 256) flags)))
      (setf (xlib:wm-hints (window-xwin window)) hints)))
  (remove-wm-state (window-xwin window) :_NET_WM_STATE_DEMANDS_ATTENTION)
  (unregister-urgent-window window))

(defun window-urgent-p (window)
  "Returns T if WINDOW has the urgency bit and/or
_NET_WM_STATE_DEMANDS_ATTENTION set"
  (let* ((hints (xlib:wm-hints (window-xwin window)))
         (flags (when hints (xlib:wm-hints-flags hints))))
    ;; XXX: as of clisp 2.46 flags is a list, not a number.
    (or (and flags (if (listp flags)
                       (find :urgency flags)
                       (logtest 256 flags)))
        (find-wm-state (window-xwin window) :_NET_WM_STATE_DEMANDS_ATTENTION))))

(defun only-urgent (windows)
  "Return a list of all urgent windows on SCREEN"
  (remove-if-not 'window-urgent-p (copy-list windows)))

(defcommand next-urgent () ()
            "Jump to the next urgent window"
            (and (screen-urgent-windows (current-screen))
                 (focus-all (first (screen-urgent-windows (current-screen))))))

;; Since DSWM already uses the term 'group' to refer to Virtual Desktops,
;; we'll call the grouped windows of an application a 'gang'

;; maybe follow transient_for to find leader.
(defun window-leader (window)
  (when window
    (or (first (window-property window :WM_CLIENT_LEADER))
        (let ((id (window-transient-for window)))
          (when id
            (window-leader (window-by-id id)))))))

;; A modal dialog can either shadow a single window, or all windows
;; in its gang, depending on the value of WM_TRANSIENT_FOR

;; If a window is shadowed by a modal dialog, so are any other
;; transients belonging to that window.

(defun window-transient-for (window)
  (first (window-property window :WM_TRANSIENT_FOR)))

(defun window-modal-p (window)
  (find-wm-state (window-xwin window) :_NET_WM_STATE_MODAL))

(defun window-transient-p (window)
  (find (window-type window) '(:transient :dialog)))

;; FIXME: use WM_HINTS.group_leader
(defun window-gang (window)
  "Return a list of other windows in WINDOW's gang."
  (let ((leader (window-leader window))
        (screen (window-screen window)))
    (when leader
      (loop for w in (screen-windows screen)
            as l = (window-leader w)
            if (and (not (eq w window)) l (= leader l))
            collect w))))

(defun only-modals (windows)
  "Out of WINDOWS, return a list of those which are modal."
  (remove-if-not 'window-modal-p (copy-list windows)))

(defun x-of (window filter)
  (let* ((root (screen-root (window-screen window)))
         (root-id (xlib:drawable-id root))
         (win-id (xlib:window-id (window-xwin window))))
    (loop for w in (funcall filter (window-gang window))
          as tr = (window-transient-for w)
          when (or (not tr)             ; modal for group
                   (eq tr root-id)      ; ditto
                   (eq tr win-id))      ; modal for win
          collect w)))


;; The modals of a transient are the modals of the window
;; the transient belongs to.
(defun modals-of (window)
  "Given WINDOW return the modal dialogs which are shadowing it, if any."
  (loop for m in (only-modals (window-gang window))
        when (find window (shadows-of m))
        collect m))

(defun transients-of (window)
  "Return the transient dialogs belonging to WINDOW"
  (x-of window 'only-transients))

(defun shadows-of (window)
  "Given modal window WINDOW return the list of windows in its shadow."
  (let* ((root (screen-root (window-screen window)))
         (root-id (xlib:drawable-id root))
         (tr (window-transient-for window)))
    (cond
      ((or (not tr)
           (eq tr root-id))
       (window-gang window))
      (t
       (let ((w (window-by-id tr)))
         (append (list w) (transients-of w)))))))

(defun only-transients (windows)
  "Out of WINDOWS, return a list of those which are transient."
  (remove-if-not 'window-transient-p (copy-list windows)))

(defun all-windows ()
  (mapcan (lambda (s) (copy-list (screen-windows s))) *screen-list*))

(defun visible-windows ()
  "Return a list of visible windows (on all screens)"
  (loop for s in *screen-list*
        nconc (delete-if 'window-hidden-p (copy-list (group-windows (screen-current-group s))))))

(defun top-windows ()
  "Return a list of semantically visible windows (on all screens)"
  (loop for s in *screen-list*
        nconc (delete-if-not 'window-visible-p (copy-list (group-windows (screen-current-group s))))))

(defun window-name (window)
  (or (window-user-title window)
      (case *window-name-source*
        (:resource-name (window-res window))
        (:class (window-class window))
        (t (window-title window)))
      *default-window-name*))

(defun window-id (window)
  (xlib:window-id (window-xwin window)))

(defun window-in-current-group-p (window)
  (eq (window-group window)
      (screen-current-group (window-screen window))))

(defun window-screen (window)
  (group-screen (window-group window)))

(defun send-client-message (window type &rest data)
  "Send a client message to a client's window."
  (xlib:send-event (window-xwin window)
                   :client-message nil
                   :window (window-xwin window)
                   :type type
                   :format 32
                   :data data))

(defun window-map-number (window)
  (let ((num (window-number window)))
    (or (and (< num (length *window-number-map*))
             (elt *window-number-map* num))
        num)))

(defun fmt-window-status (window)
  (let ((group (window-group window)))
    (cond ((eq window (group-current-window group))
           #\*)
          ((and (typep (second (group-windows group)) 'window)
                (eq window (second (group-windows group))))
           #\+)
          (t #\-))))

(defun fmt-window-marked (window)
  (if (window-marked window)
      #\#
      #\Space))

;; (defun draw-window-mark (group window)
;;   "Draw the number of each frame in its corner. Return the list of
;; windows used to draw the numbers in. The caller must destroy them."
;;   (let ((screen (group-screen group)))
;;     (mapcar (lambda (f)
;;               (let ((w (xlib:create-window
;;                         :parent (screen-root screen)
;;                         :x (frame-x f) :y (frame-display-y group f) :width 1 :height 1
;;                         :background (screen-fg-color screen)
;;                         :border (screen-border-color screen)
;;                         :border-width 1
;;                         :event-mask '())))
;;                 (xlib:map-window w)
;;                 (setf (xlib:window-priority w) :above)
;;                 (echo-in-window w (screen-font screen)
;;                                 (screen-fg-color screen)
;;                                 (screen-bg-color screen)
;;                                 (string (get-frame-number-translation f)))
;;                 (xlib:display-finish-output *display*)
;;                 (dformat 3 "mapped ~S~%" (frame-number f))
;;                 w))
;;             (group-frames group))))

;; (defun clear-window-mark (group window)
;;   "Draw the number of each frame in its corner. Return the list of
;; windows used to draw the numbers in. The caller must destroy them."
;;   (let ((screen (group-screen group)))
;;     (mapcar (lambda (f)
;;               (let ((w (xlib:create-window
;;                         :parent (screen-root screen)
;;                         :x (frame-x f) :y (frame-display-y group f) :width 1 :height 1
;;                         :background (screen-fg-color screen)
;;                         :border (screen-border-color screen)
;;                         :border-width 1
;;                         :event-mask '())))
;;                 (xlib:map-window w)
;;                 (setf (xlib:window-priority w) :above)
;;                 (echo-in-window w (screen-font screen)
;;                                 (screen-fg-color screen)
;;                                 (screen-bg-color screen)
;;                                 (string (get-frame-number-translation f)))
;;                 (xlib:display-finish-output *display*)
;;                 (dformat 3 "mapped ~S~%" (frame-number f))
;;                 w))
;;             (group-frames group))))

;; (defun update-window-mark (window)
;;   "Called when we need to draw or clear the mark."
;;   ;; FIXME: This doesn't work at all. I'd like to have little squares
;;   ;; that look like clamps on the corners of the window, likes its
;;   ;; sorta grabbed. But i dunno how to properly draw them.
;;   (let* ((screen (window-screen window)))
;;     (if (window-marked window)
;;      (xlib:draw-rectangle (window-parent window) (screen-marked-gc (window-screen window))
;;                           0 0 300 200 t)
;;      (xlib:clear-area (window-parent window)))))

(defun get-normalized-normal-hints (xwin)
  (macrolet ((validate-hint (fn)
               (setf fn (intern1 (concatenate 'string (string '#:wm-size-hints-) (string fn)) :xlib))
               `(setf (,fn hints) (and (,fn hints)
                                       (plusp (,fn hints))
                                       (,fn hints)))))
    (let ((hints (xlib:wm-normal-hints xwin)))
      (when hints
        (validate-hint :min-width)
        (validate-hint :min-height)
        (validate-hint :max-width)
        (validate-hint :max-height)
        (validate-hint :base-width)
        (validate-hint :base-height)
        (validate-hint :width-inc)
        (validate-hint :height-inc)
        (validate-hint :min-aspect)
        (validate-hint :max-aspect))
      hints)))

(defun xwin-net-wm-name (win)
  "Return the netwm wm name"
  (let ((name (xlib:get-property win :_NET_WM_NAME)))
    (when name
      (utf8-to-string name))))

(defun xwin-name (win)
  (or
   (xwin-net-wm-name win)
   (xlib:wm-name win)))

;; FIXME: should we raise the winodw or its parent?
(defmethod raise-window (win)
  "Map the window if needed and bring it to the top of the stack. Does not affect focus."
  (when (window-urgent-p win)
    (window-clear-urgency win))
  (when (window-hidden-p win)
    (unhide-window win)
    (update-configuration win))
  (when (window-in-current-group-p win)
    (setf (xlib:window-priority (window-parent win)) :top-if)))

;; some handy wrappers

(defun xwin-border-width (win)
  (xlib:drawable-border-width win))

(defun (setf xwin-border-width) (width win)
  (setf (xlib:drawable-border-width win) width))

(defun default-border-width-for-type (window)
  (or (and (window-maxsize-p (window-xwin window))
           *maxsize-border-width*)
      (ecase (window-type window)
        (:dock 0)
        (:normal *normal-border-width*)
        ((:transient :dialog) *transient-border-width*))))

(defun xwin-class (win)
  (multiple-value-bind (res class) (xlib:get-wm-class win)
    (declare (ignore res))
    class))

(defun xwin-res-name (win)
  (multiple-value-bind (res class) (xlib:get-wm-class win)
    (declare (ignore class))
    res))

(defun xwin-role (win)
  "Return WM_WINDOW_ROLE"
  (let ((name (xlib:get-property win :WM_WINDOW_ROLE)))
    (dformat 10 "role: ~a~%" name)
    (if name
        (utf8-to-string name)
        "")))

(defmacro define-window-slot (attr)
  "Create a new window attribute and corresponding get/set functions."
  (let ((win (gensym))
        (val (gensym)))
    `(progn
      (defun ,(intern1 (format nil "WINDOW-~a" attr)) (,win)
        (gethash ,attr (window-plist ,win)))
      (defun (setf ,(intern1 (format nil "WINDOW-~a" attr))) (,val ,win)
        (setf (gethash ,attr (window-plist ,win))) ,val))))

(defun sort-windows (group)
  "Return a copy of the screen's window list sorted by usage (emacs-like behavior)"
  (let ((win-list
	 (sort1 (group-windows group) '< :key 'window-state)))
    (cond
     ((< 2 (length win-list))
      (cons (cadr win-list)
    	    (cons (car win-list) (cddr win-list))))
     ((> 2 (length win-list))
      win-list)
     (t
      (reverse win-list)))))

(defun sort-windows-by-number (group)
  "Return a copy of the screen's window list sorted by number."
  (sort1 (group-windows group) '< :key 'window-number))

(defun marked-windows (group)
  "Return the marked windows in the specified group."
  (loop for i in (sort-windows-by-number group)
        when (window-marked i)
        collect i))

(defun (setf xwin-state) (state xwin)
  "Set the state (iconic, normal, withdrawn) of a window."
  (xlib:change-property xwin
                        :WM_STATE
                        (list state)
                        :WM_STATE
                        32))

(defun xwin-state (xwin)
  "Get the state (iconic, normal, withdraw of a window."
  (first (xlib:get-property xwin :WM_STATE)))

(defun window-hidden-p (window)
  (eql (window-state window) +iconic-state+))

(defun add-wm-state (xwin state)
  (xlib:change-property xwin :_NET_WM_STATE
                        (list (xlib:find-atom *display* state))
                        :atom 32
                        :mode :append))

(defun remove-wm-state (xwin state)
  (xlib:change-property xwin :_NET_WM_STATE
                        (delete (xlib:find-atom *display* state) (xlib:get-property xwin :_NET_WM_STATE))
                        :atom 32))

(defun window-property (window prop)
  (xlib:get-property (window-xwin window) prop))

(defun find-wm-state (xwin state)
  (find (xlib:find-atom *display* state) (xlib:get-property xwin :_NET_WM_STATE) :test #'=))

(defun xwin-unhide (xwin parent)
  (xlib:map-subwindows parent)
  (xlib:map-window parent)
  (setf (xwin-state xwin) +normal-state+))

(defun unhide-window (window)
  (when (window-in-current-group-p window)
    (xwin-unhide (window-xwin window) (window-parent window)))
  (setf (window-state window) +normal-state+)
  ;; Mark window as unhiden
  (remove-wm-state (window-xwin window) :_NET_WM_STATE_HIDDEN))

;; Despite the naming convention, this function takes a window struct,
;; not an xlib:window.
(defun xwin-hide (window)
  (declare (type window window))
  (unless (eq (xlib:window-map-state (window-xwin window)) :unmapped)
    (setf (xwin-state (window-xwin window)) +iconic-state+)
    (incf (window-unmap-ignores window))
    (xlib:unmap-window (window-parent window))
    (xlib:unmap-subwindows (window-parent window))))

(defun hide-window (window)
  (dformat 2 "hide window: ~s~%" window)
  (unless (eql (window-state window) +iconic-state+)
    (setf (window-state window) +iconic-state+)
    ;; Mark window as hidden
    (add-wm-state (window-xwin window) :_NET_WM_STATE_HIDDEN)
    (when (window-in-current-group-p window)
      (xwin-hide window)
      (when (eq window (current-window))
        (group-lost-focus (window-group window))))))

(defun window-maxsize-p (win)
  "Returns T if WIN specifies maximum dimensions."
  (let ((hints (get-normalized-normal-hints win)))
    (and hints (or (xlib:wm-size-hints-max-width hints)
                   (xlib:wm-size-hints-max-height hints)
                   (xlib:wm-size-hints-min-aspect hints)
                   (xlib:wm-size-hints-max-aspect hints)))))

(defun xwin-type (win)
  "Return one of :desktop, :dock, :toolbar, :utility, :splash,
:dialog, :transient, and :normal.  Right now
only :dock, :dialog, :normal, and :transient are
actually returned; see +NETWM-WINDOW-TYPES+."
  (or (let ((net-wm-window-type (xlib:get-property win :_NET_WM_WINDOW_TYPE)))
        (when net-wm-window-type
          (dolist (type-atom net-wm-window-type)
            (when (assoc (xlib:atom-name *display* type-atom) +netwm-window-types+)
              (return (cdr (assoc (xlib:atom-name *display* type-atom) +netwm-window-types+)))))))
      (and (xlib:get-property win :WM_TRANSIENT_FOR)
           :transient)
      :normal))

(defun xwin-strut (screen win)
  "Return the area that the window wants to reserve along the edges of the screen.
Values are left, right, top, bottom, left_start_y, left_end_y,
right_start_y, right_end_y, top_start_x, top_end_x, bottom_start_x
and bottom_end_x."
  (let ((net-wm-strut-partial (xlib:get-property win :_NET_WM_STRUT_PARTIAL)))
    (if (= (length net-wm-strut-partial) 12)
        (apply 'values net-wm-strut-partial)
        (let ((net-wm-strut (xlib:get-property win :_NET_WM_STRUT)))
          (if (= (length net-wm-strut) 4)
              (apply 'values (concatenate 'list net-wm-strut
                                          (list 0 (screen-height screen)
                                                0 (screen-height screen)
                                                0 (screen-width screen)
                                                0 (screen-width screen))))
              (values 0 0 0 0 0 0 0 0 0 0 0 0))))))

;; Stolen from Eclipse
(defun xwin-send-configuration-notify (xwin x y w h bw)
  "Send a synthetic configure notify event to the given window (ICCCM 4.1.5)"
  (xlib:send-event xwin :configure-notify nil
                   :event-window xwin
                   :window xwin
                   :x x :y y
                   :width w
                   :height h
                   :border-width bw
                   :propagate-p nil))

(defun update-window-gravity ()
  (dolist (s *screen-list*)
    (dolist (g (screen-groups s))
      (mapc 'maximize-window (group-windows g)))))

(defun set-normal-gravity (gravity)
  "Set the default gravity for normal windows. Possible values are
@code{:center} @code{:top} @code{:left} @code{:right} @code{:bottom}
@code{:top-left} @code{:top-right} @code{:bottom-left} and
@code{:bottom-right}."
  (setf *normal-gravity* gravity)
  (update-window-gravity))

(defun set-maxsize-gravity (gravity)
  "Set the default gravity for maxsize windows."
  (setf *maxsize-gravity* gravity)
  (update-window-gravity))

(defun set-transient-gravity (gravity)
  "Set the default gravity for transient/pop-up windows."
  (setf *transient-gravity* gravity)
  (update-window-gravity))

(defun gravity-for-window (win)
  (or (window-gravity win)
      (and (window-maxsize-p (window-xwin win)) *maxsize-gravity*)
      (ecase (window-type win)
        (:dock *normal-gravity*)
        (:normal *normal-gravity*)
        ((:transient :dialog) *transient-gravity*))))

(defun window-width-inc (window)
  "Find out what is the correct step to change window width"
  (or
    (xlib:wm-size-hints-width-inc (window-normal-hints window))
    1))

(defun window-height-inc (window)
  "Find out what is the correct step to change window height"
  (or
    (xlib:wm-size-hints-height-inc (window-normal-hints window))
    1))

(defun set-window-geometry (win &key x y width height border-width)
  (macrolet ((update (xfn wfn v)
               `(when ,v ;; (/= (,wfn win) ,v))
                 (setf (,xfn (window-xwin win)) ,v)
                 ,(when wfn `(setf (,wfn win) ,v)))))
    (xlib:with-state ((window-xwin win))
      (update xlib:drawable-x nil x)
      (update xlib:drawable-y nil y)
      (update xlib:drawable-width window-width width)
      (update xlib:drawable-height window-height height)
      (update xlib:drawable-border-width nil border-width)
      )))

(defun find-free-window-number (group)
  "Return a free window number for GROUP. Begining from '1'"
  (find-free-number (mapcar 'window-number (group-windows group)) 1))

(defun reparent-window (screen window)
  ;; apparently we need to grab the server so the client doesn't get
  ;; the mapnotify event before the reparent event. that's what fvwm
  ;; says.
  (xlib:with-server-grabbed (*display*)
    (let ((master-window (xlib:create-window
                          :parent (screen-root screen)
                          :x (xlib:drawable-x (window-xwin window)) :y (xlib:drawable-y (window-xwin window))
                          :width (window-width window)
                          :height (window-height window)
                          :background (if (eq (window-type window) :normal)
                                          (screen-win-bg-color screen)
                                          :none)
                          :border (screen-unfocus-color screen)
                          :border-width (default-border-width-for-type window)
                          :event-mask *window-parent-events*)))
      (unless (eq (xlib:window-map-state (window-xwin window)) :unmapped)
        (incf (window-unmap-ignores window)))
      (xlib:reparent-window (window-xwin window) master-window 0 0)
      (xwin-grab-buttons master-window)
      ;;     ;; we need to update these values since they get set to 0,0 on reparent
      ;;     (setf (window-x window) 0
      ;;          (window-y window) 0)
      (xlib:add-to-save-set (window-xwin window))
      (setf (window-parent window) master-window))))

(defun process-existing-windows (screen)
  "Windows present when dswm starts up must be absorbed by dswm."
  (let ((children (xlib:query-tree (screen-root screen)))
        (*processing-existing-windows* t)
        (stacking (xlib:get-property (screen-root screen) :_NET_CLIENT_LIST_STACKING :type :window)))
    (when stacking
      (dformat 3 "Using window stacking: ~{~X ~}~%" stacking)
      ;; sort by _NET_CLIENT_LIST_STACKING
      (setf children (stable-sort children #'< :key
                                  (lambda (xwin)
                                    (or (position (xlib:drawable-id xwin) stacking :test #'=) 0)))))
    (dolist (win children)
      (let ((map-state (xlib:window-map-state win))
            (wm-state (xwin-state win)))
        ;; Don't process override-redirect windows.
        (unless (or (eq (xlib:window-override-redirect win) :on)
                    (internal-window-p screen win))
          (if (eq (xwin-type win) :dock)
              (progn
                (dformat 1 "Window ~S is dock-type. Placing in mode-line.~%" win)
                (place-mode-line-window screen win))
              (if (or (eql map-state :viewable)
                      (eql wm-state +iconic-state+))
                  (progn
                    (dformat 1 "Processing ~S ~S~%" (xwin-name win) win)
                    (process-mapped-window screen win))))))))
  (dolist (w (screen-windows screen))
    (setf (window-state w) +normal-state+)
    (xwin-hide w)))

(defun xwin-grab-keys (win screen)
  (labels ((grabit (w key)
             (loop for code in (multiple-value-list (xlib:keysym->keycodes *display* (key-keysym key))) do
               ;; some keysyms aren't mapped to keycodes so just ignore them.
               (when code
                 ;; Some keysyms, such as upper case letters, need the
                 ;; shift modifier to be set in order to grab properly.
                 (when (and (not (eql (key-keysym key) (xlib:keycode->keysym *display* code 0)))
                            (eql (key-keysym key) (xlib:keycode->keysym *display* code 1)))
                   ;; don't butcher the caller's structure
                   (setf key (copy-structure key)
                         (key-shift key) t))
                 (xlib:grab-key w code
                                :modifiers (x11-mods key) :owner-p t
                                :sync-pointer-p nil :sync-keyboard-p nil)
                 ;; Ignore capslock and numlock by also grabbing the
                 ;; keycombos with them on.
                 (xlib:grab-key w code :modifiers (x11-mods key nil t) :owner-p t
                                :sync-keyboard-p nil :sync-keyboard-p nil)
                 (when (modifiers-numlock *modifiers*)
                   (xlib:grab-key w code
                                  :modifiers (x11-mods key t nil) :owner-p t
                                  :sync-pointer-p nil :sync-keyboard-p nil)
                   (xlib:grab-key w code :modifiers (x11-mods key t t) :owner-p t
                                  :sync-keyboard-p nil :sync-keyboard-p nil))))))
    (dolist (map (dereference-kmaps (top-maps screen)))
      (dolist (i (kmap-bindings map))
        (grabit win (binding-key i))))))

(defun grab-keys-on-window (win)
  (xwin-grab-keys (window-xwin win) (window-group win)))

(defun xwin-ungrab-keys (win)
  (xlib:ungrab-key win :any :modifiers :any))

(defun ungrab-keys-on-window (win)
  (xwin-ungrab-keys (window-xwin win)))

(defun xwin-grab-buttons (win)
  ;; FIXME: Why doesn't grabbing button :any work? We have to
  ;; grab them one by one instead.
  (xwin-ungrab-buttons win)
  (loop for i from 1 to 7
        do (xlib:grab-button win i '(:button-press)
                             :modifiers :any
                             :owner-p nil
                             :sync-pointer-p t
                             :sync-keyboard-p nil)))


(defun xwin-ungrab-buttons (win)
  (xlib:ungrab-button win :any :modifiers :any))

(defun sync-keys ()
  "Any time *top-map* is modified this must be called."
  (loop for i in *screen-list*
        do (xwin-ungrab-keys (screen-focus-window i))
        do (loop for j in (screen-mapped-windows i)
                 do (xwin-ungrab-keys j))
        do (xlib:display-finish-output *display*)
        do (loop for j in (screen-mapped-windows i)
                 do (xwin-grab-keys j i))
        do (xwin-grab-keys (screen-focus-window i) i))
  (xlib:display-finish-output *display*))

(defun netwm-remove-window (window)
  (xlib:delete-property (window-xwin window) :_NET_WM_DESKTOP))

(defun process-mapped-window (screen xwin)
  "Add the window to the screen's mapped window list and process it as
needed."
  (let ((window (xwin-to-window xwin)))
    (screen-add-mapped-window screen xwin)
    ;; windows always have border width 0. Their parents provide the
    ;; border.
    (set-window-geometry window :border-width 0)
    (setf (xlib:window-event-mask (window-xwin window)) *window-events*)
    (register-window window)
    (reparent-window screen window)
    (netwm-set-allowed-actions window)
    (let ((placement-data (place-window screen window)))
      (apply 'group-add-window (window-group window) window placement-data)
      ;; If the placement rule matched then either the window's group
      ;; is the current group or the rule's :lock attribute was
      ;; on. Either way the window's group should become the current
      ;; one (if it isn't already) if :raise is T.
      (when placement-data
        (if (getf placement-data :raise)
          (switch-to-group (window-group window))
          (message "Placing window ~a in group ~a" (window-name window) (group-name (window-group window))))
        (apply 'run-hook-with-args *place-window-hook* window (window-group window) placement-data)))
    ;; must call this after the group slot is set for the window.
    (grab-keys-on-window window)
    ;; quite often the modeline displays the window list, so update it
    (update-all-mode-lines)
    ;; Run the new window hook on it.
    (run-hook-with-args *new-window-hook* window)
    window))

(defun find-withdrawn-window (xwin)
  "Return the window and screen for a withdrawn window."
  (declare (type xlib:window xwin))
  (dolist (i *screen-list*)
    (let ((w (find xwin (screen-withdrawn-windows i) :key 'window-xwin :test 'xlib:window-equal)))
      (when w
        (return-from find-withdrawn-window (values w i))))))

(defun restore-window (window)
  "Restore a withdrawn window"
  (declare (type window window))
  ;; put it in a valid group
  (let* ((screen (window-screen window))
         (group (get-window-placement screen window)))
    (unless (find (window-group window)
                  (screen-groups screen))
      (setf (window-group window) (or group (screen-current-group screen))))
    ;; FIXME: somehow it feels like this could be merged with group-add-window
    (setf (window-title window) (xwin-name (window-xwin window))
          (window-class window) (xwin-class (window-xwin window))
          (window-res window) (xwin-res-name (window-xwin window))
          (window-role window) (xwin-role (window-xwin window))
          (window-type window) (xwin-type (window-xwin window))
          (window-normal-hints window) (get-normalized-normal-hints (window-xwin window))
          (window-number window) (find-free-window-number (window-group window))
          (window-state window) +iconic-state+
          (xwin-state (window-xwin window)) +iconic-state+
          (screen-withdrawn-windows screen) (delete window (screen-withdrawn-windows screen))
          ;; put the window at the end of the list
          (group-windows (window-group window)) (append (group-windows (window-group window)) (list window)))
    (screen-add-mapped-window screen (window-xwin window))
    (register-window window)
    (group-add-window (window-group window) window)
    (netwm-set-group window)
    ;; It is effectively a new window in terms of the window list.
    (run-hook-with-args *new-window-hook* window)
    ;; FIXME: only called frame-raise-window instead of this function
    ;; which will likely call focus-all.
    (group-raise-request (window-group window) window :map)))

(defun withdraw-window (window)
  "Withdrawing a window means just putting it in a list til we get a destroy event."
  (declare (type window window))
  ;; This function cannot request info about WINDOW from the xserver as it may not exist anymore.
  (let ((group (window-group window))
        (screen (window-screen window)))
    (dformat 1 "withdraw window ~a~%" screen)
    ;; Save it for later since it is only withdrawn, not destroyed.
    (push window (screen-withdrawn-windows screen))
    (setf (window-state window) +withdrawn-state+
          (xwin-state (window-xwin window)) +withdrawn-state+)
    (xlib:unmap-window (window-parent window))
    ;; Clean up the window's entry in the screen and group
    (setf (group-windows group)
          (delete window (group-windows group)))
    (screen-remove-mapped-window screen (window-xwin window))
    (when (window-in-current-group-p window)
      ;; since the window doesn't exist, it doesn't have focus.
      (setf (screen-focus screen) nil))
    (netwm-remove-window window)
    (group-delete-window group window)
    ;; quite often the modeline displays the window list, so update it
    (update-all-mode-lines)
    ;; Run the destroy hook on the window
    (run-hook-with-args *destroy-window-hook* window)))

(defun destroy-window (window)
  (declare (type window window))
  "The window has been destroyed. clean up our data structures."
  ;; This function cannot request info about WINDOW from the xserver
  (let ((screen (window-screen window)))
    (unless (eql (window-state window) +withdrawn-state+)
      (withdraw-window window))
    ;; now that the window is withdrawn, clean up the data structures
    (setf (screen-withdrawn-windows screen)
          (delete window (screen-withdrawn-windows screen)))
    (setf (screen-urgent-windows screen)
          (delete window (screen-urgent-windows screen)))
    (dformat 1 "destroy window ~a~%" screen)
    (dformat 3 "destroying parent window~%")
    (dformat 7 "parent window is ~a~%" (window-parent window))
    (xlib:destroy-window (window-parent window))))

(defun move-window-to-head (group window)
  "Move window to the head of the group's window list."
  (declare (type group group))
  (declare (type window window))
                                        ;(assert (member window (screen-mapped-windows screen)))
  (move-to-head (group-windows group) window)
  (netwm-update-client-list-stacking (group-screen group)))

(defun no-focus (group last-win)
  "don't focus any window but still read keyboard events."
  (dformat 3 "no-focus~%")
  (let* ((screen (group-screen group)))
    (when (eq group (screen-current-group screen))
      (xlib:set-input-focus *display* (screen-focus-window screen) :POINTER-ROOT)
      (setf (screen-focus screen) nil)
      (move-screen-to-head screen))
    (when last-win
      (update-decoration last-win))))
  
(defmethod focus-window (window)
  "Make the window visible and give it keyboard focus."
  (dformat 3 "focus-window: ~s~%" window)
  (let* ((group (window-group window))
         (screen (group-screen group))
         (cw (screen-focus screen)))
    ;; If window to focus is already focused then our work is done.
    (unless (eq window cw)
      (raise-window window)
      (screen-set-focus screen window)
      ;;(send-client-message window :WM_PROTOCOLS +wm-take-focus+)
      (update-decoration window)
      (when cw
        (update-decoration cw))
      ;; Move the window to the head of the mapped-windows list
      (move-window-to-head group window)
      (run-hook-with-args *focus-window-hook* window cw))))

(defun xwin-kill (window)
  "Kill the client associated with window."
  (dformat 3 "Kill client~%")
  (xlib:kill-client *display* (xlib:window-id window)))

(defun select-window-from-menu (windows fmt)
  "Allow the user to select a window from the list passed in @var{windows}.  The
@var{fmt} argument specifies the window formatting used.  Returns the window
selected."
  (second (select-from-menu (current-screen)
			    (mapcar (lambda (w)
				      (list (format-expand *window-formatters* fmt w) w))
				    windows))))

;;; Window commands

(defcommand delete-window (&optional (window (current-window))) ()
  "Delete a window. By default delete the current window. This is a
request sent to the window. The window's client may decide not to
grant the request or may not be able to if it is unresponsive."
  (when window
    (send-client-message window :WM_PROTOCOLS (xlib:intern-atom *display* :WM_DELETE_WINDOW))))

(defcommand-alias delete delete-window)

(defcommand kill-window (&optional (window (current-window))) ()
  "Tell X to disconnect the client that owns the specified
window. Default to the current window. if
@command{delete-window} didn't work, try this."
  (when window
    (xwin-kill (window-xwin window))))

(defcommand-alias kill kill-window)

(defcommand title (title) ((:title "Set window's title to: "))
  "Override the current window's title."
  (if (current-window)
      (setf (window-user-title (current-window)) title)
      (message "No Focused Window")))

; Emacs-like
(defcommand-alias rename-window title)

(defcommand select-window (query) ((:window-name "Select window: "))
  "Switch to the first window that starts with @var{query}."
  (let (match)
    (labels ((match (win)
               (let* ((wname (window-name win))
                      (end (min (length wname) (length query))))
                 (string-equal wname query :end1 end :end2 end))))
      (unless (null query)
        (setf match (find-if #'match (group-windows (current-group)))))
      (when match
        (group-focus-window (current-group) match)))))

(defcommand-alias select select-window)

(defcommand select-window-by-name (name) ((:window-name "Select window: "))
  "Switch to the first window whose name is exactly @var{name}."
  (let ((win (find name (group-windows (current-group))
                   :test #'string= :key #'window-name)))
    (when win
      (group-focus-window (current-group) win))))

(defcommand select-window-by-number (num &optional (group (current-group)))
  ((:window-number "Select window: "))
  "Find the window with the given number and focus it in its frame."
  (labels ((match (win)
		  (= (window-number win) num)))
    (let ((win (find-if #'match (group-windows group))))
      (when win
        (group-focus-window group win)))))

(defcommand other-window (&optional (group (current-group))) ()
  "Switch to the window last focused."
  (let* ((wins (group-windows group))
         ;; the frame could be empty
         (win (if (group-current-window group)
                  (second wins)
		(first wins))))
    (if win
        (group-focus-window group win)
      (echo-string (group-screen group) "No other window."))))

(defcommand-alias other other-window)

(defcommand renumber (nt &optional (group (current-group))) ((:number "Number: "))
  "Change the current window's number to the specified number. If another window
is using the number, then the windows swap numbers. Defaults to current group."
  (let ((nf (window-number (group-current-window group)))
        (win (find-if #'(lambda (win)
                          (= (window-number win) nt))
                      (group-windows group))))
    ;; Is it already taken?
    (if win
        (progn
          ;; swap the window numbers
          (setf (window-number win) nf)
          (setf (window-number (group-current-window group)) nt))
        ;; Just give the window the number
        (setf (window-number (group-current-window group)) nt))))

(defcommand-alias number renumber)

(defcommand repack-window-numbers (&optional preserved) ()
  "Ensure that used window numbers do not have gaps; ignore PRESERVED window numbers."
  (let* ((group (current-group))
	 (windows (sort-windows-by-number group)))
    (loop for w in windows
	  do (unless (find (window-number w) preserved)
	       (setf
		 (window-number w)
		 (find-free-number
		   (remove
		     (window-number w)
		     (mapcar 'window-number windows))
		   0))))))

(defcommand windowlist (&optional (fmt *window-format*)) (:rest)
"Allow the user to Select a window from the list of windows and focus
the selected window. For information of menu bindings
@xref{Menus}. The optional argument @var{fmt} can be specified to
override the default window formatting."
  (if-null (group-windows (current-group))
      (message "No Managed Windows")
      (let* ((group (current-group))
             (window (select-window-from-menu (sort-windows group) fmt)))
        (if window
            (group-focus-window group window)
            (throw 'error :abort)))))


(defcommand window-send-string (string &optional (window
						  (current-window)))
  ((:rest "Insert string to send: "))
  "Send the string of characters to the current window as if they'd been typed."
  (when window
    (map nil (lambda (ch)
               ;; exploit the fact that keysyms for ascii characters
               ;; are the same as their ascii value.
               (let ((sym (cond ((<= 32 (char-code ch) 127)
                                 (char-code ch))
                                ((char= ch #\Tab)
                                 (car (dswm-name->keysyms "TAB")))
                                ((char= ch #\Newline)
                                 (car (dswm-name->keysyms "RET")))
                                (t nil))))
                 (when sym
                   (send-fake-key window
                                  (make-key :keysym sym)))))
         string)))

(defcommand-alias insert window-send-string)

(defcommand mark () ()
"Toggle the current window's mark."
  (let ((win (current-window)))
    (when win
      (setf (window-marked win) (not (window-marked win)))
      (message (if (window-marked win)
                   "Marked!"
                   "Unmarked!")))))

(defcommand clear-window-marks (&optional (group (current-group)) (windows (group-windows group))) ()
"Clear all marks in the current group."
  (dolist (w windows)
    (setf (window-marked w) nil)))

(defcommand-alias clear-marks clear-window-marks)

(defcommand echo-windows (&optional (fmt *window-format*) (group (current-group)) (windows (group-windows group))) (:rest)
  "Display a list of managed windows. The optional argument @var{fmt} can
be used to override the default window formatting."
  (let* ((wins (sort1 windows '< :key 'window-number))
         (highlight (position (group-current-window group) wins))
         (names (mapcar (lambda (w)
                          (format-expand *window-formatters* fmt w)) wins)))
    (if-null wins
        (echo-string (group-screen group) "No Managed Windows")
        (echo-string-list (group-screen group) names highlight))))

(defcommand-alias windows echo-windows)

(defcommand refresh () ()
  "Refresh current window without changing its size."
  (let* ((window (current-window))
         (w (window-width window))
         (h (window-height window)))
    (set-window-geometry window
                         :width (- w (window-width-inc window))
                         :height (- h (window-height-inc window)))
    ;; make sure the first one goes through before sending the second
    (xlib:display-finish-output *display*)
    (set-window-geometry window
                         :width w
                         :height h)))

(defcommand place-existing-windows () ()
  "Re-arrange existing windows according to placement rules."
  (sync-window-placement))