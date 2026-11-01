\version "2.24.0"

%% Piano tables: both staves of a piano passage typed as a table.
%%
%% Written into the project by Frescobaldi for macOS (Insert Piano Table),
%% so the score compiles with plain LilyPond anywhere. It's an independent
%% implementation of an idea from Paolo Prete's Spontini Editor.
%% Part of Frescobaldi for macOS, GPL-2.0-or-later.
%%
%% Cross-staff passages, used in the upper staff's music:
%%
%%   \pianoTable
%%     #'(    U          -       C            - )         % beams (optional)
%%     { \col c''8[ \col s  \col <e' g'> \col s  \col }   % upper staff
%%     { \col s8    \col g  \col c       \col e] \col }   % lower staff
%%
%% \col separates the columns; it does nothing by itself, so the rows are
%% ordinary music. A column is one stretch of time: both cells have the
%% same length, or one of them is empty. Notes from both rows become one
%% voice that changes staff (\change Staff), so beams can join them; when
%% both cells have notes, the lower ones join the upper stems (\crossStaff).
%% The optional list, before the rows, says where each column's beam goes:
%%   U  above (stems up)       D  below (stems down)
%%   C  between the staves     N  no cross-staff: each row stays in its
%%   -  as the column before       staff, as its own voice
%% Without the list LilyPond chooses. A beam or slur that starts or ends
%% on a skip (s8]) goes to the note in the other row. A \tuplet may span
%% columns, with \col inside it in both rows. Pitches are absolute (c' is
%% middle C), also inside \relative, which goes on after the table from
%% the note before it; a row may be \relative or \fixed itself.
%%
%% Polyphony without cross-staff, each row its own voice:
%%
%%   \pianoTablePoly 2 {
%%     { \col c'''4 \col d''' \col e''' \col f''' \col }   % upper, voice 1
%%     { \col a'2   \col      \col b'2   \col      \col }   % upper, voice 2
%%     { \col c'1   \col      \col       \col      \col }   % lower, voice 1
%%   }
%%
%% The number says how many rows are in the upper staff. Here a column is
%% only for the eye: an empty cell is time a longer note fills.
%%
%% The staves are found by name, "right" and "left" (as Frescobaldi's New
%% Score makes them); set pianoTableStaves = #'("upper" . "lower") for
%% others.

pianoTableStaves = #'("right" . "left")

col = #(make-music 'SequentialMusic 'elements '() 'piano-table-column #t)

#(define (pt-column? m)
   (and (ly:music? m) (ly:music-property m 'piano-table-column #f)))

#(define (pt-children m)
   (let ((e (ly:music-property m 'element #f)))
     (append (ly:music-property m 'elements '()) (if (ly:music? e) (list e) '()))))

#(define (pt-any? pred m)
   (let walk ((m m))
     (or (pred m) (any walk (pt-children m)))))

#(define (pt-notes? cell)
   (any (lambda (piece) (pt-any? (lambda (m) (music-is-of-type? m 'note-event)) (car piece))) cell))

#(define (pt-rests? cell)
   (any (lambda (piece)
          (pt-any? (lambda (m) (or (music-is-of-type? m 'rest-event)
                                   (music-is-of-type? m 'multi-measure-rest))) (car piece)))
        cell))

%% A row's cells: lists of pieces (music . tuplet), where tuplet is the
%% \tuplet the piece was in, if that \tuplet had columns inside.
#(define (pt-cells row)
   (let ((cells '()) (current '()) (at-edge #f))
     ;; at-edge: a \col just before or after a tuplet's brace, which is the
     ;; same column boundary as a \col on the other side of the brace.
     (define (finish!)
       (set! cells (cons (reverse current) cells))
       (set! current '()))
     (define (add! m tuplet)
       (set! at-edge #f)
       (set! current (cons (cons m tuplet) current)))
     (define (walk m tuplet)
       (cond
        ((pt-column? m)
         (if (and at-edge (null? current))
             (set! at-edge #f)
             (begin (finish!) (set! at-edge #f))))
        ((not (pt-any? pt-column? m)) (add! m tuplet))
        ((music-is-of-type? m 'sequential-music)
         (for-each (lambda (e) (walk e tuplet)) (ly:music-property m 'elements)))
        ((music-is-of-type? m 'relative-octave-music)
         (walk (ly:music-property m 'element) tuplet))
        ((and (music-is-of-type? m 'time-scaled-music) (not tuplet))
         (let* ((inner (ly:music-property m 'element))
                (elements (if (music-is-of-type? inner 'sequential-music)
                              (ly:music-property inner 'elements)
                              (list inner))))
           (set! at-edge (null? current))
           (for-each (lambda (e) (walk e m)) elements)
           (set! at-edge (and (pair? elements) (pt-column? (last elements))))))
        (else
         (ly:music-warning m (G_ "piano table: \\col can't be used inside this"))
         (add! m tuplet))))
     (walk row #f)
     (finish!)
     ;; The markers at both ends only delimit the row.
     (let* ((cells (reverse cells))
            (cells (if (and (pair? cells) (null? (car cells))) (cdr cells) cells))
            (cells (if (and (pair? cells) (null? (last cells))) (drop-right cells 1) cells)))
       cells)))

%% Music for pieces: runs from the same \tuplet (by key) are wrapped in a
%% copy of it, so a tuplet that spans columns keeps one bracket.
#(define (pt-music pieces key)
   (let loop ((pieces pieces) (out '()))
     (if (null? pieces)
         (make-sequential-music (reverse out))
         (let* ((tuplet (cdar pieces))
                (k (and tuplet (key tuplet)))
                (run (if tuplet
                         (take-while (lambda (p) (and (cdr p) (equal? (key (cdr p)) k))) pieces)
                         (list (car pieces))))
                (rest (list-tail pieces (length run)))
                (seq (make-sequential-music (map car run))))
           (loop rest
                 (cons (if tuplet
                           (let ((copy (ly:music-deep-copy tuplet)))
                             (ly:music-set-property! copy 'element seq)
                             copy)
                           seq)
                       out))))))

#(define (pt-length cell)
   (ly:music-length (pt-music cell (lambda (t) t))))

#(define (pt-positive? moment) (ly:moment<? ZERO-MOMENT moment))

%% The row without its column markers.
#(define (pt-strip music)
   (let ((copy (ly:music-deep-copy music)))
     (let walk ((m copy))
       (let ((elements (ly:music-property m 'elements '()))
             (element (ly:music-property m 'element #f)))
         (when (pair? elements)
           (ly:music-set-property! m 'elements (remove pt-column? elements))
           (for-each walk (ly:music-property m 'elements)))
         (when (ly:music? element) (walk element))))
     copy))

%% Beams and slurs that start or end on a skip of a cell that isn't used
%% (`s8]` under a note): moved to the first (start) or last (end) note
%% of the cell that is.
#(define (pt-spans cell)
   (append-map
    (lambda (piece)
      (let collect ((m (car piece)))
        (append
         (if (music-is-of-type? m 'skip-event)
             (filter (lambda (a) (memq (ly:music-property a 'name) '(BeamEvent SlurEvent PhrasingSlurEvent)))
                     (ly:music-property m 'articulations '()))
             '())
         (append-map collect (pt-children m)))))
    cell))

#(define (pt-rhythmic-events cell)
   (append-map
    (lambda (piece)
      (let collect ((m (car piece)))
        (if (or (music-is-of-type? m 'event-chord)
                (music-is-of-type? m 'note-event)
                (music-is-of-type? m 'rest-event))
            (list m)
            (append-map collect (pt-children m)))))
    cell))

#(define (pt-adopt-spans! cell from)
   (let ((spans (pt-spans from))
         (events (pt-rhythmic-events cell)))
     (when (and (pair? spans) (pair? events))
       (for-each
        (lambda (span)
          (let* ((target (if (eqv? (ly:music-property span 'span-direction) STOP) (last events) (car events)))
                 (key (if (music-is-of-type? target 'event-chord) 'elements 'articulations)))
            (ly:music-set-property! target key
                                    (append (ly:music-property target key '()) (list (ly:music-deep-copy span))))))
        spans))))

#(define (pt-skip length)
   (make-music 'SkipEvent 'duration (make-duration-of-length length)))

#(define (pt-stems direction)
   (case direction
     ((up) #{ \stemUp #})
     ((down) #{ \stemDown #})
     (else #{ \stemNeutral #})))

pianoTable =
#(define-music-function (beams upper lower) ((list? '()) ly:music? ly:music?)
   (_i "Both staves of a piano passage as a table: where each column's
beam goes (@code{U D C N -}, optional), then the @var{upper} and
@var{lower} rows with @code{\\col} between the columns.")
   (let* ((staves (ly:parser-lookup 'pianoTableStaves))
          (up-staff (car staves))
          (down-staff (cdr staves))
          ;; Copies: cells are changed (spans moved) and rows may be variables.
          (ups (pt-cells (ly:music-deep-copy upper)))
          (downs (pt-cells (ly:music-deep-copy lower)))
          (count (max (length ups) (length downs)))
          (ups (append ups (make-list (- count (length ups)) '())))
          (downs (append downs (make-list (- count (length downs)) '())))
          (letters (let loop ((ls beams) (previous 'auto) (out '()))
                     (if (null? ls)
                         (reverse out)
                         (let ((l (if (eq? (car ls) '-) previous (car ls))))
                           (loop (cdr ls) l (cons l out))))))
          (letters (append letters (make-list (max 0 (- count (length letters)))
                                              (if (pair? letters) (last letters) 'auto))))
          ;; The columns each \tuplet spans, to join its pieces again.
          (spans (make-hash-table))
          (key (lambda (t)
                 (list (ly:music-property t 'numerator) (ly:music-property t 'denominator)
                       (hashq-ref spans t)))))
     (when (> (length ups) (length downs) 0)
       (ly:music-warning lower (G_ "piano table: the lower row has fewer columns")))
     (when (> (length downs) (length ups) 0)
       (ly:music-warning upper (G_ "piano table: the upper row has fewer columns")))
     (for-each
      (lambda (cell index)
        (for-each (lambda (piece)
                    (let ((t (cdr piece)))
                      (when t
                        (let ((span (hashq-ref spans t (cons index index))))
                          (hashq-set! spans t (cons (min index (car span)) (max index (cdr span))))))))
                  cell))
      (append ups downs)
      (append (iota count) (iota count)))
     (let ((main '()) (second '()) (in-lower #f) (stems #f))
       ;; main: pieces of the voice that changes staff; second: the lower
       ;; staff's own voice (split chords, N columns).
       (define (main! m tuplet) (set! main (cons (cons m tuplet) main)))
       (define (second! m tuplet) (set! second (cons (cons m tuplet) second)))
       (define (cell! cell) (for-each (lambda (p) (main! (car p) (cdr p))) cell))
       (define (to-staff! lower? tuplet)
         (unless (eq? lower? in-lower)
           (main! #{ \change Staff = #(if lower? down-staff up-staff) #} tuplet)
           (set! in-lower lower?)))
       (define (stems! direction tuplet)
         (unless (eq? direction stems)
           (main! (pt-stems direction) tuplet)
           (set! stems direction)))
       (define (first-tuplet cell) (and (pair? cell) (cdar cell)))
       (for-each
        (lambda (up down letter index)
          (let* ((up-length (pt-length up))
                 (down-length (pt-length down))
                 (length (if (ly:moment<? up-length down-length) down-length up-length))
                 (up-notes (pt-notes? up))
                 (down-notes (pt-notes? down))
                 (tuplet (or (first-tuplet up) (first-tuplet down))))
            (when (and (pt-positive? up-length) (pt-positive? down-length)
                       (or (ly:moment<? up-length down-length) (ly:moment<? down-length up-length)))
              (ly:music-warning upper (format #f (G_ "piano table: the cells of column ~a have different lengths")
                                              (1+ index))))
            (cond
             ((eq? letter 'N)
              ;; Each row in its own staff and voice.
              (to-staff! #f tuplet)
              (stems! 'neutral tuplet)
              (if (null? up) (main! (pt-skip length) #f) (cell! up))
              (if (null? down)
                  (second! (pt-skip length) #f)
                  (for-each (lambda (p) (second! (car p) (cdr p))) down)))
             ((or up-notes (and (not down-notes) (pt-rests? up)))
              ;; The upper notes lead; lower notes at the same time join
              ;; their stems.
              (to-staff! #f (first-tuplet up))
              (stems! (case letter ((U) 'up) ((D C) 'down) (else 'neutral)) (first-tuplet up))
              (unless down-notes (pt-adopt-spans! up down))
              (cell! up)
              (when (ly:moment<? up-length length)
                (main! (pt-skip (ly:moment-sub length up-length)) #f))
              (if (or down-notes (pt-rests? down))
                  (second! (if down-notes
                               #{ \crossStaff {
                                    $(pt-stems (case letter ((D) 'down) (else 'up)))
                                    $(pt-music down key) } #}
                               (pt-music down key))
                           #f)
                  (second! (pt-skip length) #f)))
             ((or down-notes (pt-rests? down))
              (to-staff! #t (first-tuplet down))
              (stems! (case letter ((U C) 'up) ((D) 'down) (else 'neutral)) (first-tuplet down))
              (pt-adopt-spans! down up)
              (cell! down)
              (second! (pt-skip length) #f))
             (else
              (main! (pt-skip length) #f)
              (second! (pt-skip length) #f)))))
        ups downs letters (iota count))
       (to-staff! #f #f)
       (stems! 'neutral #f)
       (make-music
        'RelativeOctaveMusic
        'element
        ;; \context Voice: the voice the music around the table is in. Without
        ;; it a table at the start of a staff makes its own voice, and the
        ;; music after it would be in the staff, where \change Staff can't
        ;; work.
        #{ <<
             \context Voice $(pt-music (reverse main) key)
             \new Voice {
               \change Staff = #down-staff
               $(pt-music (reverse second) key)
             }
           >> #}))))

pianoTablePoly =
#(define-music-function (upper rows) (index? ly:music?)
   (_i "Both staves of a piano passage as a table with a row per voice:
the first @var{upper} rows in the upper staff, the others in the lower.")
   (let* ((staves (ly:parser-lookup 'pianoTableStaves))
          (rows (filter (lambda (m) (not (pt-column? m)))
                        (if (music-is-of-type? rows 'sequential-music)
                            (ly:music-property rows 'elements)
                            (list rows))))
          (ups (take rows (min upper (length rows))))
          (downs (list-tail rows (min upper (length rows)))))
     (define (voices rows staff)
       (map (lambda (row index)
              (let ((music (pt-strip row)))
                #{ \new Voice {
                     \change Staff = #staff
                     $(if (= (length rows) 1)
                          #{ \oneVoice #}
                          (case index
                            ((0) #{ \voiceOne #}) ((1) #{ \voiceTwo #})
                            ((2) #{ \voiceThree #}) (else #{ \voiceFour #})))
                     #music
                   } #}))
            rows (iota (length rows))))
     (make-music
      'RelativeOctaveMusic
      'element
      (make-simultaneous-music (append (voices ups (car staves)) (voices downs (cdr staves)))))))

\layout {
  \context {
    \PianoStaff
    \consists "Span_stem_engraver"
  }
}
