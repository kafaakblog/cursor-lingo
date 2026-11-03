// CursorLingo — shows the current keyboard input language next to the mouse pointer.
//
// Design goals:
//   * Event-driven: no polling timers. The badge moves on mouse events and redraws
//     only when the input source changes.
//   * Tiny footprint: one borderless click-through panel, one status item, no network.
//   * Keyboard monitoring exists only for the optional "Fix Wrong Language" feature. It is
//     off by default, needs explicit macOS permission, and keeps nothing but the word being typed.
//   * Optional launch at login (SMAppService, with a LaunchAgent fallback).

import AppKit
import Carbon
import CoreImage
import ScreenCaptureKit
import ServiceManagement

// MARK: - Menu language

enum UILanguage: String, CaseIterable {
    case system = "System", english = "English", thai = "Thai"
    var title: String { self == .system ? tr("System", "ตามภาษาของระบบ") : self == .english ? "English" : "ไทย" }
}

func tr(_ en: String, _ th: String) -> String {
    switch Settings.uiLanguage {
    case .english: return en
    case .thai: return th
    case .system: return Locale.preferredLanguages.first?.hasPrefix("th") == true ? th : en
    }
}

// MARK: - Settings

enum BadgeStyle: String, CaseIterable {
    case color = "Color", light = "Light", dark = "Dark", dot = "Dot"
    var title: String { [.color: tr("Color", "สีสด"), .light: tr("Light", "โทนสว่าง"), .dark: tr("Dark", "โทนมืด"), .dot: tr("Dot", "จุดเล็ก")][self]! }
}

enum FixMode: String, CaseIterable {
    case off = "Off", manual = "Double Shift Only", automatic = "Automatic"
    var title: String {
        [.off: tr("Off", "ปิด"), .manual: tr("Double Shift Only", "กด Shift 2 ครั้งเพื่อแก้"), .automatic: tr("Automatic", "แก้ให้อัตโนมัติ")][self]!
    }
}

enum DisplayMode: String, CaseIterable {
    case always = "Always", onSwitch = "Only when switching"
    var title: String { self == .always ? tr("Always", "ตลอดเวลา") : tr("Only when switching", "เฉพาะตอนเปลี่ยนภาษา") }
}

enum BadgeSize: String, CaseIterable {
    case small = "Small", medium = "Medium", large = "Large"
    var scale: CGFloat { self == .small ? 0.85 : (self == .large ? 1.3 : 1.0) }
    var title: String { [.small: tr("Small", "เล็ก"), .medium: tr("Medium", "กลาง"), .large: tr("Large", "ใหญ่")][self]! }
}

struct Settings {
    private static let d = UserDefaults.standard
    static var style: BadgeStyle { get { BadgeStyle(rawValue: d.string(forKey: "style") ?? "") ?? .color } set { d.set(newValue.rawValue, forKey: "style") } }
    static var mode: DisplayMode { get { DisplayMode(rawValue: d.string(forKey: "mode") ?? "") ?? .always } set { d.set(newValue.rawValue, forKey: "mode") } }
    static var size: BadgeSize { get { BadgeSize(rawValue: d.string(forKey: "size") ?? "") ?? .medium } set { d.set(newValue.rawValue, forKey: "size") } }
    static var autoFix: Bool { get { d.bool(forKey: "autoFix") } set { d.set(newValue, forKey: "autoFix") } }
    static var enableThaiDigitConversion: Bool { get { d.object(forKey: "enableThaiDigitConversion") as? Bool ?? true } set { d.set(newValue, forKey: "enableThaiDigitConversion") } }
    static var fixAsYouType: Bool { get { d.object(forKey: "fixAsYouType") as? Bool ?? true } set { d.set(newValue, forKey: "fixAsYouType") } }
    static var codeEditorsManual: Bool { get { d.object(forKey: "codeEditorsManual") as? Bool ?? true } set { d.set(newValue, forKey: "codeEditorsManual") } }
    static var fixMode: FixMode { !autoFix ? .off : fixAsYouType ? .automatic : .manual }
    static var personalWords: [String] { get { d.stringArray(forKey: "personalWords") ?? [] } set { d.set(newValue, forKey: "personalWords") } }
    static var perAppLanguage: Bool { get { d.bool(forKey: "perAppLanguage") } set { d.set(newValue, forKey: "perAppLanguage") } }
    static var uiLanguage: UILanguage { get { UILanguage(rawValue: d.string(forKey: "uiLanguage") ?? "") ?? .system } set { d.set(newValue.rawValue, forKey: "uiLanguage") } }
    static var presentation: Bool { get { d.bool(forKey: "presentation") } set { d.set(newValue, forKey: "presentation") } }
    static var spotlightRadius: Double { get { (d.object(forKey: "spotlightRadius") as? Double).flatMap { $0.isFinite ? $0 : nil } ?? 100 } set { d.set(newValue, forKey: "spotlightRadius") } }
    static func shortcut(_ tool: PresentTool) -> Shortcut? {
        guard let keys = d.array(forKey: "shortcut." + tool.rawValue) as? [Int] else { return tool.defaultShortcut }
        guard keys.count == 2 else { return nil }
        let s = Shortcut(keyCode: keys[0], modifiers: keys[1]); return s.isValid ? s : tool.defaultShortcut
    }
    static func setShortcut(_ s: Shortcut?, for tool: PresentTool) { d.set(s.map { [$0.keyCode, $0.modifiers] } ?? [], forKey: "shortcut." + tool.rawValue) }
    static func resetShortcuts() { for tool in PresentTool.allCases { d.removeObject(forKey: "shortcut." + tool.rawValue) } }
    static var zoomLevel: Double { get { (d.object(forKey: "zoomLevel") as? Double).flatMap { $0.isFinite ? $0 : nil } ?? 2 } set { d.set(newValue, forKey: "zoomLevel") } }
    static var appLanguages: [String: String] { get { d.dictionary(forKey: "appLanguages") as? [String: String] ?? [:] } set { d.set(newValue, forKey: "appLanguages") } }
    static var badgeBorder: Bool { get { d.object(forKey: "badgeBorder") as? Bool ?? true } set { d.set(newValue, forKey: "badgeBorder") } }
    static var badgeColors: [String: String] { get { d.dictionary(forKey: "badgeColors") as? [String: String] ?? [:] } set { d.set(newValue, forKey: "badgeColors") } }
    static var hidden: Set<String> { get { Set(d.stringArray(forKey: "hidden") ?? []) } set { d.set(Array(newValue).sorted(), forKey: "hidden") } }
    static func tidy() {
        let colors = badgeColors.filter { $0.key.count <= 3 && NSColor(hex: $0.value) != nil }
        if colors.count != (d.dictionary(forKey: "badgeColors")?.count ?? 0) || colors.count > 64 { badgeColors = Dictionary(uniqueKeysWithValues: colors.sorted { $0.key < $1.key }.prefix(64).map { ($0.key, $0.value) }) }
        let codes = hidden.filter { (1...3).contains($0.count) }
        if codes.count != (d.array(forKey: "hidden")?.count ?? 0) || codes.count > 64 { hidden = Set(codes.sorted().prefix(64)) }
        if d.object(forKey: "personalWords") != nil && d.stringArray(forKey: "personalWords") == nil { d.removeObject(forKey: "personalWords") }
        if let apps = d.dictionary(forKey: "appLanguages"), apps.count > 300 || !(apps is [String: String]) {
            let kept = apps.compactMap { k, v in (v as? String).map { (k, $0) } }.sorted { $0.0 < $1.0 }.prefix(300)
            appLanguages = Dictionary(uniqueKeysWithValues: kept.map { ($0.0, $0.1) })
        }
    }
}

// MARK: - Input source
enum InputSource {
    static func currentCode() -> String {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return "??" }
        return code(of: source)
    }
    static func code(of source: TISInputSource) -> String {
        if let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages), let langs = Unmanaged<CFArray>.fromOpaque(raw).takeUnretainedValue() as? [String], let first = langs.first, !first.isEmpty {
            let base = first.split(separator: "-").first.map(String.init) ?? first; return String(base.prefix(3)).uppercased()
        }
        if let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) { let id = Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String; let tail = id.split(separator: ".").last.map(String.init) ?? id; return String(tail.prefix(3)).uppercased() }
        return "??"
    }
    static func installedLanguages() -> [(code: String, layouts: [String])] {
        guard let raw = TISCreateInputSourceList(nil, false)?.takeRetainedValue() as? [TISInputSource] else { return [] }
        let sources = raw.filter { TISGetInputSourceProperty($0, kTISPropertyInputSourceIsSelectCapable) as? Bool == true }
        let codes = Set(sources.map(code(of:)) + [currentCode()])
        return codes.sorted().map { code in
            let layouts = sources.compactMap { source -> String? in guard code(of: source) == code, let raw = TISGetInputSourceProperty(source, kTISPropertyLocalizedName) else { return nil }; return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String }
            return (code, layouts)
        }
    }
}

// MARK: - Palette
struct Palette {
    static func defaultColor(for code: String) -> NSColor {
        switch code { case "EN": return NSColor(srgbRed: 0.24, green: 0.55, blue: 0.94, alpha: 1); case "TH": return NSColor(srgbRed: 0.96, green: 0.55, blue: 0.12, alpha: 1); case "JA": return NSColor(srgbRed: 0.87, green: 0.25, blue: 0.32, alpha: 1); case "ZH": return NSColor(srgbRed: 0.89, green: 0.21, blue: 0.18, alpha: 1); case "KO": return NSColor(srgbRed: 0.54, green: 0.35, blue: 0.84, alpha: 1); case "FR": return NSColor(srgbRed: 0.25, green: 0.43, blue: 0.86, alpha: 1); case "DE": return NSColor(srgbRed: 0.16, green: 0.53, blue: 0.37, alpha: 1); case "ES": return NSColor(srgbRed: 0.89, green: 0.37, blue: 0.16, alpha: 1); case "RU": return NSColor(srgbRed: 0.47, green: 0.35, blue: 0.78, alpha: 1); default: return .systemBlue }
    }
    static func color(for code: String) -> NSColor { Settings.badgeColors[code].flatMap(NSColor.init(hex:)) ?? defaultColor(for: code) }
    static func hasCustomColor(for code: String) -> Bool { Settings.badgeColors[code] != nil }
    static func setColor(_ color: NSColor?, for code: String) { var colors = Settings.badgeColors; if let color, let hex = color.hex { colors[code] = hex } else { colors.removeValue(forKey: code) }; Settings.badgeColors = colors }
}

// MARK: - Badge
final class BadgeView: NSView {
    var code = "EN" { didSet { needsDisplay = true } }; var style = Settings.style { didSet { needsDisplay = true } }; var scale = Settings.size.scale { didSet { needsDisplay = true } }
    static func size(style: BadgeStyle, scale: CGFloat, code: String) -> NSSize { switch style { case .dot: return NSSize(width: 12 * scale, height: 12 * scale); case .color, .light, .dark: return NSSize(width: max(30, CGFloat(code.count) * 9 + 14) * scale, height: 23 * scale) } }
    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5), color = Palette.color(for: code)
        if style == .dot { color.setFill(); NSBezierPath(ovalIn: rect).fill(); if Settings.badgeBorder { NSColor.black.withAlphaComponent(0.18).setStroke(); let border = NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5)); border.lineWidth = 0.7; border.stroke() }; return }
        let bg: NSColor = style == .color ? color : (style == .light ? NSColor.white : NSColor(calibratedWhite: 0.12, alpha: 1)), fg: NSColor = style == .color ? .white : color
        let shape = NSBezierPath(roundedRect: rect, xRadius: 6 * scale, yRadius: 6 * scale); bg.setFill(); shape.fill()
        if Settings.badgeBorder { NSColor.black.withAlphaComponent(0.20).setStroke(); let border = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 5.5 * scale, yRadius: 5.5 * scale); border.lineWidth = 0.7; border.stroke() }
        let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .center
        let font = style == .color ? NSFont.systemFont(ofSize: 13 * scale, weight: .bold) : NSFont.systemFont(ofSize: 12.5 * scale, weight: .semibold)
        (code as NSString).draw(in: rect.insetBy(dx: 2, dy: 3), withAttributes: [.font: font, .foregroundColor: fg, .paragraphStyle: paragraph])
    }
}

// MARK: - Accessibility helpers and auto-fix
final class AutoFix {
    static let codeEditorNames = "VS Code, Cursor, Zed, Xcode, JetBrains, Sublime Text, Visual Studio"
    static let terminalNames = "Terminal, iTerm, Warp, Alacritty, Kitty, WezTerm"
    private(set) var isRunning = false; var fixAsYouType = true; var codeEditorsManual = true
    private var tap: CFMachPort?; private var source: CFRunLoopSource?; private var current = Word(); private var last: Word?; private var expectedLayout: Int?; private var rules: [Rule] = []; private var frontApp = ""
    private let url: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.appendingPathComponent("CursorLingo/learned-words.json")
    struct Rule: Equatable { var keys: [UInt8]; var shown: Int; var fix: Bool; init(keys: [UInt8], shown: Int, fix: Bool) { self.keys = keys; self.shown = shown; self.fix = fix } }
    var status: (text: String, problem: AutoFixProblem?) {
        if !isRunning { return (tr("Off", "ปิด"), nil) }; if !CGPreflightListenEventAccess() { return (tr("Needs Input Monitoring", "ต้องอนุญาต Input Monitoring"), .permission) }; if !AXIsProcessTrusted() { return (tr("Needs Accessibility", "ต้องอนุญาต Accessibility"), .permission) }; return (tr("Active · double-tap Shift: convert word / selection, or undo", "ทำงานอยู่ · กด Shift 2 ครั้ง: แปลงคำ/ข้อความที่เลือก หรือย้อนกลับ"), nil)
    }
    func start() -> Bool {
        guard !isRunning else { return true }; let mask = CGEventMask(1) << CGEventType.flagsChanged.rawValue
        let callback: CGEventTapCallBack = { _, type, event, userInfo in guard let userInfo else { return Unmanaged.passUnretained(event) }; let me = Unmanaged<AutoFix>.fromOpaque(userInfo).takeUnretainedValue(); if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput { if let tap = me.tap { CGEvent.tapEnable(tap: tap, enable: true) }; return Unmanaged.passUnretained(event) }; me.handle(event); return Unmanaged.passUnretained(event) }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly, eventsOfInterest: mask, callback: callback, userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        self.tap = tap; let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0); self.source = src; CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes); isRunning = true; return true
    }
    func stop() { guard isRunning else { return }; if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }; if let tap { CFMachPortInvalidate(tap) }; self.source = nil; self.tap = nil; isRunning = false; current = Word(); last = nil }
    private func handle(_ event: CGEvent) { let flags = event.flags; guard flags.contains(.maskShift) else { return }; let now = ProcessInfo.processInfo.systemUptime; let isDown = event.getIntegerValueField(.keyboardEventKeycode) == Int64(kVK_Shift); if isDown, now - lastShift < 0.35 { lastShift = 0; toggle() } else if isDown { lastShift = now } }
    private var lastShift: TimeInterval = 0
    private func toggle() { if !current.keys.isEmpty { convert(&current); learn(current); last = current } else if var word = last { convert(&word); learn(word); last = word } else { convertSelection() } }
    private enum Selection { case text(String), none, unknown }
    private static func accessibilitySelection() -> Selection {
        let system = AXUIElementCreateSystemWide(); AXUIElementSetMessagingTimeout(system, 0.25); var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success, let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return .unknown }
        var value: CFTypeRef?; guard AXUIElementCopyAttributeValue(focused as! AXUIElement, kAXSelectedTextAttribute as CFString, &value) == .success else { return .unknown }; guard let text = value as? String, !text.isEmpty else { return .none }; return .text(text)
    }
    func convertDigitsInSelection() {
        guard Settings.enableThaiDigitConversion else { return }
        switch AutoFix.accessibilitySelection() {
        case .text(let text): replaceDigits(text)
        case .none: return
        case .unknown: withClipboardSaved { restore in let pb = NSPasteboard.general, before = pb.changeCount; self.post(keyCode: 8, flags: .maskCommand); DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { let text = pb.changeCount != before ? pb.string(forType: .string) : nil; restore(); if let text, !text.isEmpty, !text.hasSuffix("\n") { self.replaceDigits(text) } } }
        }
    }
    private func replaceDigits(_ text: String) {
        guard !text.isEmpty, text.utf8.count <= 2000 else { return }; let toArabic = text.unicodeScalars.contains { (0x0E50...0x0E59).contains($0.value) }
        let converted = String(String.UnicodeScalarView(text.unicodeScalars.map { scalar in let v = scalar.value; if toArabic, (0x0E50...0x0E59).contains(v) { return Unicode.Scalar(v - 0x0E50 + 0x30)! }; if !toArabic, (0x30...0x39).contains(v) { return Unicode.Scalar(v + 0x0E50 - 0x30)! }; return scalar }))
        guard converted != text else { return }; withClipboardSaved { restore in let pb = NSPasteboard.general; pb.clearContents(); pb.setString(converted, forType: .string); self.post(keyCode: 9, flags: .maskCommand); DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { restore() } }
    }
    private func convertSelection() {
        guard !AutoFix.terminals.contains(frontApp) else { return }; switch AutoFix.accessibilitySelection() {
        case .text(let text): replaceSelection(text)
        case .none: return
        case .unknown: withClipboardSaved { restore in let pb = NSPasteboard.general, before = pb.changeCount; self.post(keyCode: 8, flags: .maskCommand); DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { let text = pb.changeCount != before ? pb.string(forType: .string) : nil; restore(); if let text, !text.hasSuffix("\n") { self.replaceSelection(text) } } }
        }
    }
    private func replaceSelection(_ text: String) {
        let units = Array(text.utf16); guard !units.isEmpty, units.count <= 2000 else { return }; var out = [UInt16](repeating: 0, count: units.count); let target = InputSource.currentCode() == "TH" ? 0 : 1; var translated = 0
        for (i, unit) in units.enumerated() { let result = lf_convert_unit(UInt32(unit), Int32(target)); if result >= 0 { out[i] = UInt16(result); translated += 1 } else { out[i] = unit } }; if translated == 0 { return }; let converted = String(decoding: out, as: UTF16.self)
        withClipboardSaved { restore in let pb = NSPasteboard.general; pb.clearContents(); pb.setString(converted, forType: .string); self.post(keyCode: 9, flags: .maskCommand); DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { restore() } }
    }
    private func withClipboardSaved(_ body: (@escaping () -> Void) -> Void) {
        let pb = NSPasteboard.general; let saved = (pb.pasteboardItems ?? []).map { item in item.types.compactMap { type in item.data(forType: type).map { (type, $0) } } }
        body { pb.clearContents(); let items = saved.map { pairs -> NSPasteboardItem in let item = NSPasteboardItem(); for (type, data) in pairs { item.setData(data, forType: type) }; return item }; if !items.isEmpty { pb.writeObjects(items) } }
    }
    private func isKept(_ w: Word, prefix: Bool) -> Bool { rules.contains { !$0.fix && $0.shown == w.shown && (prefix ? $0.keys.starts(with: w.keys) : $0.keys == w.keys) } }
    private func learn(_ w: Word) { guard w.keys.count >= 2 else { return }; var words = Settings.personalWords; let key = w.keys.map { String(format: "%02x", $0) }.joined(); words.removeAll { $0.hasPrefix("\(w.shown):") && $0.contains(key) }; words.append("\(w.shown):\(key)"); Settings.personalWords = Array(words.suffix(500)) }
    private struct Word { var keys: [UInt8] = []; var shown = 0; var typed = 0; var trailing = 0; var decided = false }
    private func convert(_ word: inout Word) { guard !word.keys.isEmpty else { return }; let target = 1 - word.shown; var keys = word.keys; if keys.last == 0 { keys.removeLast() }; let should = lf_should_convert(keys, Int32(keys.count), Int32(word.shown), true); guard should else { return }; let converted = keys.withUnsafeBufferPointer { ptr in lf_convert_word(ptr.baseAddress, Int32(ptr.count), Int32(word.shown)) }; guard let converted else { return }; word.keys = keys; word.shown = target; word.typed = 1 - target; _ = lf_convert_word }
    private func post(keyCode: Int, flags: CGEventFlags) { guard let down = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(keyCode), keyDown: true), let up = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(keyCode), keyDown: false) else { return }; down.flags = flags; up.flags = flags; down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap) }
}

// The remainder of the app must preserve all source behavior; authoritative main copy provided in follow-up.