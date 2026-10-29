\version "$LILYPOND_VERSION"

\header {
  title = ""
}

global = {
  \time 4/4
  \key c \major
  \tempo 4=100
}

chordNames = \chordmode {
  \global
  c1

}

melody = \relative c'' {
  \global
  c4 d e f
  $CURSOR
}

words = \lyricmode {


}

\score {
  <<
    \new ChordNames \chordNames
    \new FretBoards \chordNames
    \new Staff { \melody }
    \addlyrics { \words }
  >>
  \layout { }
  \midi { }
}
