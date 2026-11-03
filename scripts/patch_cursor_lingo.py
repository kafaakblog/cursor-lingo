#!/usr/bin/env python3
"""Rebuild macOS source from pinned pristine revision and add Thai digit conversion."""
from pathlib import Path
from urllib.request import urlopen
PIN = "97ca936555ebcec7be8adafe2f80256f259e0910"
URL = f"https://raw.githubusercontent.com/kafaakblog/cursor-lingo/{PIN}/macos/CursorLingo.swift"
path = Path("macos/CursorLingo.swift")
source = urlopen(URL, timeout=30).read().decode("utf-8")
if len(source.splitlines()) != 2744:
    raise SystemExit("Unexpected pristine source length")
def replace_once(old, new):
    global source
    if source.count(old) != 1:
        raise SystemExit(f"Expected exactly one anchor: {old[:70]!r}")
    source = source.replace(old, new, 1)
replace_once('    /// With Auto-fix on: fix words by themselves (true), or only when double Shift asks for it (false).', '''    /// Toggle ASCII digits and Thai digits in selected text. Enabled by default.
    static var enableThaiDigitConversion: Bool {
        get { d.object(forKey: "enableThaiDigitConversion") as? Bool ?? true }
        set { d.set(newValue, forKey: "enableThaiDigitConversion") }
    }
    /// With Auto-fix on: fix words by themselves (true), or only when double Shift asks for it (false).''')
replace_once('    private func convertSelection() {', '''    func convertDigitsInSelection() {
        guard Settings.enableThaiDigitConversion else { return }
        switch AutoFix.accessibilitySelection() {
        case .text(let text): replaceDigits(text)
        case .none: return
        case .unknown:
            withClipboardSaved { restore in
                let pb = NSPasteboard.general
                let before = pb.changeCount
                self.post(keyCode: 8, flags: .maskCommand)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    let text = pb.changeCount != before ? pb.string(forType: .string) : nil
                    restore()
                    if let text, !text.isEmpty, !text.hasSuffix("\\n") { self.replaceDigits(text) }
                }
            }
        }
    }
    private func replaceDigits(_ text: String) {
        guard !text.isEmpty, text.utf8.count <= 2000 else { return }
        let toArabic = text.unicodeScalars.contains { (0x0E50...0x0E59).contains($0.value) }
        let converted = String(String.UnicodeScalarView(text.unicodeScalars.map { scalar in
            let v = scalar.value
            if toArabic, (0x0E50...0x0E59).contains(v) { return Unicode.Scalar(v - 0x0E50 + 0x30)! }
            if !toArabic, (0x30...0x39).contains(v) { return Unicode.Scalar(v + 0x0E50 - 0x30)! }
            return scalar
        }))
        guard converted != text else { return }
        withClipboardSaved { restore in
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(converted, forType: .string)
            self.post(keyCode: 9, flags: .maskCommand)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { restore() }
        }
    }
    private func convertSelection() {''')
replace_once('        if mode != .off {\n            let status = app.autoFix.status', '''        views.append(separator())
        views.append(optionRow(tr("Enable Thai Digit Conversion (0-9 ↔ ๐-๙)", "เปิดใช้งานการแปลงเลขไทย ↔ อารบิก (0-9 ↔ ๐-๙)"),
                               tr("Select text and use ⌃⌥R to convert digits.", "เลือกข้อความแล้วกด ⌃⌥R เพื่อแปลงตัวเลข"),
                               toggle(Settings.enableThaiDigitConversion, #selector(digitConversionChanged(_:)))))
        if mode != .off {
            let status = app.autoFix.status''')
replace_once('    @objc private func codeEditorsChanged(_ sender: NSSwitch) {', '''    @objc private func digitConversionChanged(_ sender: NSSwitch) {
        Settings.enableThaiDigitConversion = sender.state == .on
        reload()
    }
    @objc private func codeEditorsChanged(_ sender: NSSwitch) {''')
replace_once('        menu.addItem(presentationMenu())', '        menu.addItem(presentationMenu())\n        menu.addItem(item(tr("Convert Thai ↔ Arabic Digits", "แปลงเลขไทย ↔ อารบิก"), #selector(convertSelectedDigits)))')
replace_once('    @objc func pickUILanguage(_ s: NSMenuItem) {', '    @objc private func convertSelectedDigits() { autoFix.convertDigitsInSelection() }\n\n    @objc func pickUILanguage(_ s: NSMenuItem) {')
replace_once('        return failed\n    }\n    private func toggle(_ tool: PresentTool)', '''        let digitKey = HotKey(keyCode: kVK_ANSI_R, modifiers: controlKey | optionKey) { [weak self] in
            self?.autoFix.convertDigitsInSelection()
        }
        if digitKey.registered { presentationKeys.append(digitKey) }
        return failed
    }
    private func toggle(_ tool: PresentTool)''')
if len(source.splitlines()) != 2804:
    raise SystemExit(f"Expected 2804 lines, got {len(source.splitlines())}")
if "placeholder" in source.lower() or "remainder of the app" in source.lower():
    raise SystemExit("Placeholder detected")
path.write_text(source)
print(f"Patched {path}: {len(source.splitlines())} lines")
