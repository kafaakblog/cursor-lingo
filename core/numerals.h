// Value-based digit conversion; independent of the active keyboard layout.
#pragma once
#include <cstdint>

namespace lf {
// Toggles each digit, including mixed-script selections. Other UTF-16 units stay intact.
// The caller supplies n output units; in-place conversion is supported.
inline bool convertNumerals(const char16_t* in, int n, char16_t* out) {
    bool changed = false;
    for (int i = 0; i < n; ++i) {
        char16_t c = in[i];
        if (c >= u'0' && c <= u'9') { c = char16_t(u'\u0E50' + c - u'0'); changed = true; }
        else if (c >= u'\u0E50' && c <= u'\u0E59') { c = char16_t(u'0' + c - u'\u0E50'); changed = true; }
        out[i] = c;
    }
    return changed;
}

// Two clean, short presses of the same modifier. Chords, holds, clicks and focus
// changes cancel the sequence. Unsigned subtraction also handles clock wraparound.
struct DoubleTap {
    bool down = false, clean = false, hasTap = false;
    uint32_t pressed = 0, released = 0;
    void reset() { down = clean = hasTap = false; }
    bool update(bool isDown, uint32_t now, bool alone) {
        if (isDown) {
            if (!down) { down = true; clean = alone; pressed = now; }
            return false;
        }
        bool tap = down && clean && alone && uint32_t(now - pressed) < 350;
        down = clean = false;
        if (!tap) { hasTap = false; return false; }
        if (hasTap && uint32_t(now - released) < 450) { hasTap = false; return true; }
        hasTap = true;
        released = now;
        return false;
    }
};
} // namespace lf
