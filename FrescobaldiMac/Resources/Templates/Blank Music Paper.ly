\version "$LILYPOND_VERSION"

{
  \repeat unfold 12$CURSOR
  {
    s1
    \break
  }
}

\layout {
  \context {
    \Score
    \remove "Bar_number_engraver"
  }
  \context {
    \Staff
    \remove "Clef_engraver"
    \remove "Time_signature_engraver"
    \remove "Bar_engraver"
  }
}

\paper {
  indent = 0
  ragged-last-bottom = ##f
  top-system-spacing = #'((minimum-distance . 10))
  last-bottom-spacing = #'((minimum-distance . 10))
}

\header {
  tagline = ##f
}

