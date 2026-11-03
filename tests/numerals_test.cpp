#include "numerals.h"
#include "layoutfix_c.h"
#include <cstdio>
#include <cstdlib>
#include <string>

static void check(bool ok, const char* message) {
    if (!ok) { std::fprintf(stderr, "FAIL: %s\n", message); std::exit(1); }
}

int main() {
    const std::u16string samples[][2] = {
        {u"0123456789", u"๐๑๒๓๔๕๖๗๘๙"},
        {u"๐๑๒๓๔๕๖๗๘๙", u"0123456789"},
        {u"Order 42: บ้าน ๙๙ 🙂", u"Order ๔๒: บ้าน 99 🙂"},
        {u"-001,234.50 / ๒๕๖๙\r\nLine 2\t", u"-๐๐๑,๒๓๔.๕๐ / 2569\r\nLine ๒\t"},
        {u"ไทย English 🙂 ١٢٣ １２３", u"ไทย English 🙂 ١٢٣ １２３"},
        {u"", u""},
    };
    for (const auto& pair : samples) {
        const auto& input = pair[0];
        std::u16string output(input.size(), 0), back(input.size(), 0);
        bool changed = lf::convertNumerals(input.data(), (int)input.size(), output.data());
        check(output == pair[1], "UTF-16 conversion preserves non-digits and numeric value");
        check(changed == (input != pair[1]), "no-op detection");
        lf::convertNumerals(output.data(), (int)output.size(), back.data());
        check(back == input, "round trip");
        lf::convertNumerals(back.data(), (int)back.size(), back.data());
        check(back == output, "in-place conversion");
        std::u16string bridge(input.size(), 0);
        check(lf_convert_numerals(reinterpret_cast<const uint16_t*>(input.data()), (int)input.size(),
                                  reinterpret_cast<uint16_t*>(bridge.data())) == changed, "Swift bridge result");
        check(bridge == output, "Swift bridge output");
    }
    lf::DoubleTap tap;
    check(!tap.update(true, 100, true), "first down");
    check(!tap.update(false, 150, true), "first tap");
    check(!tap.update(true, 250, true), "second down");
    check(tap.update(false, 300, true), "double tap");
    check(!tap.update(false, 310, true), "stray release");
    tap.update(true, 400, true); tap.update(false, 450, true);
    tap.update(true, 500, true); tap.reset();
    check(!tap.update(false, 550, true), "intervening key/click/focus change cancels");
    tap.update(true, 600, false);
    check(!tap.update(false, 650, true), "modifier chord does not count");
    tap.update(true, 700, true);
    check(!tap.update(false, 1100, true), "hold does not count");
    tap.update(true, 1200, true); tap.update(false, 1250, true);
    tap.update(true, 1800, true);
    check(!tap.update(false, 1850, true), "slow taps do not trigger");
    tap.reset();
    tap.update(true, 0xFFFFFF80u, true); tap.update(false, 0xFFFFFFA0u, true);
    tap.update(true, 10, true);
    check(tap.update(false, 30, true), "clock wraparound");
    std::puts("all numeral and double-tap tests passed");
}
