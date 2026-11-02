// Run all tests (from the repo root):
//   c++ -std=c++17 -I core tests/layoutfix_test.cpp -o /tmp/lf_test && /tmp/lf_test
// Ask about one word, as it appears on screen in the given layout:
//   /tmp/lf_test en "l;ylfu"      /tmp/lf_test th "ะ้รห"
// Real-world cases live in tests/cases.tsv; add a line there when you find a wrong or missed fix.
#include "layoutfix.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <string>
#include <vector>

using namespace lf;

static std::vector<uint8_t> keysFor(const char16_t* text, Lang lang) {
    std::vector<uint8_t> out;
    for (const char16_t* p = text; *p; p++) {
        int found = -1;
        for (int i = 0; i < kKeyCount * 2 && found < 0; i++) {
            uint8_t k = (uint8_t)((i % kKeyCount) | (i >= kKeyCount ? kShiftBit : 0));
            if (charFor(k, lang) == *p) found = k;
        }
        if (found < 0) { printf("untypable char U+%04X\n", *p); std::exit(2); }
        out.push_back((uint8_t)found);
    }
    return out;
}

static std::u16string fromUtf8(const std::string& s) {
    std::u16string out;
    for (size_t i = 0; i < s.size();) {
        unsigned char c = s[i];
        int len = c < 0x80 ? 1 : (c >> 5) == 6 ? 2 : (c >> 4) == 14 ? 3 : 4;
        uint32_t cp = len == 1 ? c : len == 2 ? c & 0x1F : len == 3 ? c & 0x0F : c & 0x07;
        for (int j = 1; j < len; j++) cp = (cp << 6) | (static_cast<unsigned char>(s[i + j]) & 0x3F);
        if (cp <= 0xFFFF) out.push_back((char16_t)cp);
        else { cp -= 0x10000; out.push_back((char16_t)(0xD800 | (cp >> 10))); out.push_back((char16_t)(0xDC00 | (cp & 0x3FF))); }
        i += len;
    }
    return out;
}

static int failures = 0;

static void expect(const char* name, const char16_t* text, Lang lang, bool want, bool finished = true) {
    auto keys = keysFor(text, lang);
    bool got = shouldConvert(keys.data(), (int)keys.size(), lang, finished);
    if (got != want) { printf("FAIL: %s: got %d, want %d\n", name, got, want); failures++; }
}

static int runCases(const char* path, int& count) {
    std::ifstream f(path);
    if (!f) { printf("could not open %s\n", path); return 1; }
    std::string line;
    while (std::getline(f, line)) {
        if (line.empty() || line[0] == '#') continue;
        size_t a = line.find('\t'), b = line.find('\t', a + 1);
        if (a == std::string::npos || b == std::string::npos) continue;
        std::string lang = line.substr(0, a), text = line.substr(a + 1, b - a - 1), action = line.substr(b + 1);
        Lang l = lang == "th" ? LANG_TH : LANG_EN;
        std::u16string u = fromUtf8(text);
        auto keys = keysFor(u.c_str(), l);
        bool got = shouldConvert(keys.data(), (int)keys.size(), l, true);
        bool want = action == "fix";
        if (got != want) { printf("FAIL: cases.tsv line %d (%s): got %s, want %s\n", count + 1, text.c_str(), got ? "fix" : "keep", want ? "fix" : "keep"); failures++; }
        count++;
    }
    return 0;
}

static int explain(const char* layout, const char* utf8) {
    Lang l = strcmp(layout, "th") == 0 ? LANG_TH : LANG_EN;
    std::u16string u = fromUtf8(utf8);
    auto keys = keysFor(u.c_str(), l);
    char16_t other[128]; render(keys.data(), (int)keys.size(), l == LANG_TH ? LANG_EN : LANG_TH, other);
    printf("on screen (%s): %s\nother layout:     ", layout, utf8);
    for (char16_t c : std::u16string(other)) putchar(c < 128 ? (char)c : '?');
    printf("\n%s\n", shouldConvert(keys.data(), (int)keys.size(), l, true) ? "converts" : "keeps");
    return 0;
}

int main(int argc, char** argv) {
    if (argc == 3) return explain(argv[1], argv[2]);
    // Mapping sanity: the same keys read through the other layout.
    {
        auto k = keysFor(u"l;ylfu;yoouhgik", LANG_EN);
        char16_t th[64];
        render(k.data(), (int)k.size(), LANG_TH, th);
        std::u16string s(th);
        if (s != u"สวัสดีวันนี้เรา") { printf("FAIL: mapping\n"); failures++; }
        auto k2 = keysFor(u"ะ้รห", LANG_TH);
        char16_t en[64];
        render(k2.data(), (int)k2.size(), LANG_EN, en);
        if (std::u16string(en) != u"this") { printf("FAIL: mapping 2\n"); failures++; }
    }

    // Thai typed on the English layout -> convert.
    expect("sawasdee", u"l;ylfu;yoouhgik", LANG_EN, true);
    expect("sawasdee (mid-word)", u"l;ylfu;yoouhgik", LANG_EN, true, false);
    expect("khob khun", u"ขอบคุณ", LANG_TH, false);
    {   // Common Thai words typed on the English layout (the Thai text is what the keys mean).
        const char16_t* words[] = {u"ขอบคุณ", u"ตอนนี้", u"ช่วย", u"หน่อย", u"เรียบร้อย", u"มี", u"ทำงาน"};
        for (auto w : words) {
            auto k = keysFor(w, LANG_TH);
            if (!shouldConvert(k.data(), (int)k.size(), LANG_EN, true)) { printf("FAIL: Thai word not fixed\n"); failures++; }
        }
    }
    // English on Thai layout -> convert.
    expect("this on Thai layout", u"ะ้รห", LANG_TH, true);
    expect("hello on Thai layout", u"้ำสสน", LANG_TH, true);
    // Correct text must never change.
    expect("English word", u"hello", LANG_EN, false);
    expect("English word 2", u"keyboard", LANG_EN, false);
    expect("English with comma", u"hello,", LANG_EN, false);
    expect("contraction", u"don't", LANG_EN, false);
    expect("Thai word", u"สวัสดี", LANG_TH, false);
    expect("Thai sentence run", u"ผมกำลังพิมพ์ภาษาไทย", LANG_TH, false);
    expect("short English", u"is", LANG_EN, false);
    expect("short English + comma", u"a,", LANG_EN, false);
    expect("two digits", u"4k", LANG_EN, false);
    expect("cli flag", u"-e", LANG_EN, false);
    expect("number", u"2024", LANG_EN, false);
    expect("path", u"src/main.swift", LANG_EN, false);
    expect("email", u"me@example.com", LANG_EN, false);
    expect("code", u"std::vector", LANG_EN, false);
    expect("mid-word Thai prefix is left alone", u"สวัสดี", LANG_TH, false, false);

    // Selections are converted character by character, keeping what is not on the keyboard.
    {
        const char16_t* in = u"ะ้รห รห ฟ ืำไ ทนกำส\nl;ylfu 🙂";
        int n = (int)std::u16string(in).size();
        std::u16string a(n, 0), b(n, 0);
        int to = convertText(in, n, &a[0]);
        if (to != LANG_EN || a.substr(0, 19) != u"this is a new model") { printf("FAIL: selection TH->EN\n"); failures++; }
        int back = convertText(a.c_str(), n, &b[0]);
        if (back != LANG_TH || b.substr(0, 19) != std::u16string(in).substr(0, 19)) { printf("FAIL: selection round trip\n"); failures++; }
        char16_t z[4]; if (convertText(u"123", 3, z) != -1) { printf("FAIL: digits only\n"); failures++; }
    }

    // UTF-8 Thai/Arabic digit toggle: mappings, mixed text, and round-trip.
    {
        const std::string ascii = "0123456789";
        const std::string thai = u8"๐๑๒๓๔๕๖๗๘๙";
        if (toggleDigits(ascii) != thai || toggleDigits(thai) != ascii || toggleDigits(toggleDigits(ascii)) != ascii) { printf("FAIL: digit mapping / round trip\n"); failures++; }
        if (toggleDigits(u8"Order 42: บ้าน ๙๙ 🙂") != u8"Order ๔๒: บ้าน 99 🙂") { printf("FAIL: mixed digit text\n"); failures++; }
        if (toggleDigits(u8"ปี ๒๕๖๙") != u8"ปี 2569") { printf("FAIL: Thai text digits\n"); failures++; }
    }

    int cases = 0;
    failures += runCases(argc == 2 ? argv[1] : "tests/cases.tsv", cases);
    if (failures) { printf("%d failure(s)\n", failures); return 1; }
    printf("all layoutfix tests passed (%d cases from cases.tsv)\n", cases);
    return 0;
}
