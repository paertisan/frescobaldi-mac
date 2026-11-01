%% Frescobaldi for macOS: links for adjusting objects in the preview.
%%
%% The app passes this file with -dinclude-settings for preview engraves
%% only (never for publishing or Export PDF). It adds an invisible link
%% (the url-link stencil that \with-url uses) to the stencil of each object
%% that can be dragged. The link's URL carries the object's source location
%% and the property values a drag needs; PDFKit reports it as an annotation
%% with the object's exact rectangle on the page.
%%
%%   fmac://grob?name=Script&line=3&char=8&...&file=/path/score.ly
%%
%% line is 1-based, char 0-based (Unicode characters, tabs count as one).
%% Lengths: u is millimetres per LilyPond unit (output-scale), ss
%% millimetres per staff space of the object's staff. x and y are the
%% stencil's extents, cp (slur and tie control points) and pos (beam
%% positions) are in the stencil's coordinates. The values are read when
%% the PDF is written, after layout, so reading them can't change it.
%%
%% Part of Frescobaldi for macOS, GPL-2.0-or-later.

#(define fmac-grobs
   '(Script TextScript DynamicText Fingering Slur PhrasingSlur Tie Hairpin
     SustainPedal TupletBracket Beam))

%% Objects whose collision properties live on the spanner that holds them.
#(define fmac-side-spanners '(DynamicLineSpanner SustainPedalLineSpanner))

#(define (fmac-cause-event grob)
   (let ((cause (ly:grob-property grob 'cause)))
     (cond ((ly:stream-event? cause) cause)
           ((and (ly:grob? cause) (ly:stream-event? (ly:grob-property cause 'cause)))
            (ly:grob-property cause 'cause))
           (else #f))))

%% The event an object comes from. An automatic beam has none: use its
%% first note, so the app can write an override before that note.
#(define (fmac-event grob)
   (or (fmac-cause-event grob)
       (and (eq? (grob::name grob) 'Beam)
            (let* ((stems (ly:grob-object grob 'stems))
                   (stems (if (ly:grob-array? stems) (ly:grob-array->list stems) '()))
                   (heads (if (pair? stems) (ly:grob-object (car stems) 'note-heads) '()))
                   (heads (if (ly:grob-array? heads) (ly:grob-array->list heads) '())))
              (and (pair? heads) (fmac-cause-event (car heads)))))))

#(define (fmac-num x) (if (number? x) (ly:format "~4f" x) ""))

#(define (fmac-pair p)
   (if (and (pair? p) (number? (car p)) (number? (cdr p)))
       (string-append (fmac-num (car p)) "," (fmac-num (cdr p)))
       ""))

#(define (fmac-location event)
   (let ((origin (and event (ly:event-property event 'origin #f))))
     (and (ly:input-location? origin) (ly:input-file-line-char-column origin))))

#(define (fmac-side-target grob)
   (let ((parent (ly:grob-parent grob Y)))
     (if (and (ly:grob? parent) (memq (grob::name parent) fmac-side-spanners)) parent grob)))

#(define (fmac-offset grob axis)
   (let ((parent (ly:grob-parent grob axis)))
     (if (ly:grob? parent) (ly:grob-relative-coordinate grob parent axis) #f)))

#(define (fmac-label grob event)
   (let ((name (grob::name grob))
         (text (lambda () (let ((t (ly:grob-property grob 'text #f)))
                            (if (markup? t) (markup->string t) "")))))
     (case name
       ((DynamicText TextScript) (text))
       ((Fingering) (let ((digit (ly:event-property event 'digit #f)))
                      (if digit (format #f "~a" digit) (text))))
       ((Script) (let ((type (ly:event-property event 'articulation-type #f)))
                   (if type (format #f "~a" type) "")))
       ((Hairpin) (if (eqv? (ly:grob-property grob 'grow-direction 1) LEFT) "decrescendo" "crescendo"))
       ((SustainPedal) (if (eqv? (ly:event-property event 'span-direction START) STOP) "*" "Ped."))
       (else ""))))

#(define (fmac-piece grob)
   (let* ((original (and (ly:spanner? grob) (ly:grob-original grob)))
          (pieces (if (ly:spanner? original) (ly:spanner-broken-into original) '())))
     (if (> (length pieces) 1)
         (cons (length (memq grob (reverse pieces))) (length pieces))
         (cons 1 1))))

#(define (fmac-url grob event stencil)
   (let* ((location (fmac-location event))
          (name (grob::name grob))
          (target (fmac-side-target grob))
          (target-location (and (not (eq? target grob)) (fmac-location (fmac-cause-event target))))
          (scale (ly:output-def-lookup (ly:grob-layout grob) 'output-scale))
          (piece (fmac-piece grob))
          (fields
           (list
            (cons "name" (symbol->string name))
            (cons "ev" (let ((class (ly:event-property event 'class '())))
                         (if (pair? class) (symbol->string (car class)) "")))
            (cons "line" (number->string (cadr location)))
            (cons "char" (number->string (caddr location)))
            (cons "label" (fmac-label grob event))
            (cons "u" (fmac-num scale))
            (cons "ss" (fmac-num (* scale (ly:staff-symbol-staff-space grob))))
            (cons "x" (fmac-pair (ly:stencil-extent stencil X)))
            (cons "y" (fmac-pair (ly:stencil-extent stencil Y)))
            (cons "eo" (fmac-pair (ly:grob-property grob 'extra-offset '(0 . 0))))
            (cons "xo" (fmac-num (fmac-offset grob X)))
            (cons "t" (if (eq? target grob) "" (symbol->string (grob::name target))))
            (cons "tl" (if target-location
                           (ly:format "~a,~a" (cadr target-location) (caddr target-location))
                           ""))
            (cons "yo" (fmac-num (fmac-offset target Y)))
            (cons "pad" (fmac-num (ly:grob-property target 'padding #f)))
            (cons "spad" (fmac-num (ly:grob-property target 'staff-padding #f)))
            (cons "ospad" (fmac-num (ly:grob-property target 'outside-staff-padding #f)))
            (cons "dir" (fmac-num (ly:grob-property target 'direction #f)))
            (cons "cp" (if (memq name '(Slur PhrasingSlur Tie))
                           (string-join (map fmac-pair (ly:grob-property grob 'control-points '())) ";")
                           ""))
            (cons "pos" (if (eq? name 'Beam) (fmac-pair (ly:grob-property grob 'positions '())) ""))
            (cons "piece" (ly:format "~a,~a" (car piece) (cdr piece)))
            ;; Last, so a reader can take the rest as the path.
            (cons "file" (car location)))))
     (string-append
      "fmac://grob?"
      (string-join
       (map (lambda (field) (string-append (car field) "=" (ly:string-percent-encode (cdr field))))
            fields)
       "&"))))

#(define (fmac-wrap grob)
   (let ((print (ly:grob-property-data grob 'stencil)))
     (if (procedure? print)
         (ly:grob-set-property!
          grob 'stencil
          (lambda (g)
            (let ((stencil (print g))
                  (event (fmac-event g)))
              (if (and (ly:stencil? stencil) (not (ly:stencil-empty? stencil)) (fmac-location event))
                  (let ((x (ly:stencil-extent stencil X))
                        (y (ly:stencil-extent stencil Y)))
                    ;; Delayed: the URL is built when the page is output.
                    (ly:stencil-add
                     stencil
                     (ly:make-stencil
                      `(delay-stencil-evaluation
                        ,(delay (list 'url-link (fmac-url g event stencil) x y)))
                      x y)))
                  stencil)))))))

#(define (fmac-adjust-engraver context)
   (make-engraver
    (acknowledgers
     ((grob-interface engraver grob source)
      (if (memq (grob::name grob) fmac-grobs) (fmac-wrap grob))))))

\layout {
  \context {
    \Score
    \consists #fmac-adjust-engraver
  }
}
