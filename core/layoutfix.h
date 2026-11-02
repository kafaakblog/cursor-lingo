// Wrong-keyboard-layout detection for English (US QWERTY) <-> Thai (Kedmanee).
//
// Principle: a keystroke is a *physical key*, and each physical key produces one character in
// every layout. So a word typed in the wrong layout is not random text - it is the right text
// seen through the wrong key map. For every word we therefore compute both readings:
//
//     on screen  : what the current layout produced
//     alternative: what the other layout would have produced from the very same keys
//
// and convert only when the on-screen reading looks like gibberish for its language while the
// alternative looks like a real word of the other one:
//
//   * English plausibility: a letter-trigram model (core/en_model.inc, generated from a word list).
//     Real words are cheap; Thai text typed on a Latin layout is full of impossible sequences and
//     punctuation keys (; ' , . [ ]) inside words.
//   * Thai plausibility: orthographic structure. Thai script has strict rules (a word cannot start
//     with a tone mark or a trailing vowel, vowels must sit on consonants, a leading vowel must be
//     followed by a consonant, ...). English typed on the Thai layout breaks them almost at once.
//
// Precision matters more than recall: wrongly "fixing" correct text is far worse than missing a
// typo, so every rule below errs on the side of leaving the text alone.
//
// Header-only, no allocation, no platform dependencies. Code points are written as escapes, so the
// header compiles the same whatever source encoding the compiler assumes.

#pragma once
#include <cstdint>
#include <cstring>
#include <string>

namespace lf {

enum Lang { LANG_EN = 0, LANG_TH = 1 };

// A key is its index into the physical-key table below, with bit 7 set when Shift (or Caps) is on.
constexpr int kKeyCount = 47;
constexpr uint8_t kShiftBit = 0x80;
constexpr int kMaxWord = 48;

#include "en_model.inc"

// Physical keys in ANSI order: number row, QWERTY row, home row, bottom row.
static const char kEnBase[] = "`1234567890-=qwertyuiop[]\\asdfghjkl;'zxcvbnm,./";
static const char kEnShift[] = "~!@#$%^&*()_+QWERTYUIOP{}|ASDFGHJKL:\"ZXCVBNM<>?";
// Thai Kedmanee, written as escapes so that no compiler can misread the source encoding
// (MSVC without /utf-8 reads source files in the ANSI code page).
static const char16_t kThBase[] = u"_+๑๒๓๔ู฿๕๖๗๘๙๐-=๐";
