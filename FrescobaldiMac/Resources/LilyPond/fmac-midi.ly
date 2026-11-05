%% Frescobaldi for macOS: a MIDI file for scores without a \midi block.
%%
%% Export MIDI passes this file with -dinclude-settings when the score
%% wrote no MIDI file, in a run that only makes the MIDI file. Each score
%% gets a \midi block, with its repeats played out as \unfoldRepeats
%% would. The source is left alone.
%%
%% The repeats are unfolded before LilyPond prepares a score's music
%% (toplevel-music-functions): unfolding it later breaks the lengths
%% LilyPond has worked out by then.
%%
%% Part of Frescobaldi for macOS, GPL-2.0-or-later.

#(set! toplevel-music-functions (cons unfold-repeats-fully toplevel-music-functions))

#(define (fmac-has-midi? score)
   (any (lambda (def) (eq? (ly:output-def-lookup def 'output-def-kind #f) 'midi)) (ly:score-output-defs score)))

#(define (fmac-add-midi! score)
   (if (and (ly:score? score) (not (fmac-has-midi? score)))
       (ly:score-add-output-def! score $defaultmidi)))

%% \score blocks, and music outside one, at the top, in a \book or a \bookpart.
#(let ((toplevel toplevel-score-handler) (book book-score-handler) (bookpart bookpart-score-handler))
   (set! toplevel-score-handler (lambda (score) (fmac-add-midi! score) (toplevel score)))
   (set! book-score-handler (lambda (b score) (fmac-add-midi! score) (book b score)))
   (set! bookpart-score-handler (lambda (b score) (fmac-add-midi! score) (bookpart b score)))
   (set! toplevel-music-handler
         (lambda (music)
           (collect-music-aux (lambda (score) (fmac-add-midi! score) (collect-scores-for-book score)) music)))
   (set! book-music-handler
         (lambda (b music)
           (collect-music-aux (lambda (score) (fmac-add-midi! score) (ly:book-add-score! b score)) music)))
   (set! bookpart-music-handler
         (lambda (b music)
           (collect-music-aux (lambda (score) (fmac-add-midi! score) (ly:book-add-score! b score)) music))))
