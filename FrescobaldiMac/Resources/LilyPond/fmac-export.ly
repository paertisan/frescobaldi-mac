%% Frescobaldi for macOS: the music as LilyPond interprets it, for MusicXML.
%%
%% Export MusicXML engraves the score once more, with this file passed by
%% -dinclude-settings, and doesn't print pages. Engravers added to Score,
%% Staff, Voice and Lyrics write each event LilyPond hears (notes, rests,
%% ties, slurs, dynamics, clefs, keys, bars, repeats, lyrics ...) to the
%% file named by FMAC_EXPORT_EVENTS, one record per line, fields separated
%% by tabs. The app turns the records into MusicXML (MusicXMLWriter.swift).
%% Because LilyPond did the reading, \relative, \transpose, variables,
%% includes and music functions all come out as they print.
%%
%% Records (moments are "main,grace", both rationals in whole notes):
%%   fmac-events 1
%%   header    key value                    (the \header of the file)
%%   score     id index
%%   paper     width height top bottom left right output-scale
%%             (lengths in staff spaces; output-scale is mm per staff space)
%%   break     moment line|page                (\break, \pageBreak)
%%   scoreheader index key value            (a score's own \header)
%%   ctx       id name context-id parent instrumentName shortInstrumentName
%%   staff     id name context-id parent
%%   props     staff moment clefGlyph clefPosition clefTransposition
%%             instrumentName shortInstrumentName midiInstrument
%%             midiProgram instrumentTransposition timeSignatureStyle
%%             timeSignatureVisible
%%   key       staff moment tonic fifths
%%   bar       moment barNumber measurePosition measureLength numerator/denominator
%%   barline   moment glyph
%%   tempo     moment text unit count
%%   mark      moment label number
%%   ev        voice staff moment class duration pitch span-direction
%%             articulation-type text digit direction attached hidden
%%   lyric     lyrics moment class text voice
%%   beam      voice moment ...                (the notes of a beam as drawn)
%%   end       moment finalBarType
%%
%% Pitches are "octave,notename,alteration" (c' is 0,0,0); durations
%% "log,dots,scale". An ev with attached = 1 belongs to the note before
%% it (an articulation inside a chord).
%%
%% Part of Frescobaldi for macOS, GPL-2.0-or-later.

#(define fmac-port #f)
#(define fmac-ids (make-hash-table))
#(define fmac-next-id 0)
#(define fmac-score-count 0)
#(define fmac-layout-scores 0)

%% markup->string leaves out music glyphs such as \flat in "Clarinet in B♭".
#(define fmac-glyph-text
   (list (cons flat-markup "♭") (cons sharp-markup "♯") (cons natural-markup "♮")
         (cons doubleflat-markup "𝄫") (cons doublesharp-markup "𝄪")))

#(define (fmac-glyphs->text m)
   (cond ((and (pair? m) (procedure? (car m)) (assq (car m) fmac-glyph-text)) => cdr)
         ((and (pair? m) (procedure? (car m))) (cons (car m) (map fmac-glyphs->text (cdr m))))
         ((and (pair? m) (markup-list? m)) (map fmac-glyphs->text m))
         (else m)))

#(define (fmac-markup->string m)
   (catch #t
     (lambda () (string-trim-both (markup->string (fmac-glyphs->text m))))
     (lambda args "")))

#(define (fmac-clean s)
   (string-map (lambda (c) (if (memv c '(#\tab #\newline #\return)) #\space c)) s))

#(define (fmac-moment m)
   (format #f "~a,~a"
           (/ (ly:moment-main-numerator m) (ly:moment-main-denominator m))
           (/ (ly:moment-grace-numerator m) (ly:moment-grace-denominator m))))

#(define (fmac-id ctx)
   (or (hashq-ref fmac-ids ctx)
       (begin
         (set! fmac-next-id (1+ fmac-next-id))
         (hashq-set! fmac-ids ctx (number->string fmac-next-id))
         (hashq-ref fmac-ids ctx))))

#(define (fmac-str x)
   (cond ((string? x) (fmac-clean x))
         ((symbol? x) (symbol->string x))
         ((number? x) (number->string x))
         ((boolean? x) (if x "1" ""))
         ((null? x) "")
         ((markup? x) (fmac-clean (fmac-markup->string x)))
         ((ly:pitch? x) (format #f "~a,~a,~a" (ly:pitch-octave x) (ly:pitch-notename x) (ly:pitch-alteration x)))
         ((ly:duration? x) (format #f "~a,~a,~a" (ly:duration-log x) (ly:duration-dot-count x) (ly:duration-scale x)))
         ((ly:moment? x) (fmac-moment x))
         ((ly:context? x) (fmac-id x))
         (else (fmac-clean (format #f "~a" x)))))

#(define (fmac-out . items)
   (if (not fmac-port)
       (let ((path (getenv "FMAC_EXPORT_EVENTS")))
         (set! fmac-port (if path (open-file path "w") (current-error-port)))
         (display "fmac-events\t1\n" fmac-port)))
   (display (string-join (map fmac-str items) "\t") fmac-port)
   (newline fmac-port))

#(define (fmac-now ctx) (ly:context-current-moment ctx))

%% Group contexts (StaffGroup, PianoStaff, ...) above a staff, each once.
#(define fmac-seen (make-hash-table))
#(define (fmac-announce ctx)
   (if (and ctx (not (hashq-ref fmac-seen ctx)))
       (let ((parent (ly:context-parent ctx)))
         (hashq-set! fmac-seen ctx #t)
         (fmac-announce parent)
         (fmac-out "ctx" ctx (ly:context-name ctx) (ly:context-id ctx) (or parent "")
                   (ly:context-property ctx 'instrumentName #f)
                   (ly:context-property ctx 'shortInstrumentName #f)))))

%% 2.25 renamed timeSignatureFraction to timeSignature.
#(define (fmac-time-signature ctx)
   (let ((new (ly:context-property ctx 'timeSignature #f)))
     (if (pair? new) new
         (let ((v (ly:version)))
           (if (and (= (car v) 2) (< (cadr v) 25))
               (ly:context-property ctx 'timeSignatureFraction #f)
               #f)))))

#(define (fmac-header-records record module . prefix)
   (if (module? module)
       (module-for-each
        (lambda (key var)
          (let ((value (variable-ref var)))
            (if (or (string? value) (markup? value))
                (apply fmac-out (append (list record) prefix (list key value))))))
        module)))

%% A score's own \header, for the layout scores in order.
#(define fmac-pending-headers '())
#(define (fmac-remember-score score)
   (let* ((defs (ly:score-output-defs score))
          (layout? (or (null? defs) (any (lambda (d) (eq? (ly:output-def-lookup d 'output-def-kind #f) 'layout)) defs))))
     (if layout?
         (set! fmac-pending-headers (append fmac-pending-headers (list (ly:score-header score)))))))
#(let ((toplevel toplevel-score-handler) (book book-score-handler))
   (set! toplevel-score-handler (lambda (score) (fmac-remember-score score) (toplevel score)))
   (set! book-score-handler (lambda (b score) (fmac-remember-score score) (book b score))))

#(define (fmac-score-engraver ctx)
   (let ((bar #f) (len #f) (sig #f) (index 0))
     (make-engraver
      ((initialize engraver)
       (if (= fmac-score-count 0)
           (fmac-header-records "header" (ly:parser-lookup '$defaultheader)))
       (set! fmac-score-count (1+ fmac-score-count))
       (set! index fmac-score-count)
       (fmac-out "score" ctx index)
       (let ((def (ly:context-output-def ctx)))
         (apply fmac-out "paper"
                (map (lambda (key) (ly:output-def-lookup def key #f))
                     '(paper-width paper-height top-margin bottom-margin left-margin right-margin output-scale))))
       (if (pair? fmac-pending-headers)
           (begin
             (fmac-header-records "scoreheader" (car fmac-pending-headers) index)
             (set! fmac-pending-headers (cdr fmac-pending-headers)))))
      (listeners
       ((tempo-change-event engraver event)
        (let ((count (ly:event-property event 'metronome-count #f)))
          (fmac-out "tempo" (fmac-now ctx) (ly:event-property event 'text "")
                    (ly:event-property event 'tempo-unit #f)
                    (if (pair? count) (car count) count))))
       ((line-break-event engraver event)
        (if (eq? (ly:event-property event 'break-permission #f) 'force)
            (fmac-out "break" (fmac-now ctx) "line")))
       ((page-break-event engraver event)
        (if (eq? (ly:event-property event 'break-permission #f) 'force)
            (fmac-out "break" (fmac-now ctx) "page")))
       ((mark-event engraver event)
        (fmac-out "mark" (fmac-now ctx) (ly:event-property event 'label #f)
                  (ly:context-property ctx 'rehearsalMark #f))))
      ((process-music engraver)
       (let ((b (ly:context-property ctx 'currentBarNumber))
             (pos (ly:context-property ctx 'measurePosition))
             (l (ly:context-property ctx 'measureLength))
             (s (fmac-time-signature ctx)))
         (if (not (and (equal? b bar) (equal? l len) (equal? s sig)))
             (begin
               (set! bar b) (set! len l) (set! sig s)
               (fmac-out "bar" (fmac-now ctx) b pos l
                         (if (pair? s) (format #f "~a/~a" (car s) (cdr s)) ""))))))
      ((stop-translation-timestep engraver)
       (let ((glyph (ly:context-property ctx 'whichBar "")))
         (if (and (string? glyph) (not (member glyph '("" "|"))))
             (fmac-out "barline" (fmac-now ctx) glyph))))
      ((finalize engraver)
       (fmac-out "end" (fmac-now ctx) (ly:context-property ctx 'finalBarType #f))
       (if fmac-port (force-output fmac-port))))))

%% Whether a grob is shown: not \omit (stencil #f) or \hide (transparent).
#(define (fmac-visible? ctx grob)
   (let ((def (ly:context-grob-definition ctx grob)))
     (and (ly:assoc-get 'stencil def #t) (not (ly:assoc-get 'transparent def #f)))))

#(define (fmac-staff-engraver ctx)
   (let ((props '()))
     (make-engraver
      ((initialize engraver)
       (fmac-announce (ly:context-parent ctx))
       (fmac-out "staff" ctx (ly:context-name ctx) (ly:context-id ctx) (or (ly:context-parent ctx) "")))
      (listeners
       ((key-change-event engraver event)
        (fmac-out "key" ctx (fmac-now ctx) (ly:event-property event 'tonic #f)
                  (alterations-in-key (ly:event-property event 'pitch-alist '())))))
      ((process-music engraver)
       (let* ((instrument (ly:context-property ctx 'midiInstrument #f))
              (program (and (string? instrument) (midi-program (string->symbol instrument))))
              (now (list (ly:context-property ctx 'clefGlyph #f)
                         (ly:context-property ctx 'clefPosition #f)
                         (ly:context-property ctx 'clefTransposition #f)
                         (ly:context-property ctx 'instrumentName #f)
                         (ly:context-property ctx 'shortInstrumentName #f)
                         instrument program
                         (ly:context-property ctx 'instrumentTransposition #f)
                         (ly:assoc-get 'style (ly:context-grob-definition ctx 'TimeSignature) #f)
                         (fmac-visible? ctx 'TimeSignature))))
         (if (not (equal? now props))
             (begin (set! props now) (apply fmac-out "props" ctx (fmac-now ctx) now))))))))

#(define fmac-ignored '(skip-event bar-check-event key-change-event time-signature-event
                        reference-time-signature-event tempo-change-event mark-event
                        line-break-event page-break-event))

#(define (fmac-event-record voice staff now event attached)
   (let* ((volta (ly:event-property event 'volta-numbers #f))
          (class (car (ly:event-property event 'class '(unknown))))
          (hidden (case class
                    ((note-event) (not (fmac-visible? voice 'NoteHead)))
                    ((rest-event) (not (fmac-visible? voice 'Rest)))
                    ((multi-measure-rest-event) (not (fmac-visible? voice 'MultiMeasureRest)))
                    (else #f))))
     (fmac-out "ev" voice staff now (car (ly:event-property event 'class '(unknown)))
               (ly:event-property event 'duration #f)
               (ly:event-property event 'pitch #f)
               (ly:event-property event 'span-direction #f)
               (ly:event-property event 'articulation-type #f)
               (if (pair? volta) (string-join (map number->string volta) " ")
                   (ly:event-property event 'text #f))
               (or (ly:event-property event 'digit #f) (ly:event-property event 'repeat-count #f))
               (ly:event-property event 'direction #f)
               attached
               hidden)))

#(define (fmac-voice-engraver ctx)
   (let ((events '()) (stems (make-hash-table)) (beams '()))
     (make-engraver
      ;; Beams as LilyPond draws them (automatic or typed): each stem's
      ;; moment, written when the voice ends and every beam is complete.
      (acknowledgers
       ((stem-interface engraver grob source)
        (hashq-set! stems grob (fmac-now ctx)))
       ((beam-interface engraver grob source)
        (if (not (memq grob beams)) (set! beams (cons grob beams)))))
      ((finalize engraver)
       (for-each
        (lambda (beam)
          (let* ((array (ly:grob-object beam 'stems))
                 (moments (filter-map (lambda (stem) (hashq-ref stems stem))
                                      (if (ly:grob-array? array) (ly:grob-array->list array) '()))))
            (if (> (length moments) 1) (apply fmac-out "beam" ctx moments))))
        (reverse beams))
       (if fmac-port (force-output fmac-port)))
      (listeners
       ((music-event engraver event)
        (if (not (memq (car (ly:event-property event 'class '(unknown))) fmac-ignored))
            (set! events (cons event events)))))
      ((process-music engraver)
       (if (pair? events)
           (let ((staff (ly:context-find ctx 'Staff)) (now (fmac-now ctx)))
             (for-each
              (lambda (event)
                (fmac-event-record ctx (or staff "") now event #f)
                (for-each (lambda (inner) (fmac-event-record ctx (or staff "") now inner #t))
                          (ly:event-property event 'articulations '())))
              (reverse events)))))
      ((stop-translation-timestep engraver) (set! events '())))))

#(define (fmac-lyrics-engraver ctx)
   (let ((events '()))
     (make-engraver
      (listeners
       ((lyric-event engraver event) (set! events (cons event events)))
       ((hyphen-event engraver event) (set! events (cons event events)))
       ((extender-event engraver event) (set! events (cons event events))))
      ((process-music engraver)
       (for-each (lambda (event)
                   (fmac-out "lyric" ctx (fmac-now ctx) (car (ly:event-property event 'class))
                             (ly:event-property event 'text #f)
                             (or (ly:context-property ctx 'associatedVoiceContext #f) "")))
                 (reverse events)))
      ((stop-translation-timestep engraver) (set! events '())))))

\layout {
  \context { \Score \consists #fmac-score-engraver }
  \context { \Staff \consists #fmac-staff-engraver }
  \context { \Voice \consists #fmac-voice-engraver }
  \context { \Lyrics \consists #fmac-lyrics-engraver }
}
