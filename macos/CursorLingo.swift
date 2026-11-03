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

/// The menu speaks English or Thai: the system's language by default, or what the user picked.
enum UILanguage: String, CaseIterable {
    case system = "System", english = "English", thai = "Thai"
    var title: String { self == .system ? tr("System", "ตามภาษาของระบบ") : self == .english ? "English" : "ไทย" }
}

/// The English or the Thai text, whichever the menu currently speaks.
func tr(_ en: String, _ th: String) -> String {
    switch Settings.uiLanguage {
    case .english: return en
    case .thai: return th
    case .system: return Locale.preferredLanguages.first?.hasPrefix("th") == true ? th : en
    }
}

// MARK: - Settings

// Raw values are what is stored in the preferences; `title` is what the menu shows.

enum BadgeStyle: String, CaseIterable {
    case color = "Color", light = "Light", dark = "Dark", dot = "Dot"
    var title: String { [.color: tr("Color", "สีสด"), .light: tr("Light", "โทนสว่าง"), .dark: tr("Dark", "โทนมืด"), .dot: tr("Dot", "จุดเล็ก")][self]! }
}

/// Fix Wrong Language: off, only when double Shift asks for it, or also by itself as you type.
enum FixMode: String, CaseIterable {
    case off = "Off", manual = "Double Shift Only", automatic = "Automatic"
    var title: String {
        [.off: tr("Off", "ปิด"), .manual: tr("Double Shift Only", "กด Shift 2 ครั้งเพื่อแก้"),
         .automatic: tr("Automatic", "แก้ให้อัตโนมัติ")][self]!
    }
}

enum DisplayMode: String, CaseIterable {
    case always = "Always"
    case onSwitch = "Only when switching"
    var title: String { self == .always ? tr("Always", "ตลอดเวลา") : tr("Only when switching", "เฉพาะตอนเปลี่ยนภาษา") }
}

enum BadgeSize: String, CaseIterable {
    case small = "Small", medium = "Medium", large = "Large"
    var scale: CGFloat { self == .small ? 0.85 : (self == .large ? 1.3 : 1.0) }
    var title: String { [.small: tr("Small", "เล็ก"), .medium: tr("Medium", "กลาง"), .large: tr("Large", "ใหญ่")][self]! }
}

struct Settings {
    private static let d = UserDefaults.standard

    static var style: BadgeStyle {
        get { BadgeStyle(rawValue: d.string(forKey: "style") ?? "") ?? .color }
        set { d.set(newValue.rawValue, forKey: "style") }
    }
    static var mode: DisplayMode {
        get { DisplayMode(rawValue: d.string(forKey: "mode") ?? "") ?? .always }
        set { d.set(newValue.rawValue, forKey: "mode") }
    }
    static var size: BadgeSize {
        get { BadgeSize(rawValue: d.string(forKey: "size") ?? "") ?? .medium }
        set { d.set(newValue.rawValue, forKey: "size") }
    }
    /// Re-type words that were typed in the wrong layout (EN <-> TH). Off by default.
    static var autoFix: Bool {
        get { d.bool(forKey: "autoFix") }
        set { d.set(newValue, forKey: "autoFix") }
    }
    /// Toggle ASCII digits and Thai digits in selected text. Enabled by default.
    static var enableThaiDigitConversion: Bool {
        get { d.object(forKey: "enableThaiDigitConversion") as? Bool ?? true }
        set { d.set(newValue, forKey: "enableThaiDigitConversion") }
    }
    /// With Auto-fix on: fix words by themselves (true), or only when double Shift asks for it (false).
    static var fixAsYouType: Bool {
        get { d.object(forKey: "fixAsYouType") as? Bool ?? true }
        set { d.set(newValue, forKey: "fixAsYouType") }
    }
    /// In code editors identifiers often look like gibberish, so there only double Shift converts. On by default.
    static var codeEditorsManual: Bool {
        get { d.object(forKey: "codeEditorsManual") as? Bool ?? true }
        set { d.set(newValue, forKey: "codeEditorsManual") }
    }
    /// The Fix Wrong Language menu: stored as autoFix (on/off) + fixAsYouType, so older settings carry over.
    static var fixMode: FixMode { !autoFix ? .off : fixAsYouType ? .automatic : .manual }
    /// The personal word list (see AutoFix.Rule), one entry per word: "<layout><+|->" then the keys in hex.
    static var personalWords: [String] {
        get { d.stringArray(forKey: "personalWords") ?? [] }
        set { d.set(newValue, forKey: "personalWords") }
    }
    /// Switch to the layout each app was last used with when it comes to the front. Off by default.
    static var perAppLanguage: Bool {
        get { d.bool(forKey: "perAppLanguage") }
        set { d.set(newValue, forKey: "perAppLanguage") }
    }
    static var uiLanguage: UILanguage {
        get { UILanguage(rawValue: d.string(forKey: "uiLanguage") ?? "") ?? .system }
        set { d.set(newValue.rawValue, forKey: "uiLanguage") }
    }
    /// Presentation spotlight: the screen dimmed except around the pointer. Off by default.
    static var presentation: Bool {
        get { d.bool(forKey: "presentation") }
        set { d.set(newValue, forKey: "presentation") }
    }
    /// Radius of the presentation spotlight, in points.
    static var spotlightRadius: Double {
        get { (d.object(forKey: "spotlightRadius") as? Double).flatMap { $0.isFinite ? $0 : nil } ?? 100 }
        set { d.set(newValue, forKey: "spotlightRadius") }
    }
    /// The shortcut of a presentation tool: its default until changed, nil once cleared.
    static func shortcut(_ tool: PresentTool) -> Shortcut? {
        guard let keys = d.array(forKey: "shortcut." + tool.rawValue) as? [Int] else { return tool.defaultShortcut }
        guard keys.count == 2 else { return nil }
        let s = Shortcut(keyCode: keys[0], modifiers: keys[1])
        return s.isValid ? s : tool.defaultShortcut  // edited by hand into something no key press could make
    }
    static func setShortcut(_ s: Shortcut?, for tool: PresentTool) {
        d.set(s.map { [$0.keyCode, $0.modifiers] } ?? [], forKey: "shortcut." + tool.rawValue)
    }
    static func resetShortcuts() {
        for tool in PresentTool.allCases { d.removeObject(forKey: "shortcut." + tool.rawValue) }
    }
    /// Magnification of the presentation zoom lens.
    static var zoomLevel: Double {
        get { (d.object(forKey: "zoomLevel") as? Double).flatMap { $0.isFinite ? $0 : nil } ?? 2 }
        set { d.set(newValue, forKey: "zoomLevel") }
    }
    /// Bundle ID -> input source ID it was last used with (for perAppLanguage).
    static var appLanguages: [String: String] {
        get { d.dictionary(forKey: "appLanguages") as? [String: String] ?? [:] }
        set { d.set(newValue, forKey: "appLanguages") }
    }
    /// The thin outline around the badge. On by default.
    static var badgeBorder: Bool {
        get { d.object(forKey: "badgeBorder") as? Bool ?? true }
        set { d.set(newValue, forKey: "badgeBorder") }
    }
    /// Badge colours picked in Settings: language code -> "#RRGGBB".
    static var badgeColors: [String: String] {
        get { d.dictionary(forKey: "badgeColors") as? [String: String] ?? [:] }
        set { d.set(newValue, forKey: "badgeColors") }
    }
    /// Language codes (e.g. "EN") for which the badge is hidden.
    static var hidden: Set<String> {
        get { Set(d.stringArray(forKey: "hidden") ?? []) }
        set { d.set(Array(newValue).sorted(), forKey: "hidden") }
    }
    /// At launch: the lists only ever grow by a few entries at a time, but the preferences file can be edited, or
    /// damaged. Keep what the app could have written itself, within its limits, and save that back, so a huge or
    /// broken file costs neither memory nor time from then on.
    static func tidy() {
        let colors = badgeColors.filter { $0.key.count <= 3 && NSColor(hex: $0.value) != nil }
        if colors.count != (d.dictionary(forKey: "badgeColors")?.count ?? 0) || colors.count > 64 {
            badgeColors = Dictionary(uniqueKeysWithValues: colors.sorted { $0.key < $1.key }.prefix(64).map { ($0.key, $0.value) })
        }
        let codes = hidden.filter { (1...3).contains($0.count) }
        if codes.count != (d.array(forKey: "hidden")?.count ?? 0) || codes.count > 64 { hidden = Set(codes.sorted().prefix(64)) }
        if d.object(forKey: "personalWords") != nil && d.stringArray(forKey: "personalWords") == nil {
            d.removeObject(forKey: "personalWords")  // not a list of words: nothing in it can be read
        }
        if let apps = d.dictionary(forKey: "appLanguages"), apps.count > 300 || !(apps is [String: String]) {
            let kept = apps.compactMap { k, v in (v as? String).map { (k, $0) } }.sorted { $0.0 < $1.0 }.prefix(300)
            appLanguages = Dictionary(uniqueKeysWithValues: kept.map { ($0.0, $0.1) })
        }
    }
}

// MARK: - Input source

enum InputSource {
    /// Short uppercase code for the selected keyboard input source, e.g. "EN", "TH", "JA".
    static func currentCode() -> String {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return "??" }
        return code(of: source)
    }

    static func code(of source: TISInputSource) -> String {
        if let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages),
           let langs = Unmanaged<CFArray>.fromOpaque(raw).takeUnretainedValue() as? [String],
           let first = langs.first, !first.isEmpty {
            let base = first.split(separator: "-").first.map(String.init) ?? first
            return String(base.prefix(3)).uppercased()
        }
        if let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) {
            let id = Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
            let tail = id.split(separator: ".").last.map(String.init) ?? id
            return String(tail.prefix(3)).uppercased()
        }
        return "??"
    }

    /// The keyboards added in System Settings, with their layouts behind each one (e.g. EN / U.S.).
    static func installedLanguages() -> [(code: String, layouts: [String])] {
        guard let raw = TISCreateInputSourceList(nil, false)?.takeRetainedValue() as? [TISInputSource] else { return [] }
        let sources = raw.filter { TISGetInputSourceProperty($0, kTISPropertyInputSourceIsSelectCapable) as? Bool == true }
        let codes = Set(sources.map(code(of:)) + [currentCode()])
        return codes.sorted().map { code in
            let layouts = sources.compactMap { source -> String? in
                guard code(of: source) == code,
                      let raw = TISGetInputSourceProperty(source, kTISPropertyLocalizedName) else { return nil }
                return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
            }
            return (code, layouts)
        }
    }
}

// MARK: - Palette

struct Palette {
    static func defaultColor(for code: String) -> NSColor {
        switch code {
        case "EN": return NSColor(srgbRed: 0.24, green: 0.55, blue: 0.94, alpha: 1)
        case "TH": return NSColor(srgbRed: 0.96, green: 0.55, blue: 0.12, alpha: 1)
        case "JA": return NSColor(srgbRed: 0.87, green: 0.25, blue: 0.32, alpha: 1)
        case "ZH": return NSColor(srgbRed: 0.89, green: 0.21, blue: 0.18, alpha: 1)
        case "KO": return NSColor(srgbRed: 0.54, green: 0.35, blue: 0.84, alpha: 1)
        case "FR": return NSColor(srgbRed: 0.25, green: 0.43, blue: 0.86, alpha: 1)
        case "DE": return NSColor(srgbRed: 0.16, green: 0.53, blue: 0.37, alpha: 1)
        case "ES": return NSColor(srgbRed: 0.89, green: 0.37, blue: 0.16, alpha: 1)
        case "RU": return NSColor(srgbRed: 0.47, green: 0.35, blue: 0.78, alpha: 1)
        default: return .systemBlue
        }
    }

    /// The colour picked in Settings, or the built-in one.
    static func color(for code: String) -> NSColor {
        Settings.badgeColors[code].flatMap(NSColor.init(hex:)) ?? defaultColor(for: code)
    }

    static func hasCustomColor(for code: String) -> Bool { Settings.badgeColors[code] != nil }
    static func setColor(_ color: NSColor?, for code: String) {
        var colors = Settings.badgeColors
        if let color, let hex = color.hex { colors[code] = hex } else { colors.removeValue(forKey: code) }
        Settings.badgeColors = colors
    }
}

// MARK: - Badge

final class BadgeView: NSView {
    var code = "EN" { didSet { needsDisplay = true } }
    var style = Settings.style { didSet { needsDisplay = true } }
    var scale = Settings.size.scale { didSet { needsDisplay = true } }

    static func size(style: BadgeStyle, scale: CGFloat, code: String) -> NSSize {
        switch style {
        case .dot: return NSSize(width: 12 * scale, height: 12 * scale)
        case .color, .light, .dark:
            let width = max(30, CGFloat(code.count) * 9 + 14) * scale
            return NSSize(width: width, height: 23 * scale)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let color = Palette.color(for: code)
        if style == .dot {
            color.setFill()
            NSBezierPath(ovalIn: rect).fill()
            if Settings.badgeBorder {
                NSColor.black.withAlphaComponent(0.18).setStroke()
                let border = NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5))
                border.lineWidth = 0.7
                border.stroke()
            }
            return
        }

        let bg: NSColor = style == .color ? color : (style == .light ? NSColor.white : NSColor(calibratedWhite: 0.12, alpha: 1))
        let fg: NSColor = style == .color ? .white : color
        let shape = NSBezierPath(roundedRect: rect, xRadius: 6 * scale, yRadius: 6 * scale)
        bg.setFill()
        shape.fill()

        // Hairline border keeps the badge readable in any background (unless turned off in Settings).
        if Settings.badgeBorder {
            NSColor.black.withAlphaComponent(0.20).setStroke()
            let border = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 5.5 * scale, yRadius: 5.5 * scale)
            border.lineWidth = 0.7
            border.stroke()
        }

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let font = style == .color ? NSFont.systemFont(ofSize: 13 * scale, weight: .bold)
                                   : NSFont.systemFont(ofSize: 12.5 * scale, weight: .semibold)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: fg,
            .paragraphStyle: paragraph,
        ]
        (code as NSString).draw(in: rect.insetBy(dx: 2, dy: 3), withAttributes: attributes)
    }
}

// MARK: - Accessibility helpers and auto-fix

final class AutoFix {
    static let codeEditorNames = "VS Code, Cursor, Zed, Xcode, JetBrains, Sublime Text, Visual Studio"
    static let terminalNames = "Terminal, iTerm, Warp, Alacritty, Kitty, WezTerm"

    private(set) var isRunning = false
    var fixAsYouType = true
    var codeEditorsManual = true
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var current = Word()
    private var last: Word?
    private var expectedLayout: Int?
    private var rules: [Rule] = []
    private var frontApp = ""
    private let url: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        .appendingPathComponent("CursorLingo/learned-words.json")

    struct Rule: Equatable {
        var keys: [UInt8]
        var shown: Int
        var fix: Bool
        init(keys: [UInt8], shown: Int, fix: Bool) { self.keys = keys; self.shown = shown; self.fix = fix }
    }

    var status: (text: String, problem: AutoFixProblem?) {
        if !isRunning { return (tr("Off", "ปิด"), nil) }
        if !CGPreflightListenEventAccess() { return (tr("Needs Input Monitoring", "ต้องอนุญาต Input Monitoring"), .permission) }
        if !AXIsProcessTrusted() { return (tr("Needs Accessibility", "ต้องอนุญาต Accessibility"), .permission) }
        return (tr("Active · double-tap Shift: convert word / selection, or undo", "ทำงานอยู่ · กด Shift 2 ครั้ง: แปลงคำ/ข้อความที่เลือก หรือย้อนกลับ"), nil)
    }

    func start() -> Bool {
        guard !isRunning else { return true }
        let mask = CGEventMask(1) << CGEventType.flagsChanged.rawValue
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let me = Unmanaged<AutoFix>.fromOpaque(userInfo).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = me.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                return Unmanaged.passUnretained(event)
            }
            me.handle(event)
            return Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                          options: .listenOnly, eventsOfInterest: mask,
                                          callback: callback, userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            return false
        }
        self.tap = tap
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.source = src
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        isRunning = true
        return true
    }

    func stop() {
        guard isRunning else { return }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        self.source = nil
        self.tap = nil
        isRunning = false
        current = Word()
        last = nil
    }

    private func handle(_ event: CGEvent) {
        let flags = event.flags
        guard flags.contains(.maskShift) else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let isDown = event.getIntegerValueField(.keyboardEventKeycode) == Int64(kVK_Shift)
        if isDown, now - lastShift < 0.35 {
            lastShift = 0
            toggle()
        } else if isDown {
            lastShift = now
        }
    }

    private var lastShift: TimeInterval = 0

    private func toggle() {
        if !current.keys.isEmpty {
            convert(&current)
            learn(current)
        } else if var word = last {
            convert(&word)
            learn(word)
            last = word
        } else {
            convertSelection()
        }
    }

    // MARK: Selection

    private enum Selection { case text(String), none, unknown }

    /// Asks the focused text field for its selection through Accessibility (no clipboard involved).
    private static func accessibilitySelection() -> Selection {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.25)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return .unknown }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(focused as! AXUIElement, kAXSelectedTextAttribute as CFString, &value) == .success
        else { return .unknown }
        guard let text = value as? String, !text.isEmpty else { return .none }
        return .text(text)
    }

    /// Convert selected digits, preferring Thai-to-Arabic if any Thai digit is present.
    func convertDigitsInSelection() {
        guard Settings.enableThaiDigitConversion, !AutoFix.terminals.contains(frontApp) else { return }
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
                    if let text, !text.isEmpty, !text.hasSuffix("\n") { self.replaceDigits(text) }
                }
            }
        }
    }

    private func replaceDigits(_ text: String) {
        guard !text.isEmpty, text.utf8.count <= 2000 else { return }
        let toArabic = text.unicodeScalars.contains { (0x0E50...0x0E59).contains($0.value) }
        let converted = String(String.UnicodeScalarView(text.unicodeScalars.map { scalar in
            let value = scalar.value
            if toArabic, (0x0E50...0x0E59).contains(value) { return Unicode.Scalar(value - 0x0E50 + 0x30)! }
            if !toArabic, (0x30...0x39).contains(value) { return Unicode.Scalar(value + 0x0E50 - 0x30)! }
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

    private func convertSelection() {
        guard !AutoFix.terminals.contains(frontApp) else { return }
        switch AutoFix.accessibilitySelection() {
        case .text(let text): replaceSelection(text)
        case .none: return
        case .unknown:  // the app doesn't expose its selection: copy it, then put the clipboard back
            withClipboardSaved { restore in
                let pb = NSPasteboard.general
                let before = pb.changeCount
                self.post(keyCode: 8, flags: .maskCommand)  // ⌘C
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    let text = pb.changeCount != before ? pb.string(forType: .string) : nil
                    restore()
                    // Editors copy the whole line ("...\n") when nothing is selected: never act on that.
                    if let text, !text.hasSuffix("\n") { self.replaceSelection(text) }
                }
            }
        }
    }

    /// Types (or, for several lines, pastes) the other layout's reading of `text` over the selection.
    private func replaceSelection(_ text: String) {
        let units = Array(text.utf16)
        guard !units.isEmpty, units.count <= 2000 else { return }
        var out = [UInt16](repeating: 0, count: units.count)
        var target = InputSource.currentCode() == "TH" ? 0 : 1
        var translated = 0
        for (i, unit) in units.enumerated() {
            let result = lf_convert_unit(UInt32(unit), Int32(target))
            if result >= 0 { out[i] = UInt16(result); translated += 1 } else { out[i] = unit }
        }
        if translated == 0 { return }
        let converted = String(decoding: out, as: UTF16.self)
        withClipboardSaved { restore in
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(converted, forType: .string)
            self.post(keyCode: 9, flags: .maskCommand)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { restore() }
        }
    }

    /// Runs `body` with a snapshot of the clipboard; `body` calls the closure it gets to put the snapshot back.
    private func withClipboardSaved(_ body: (@escaping () -> Void) -> Void) {
        let pb = NSPasteboard.general
        let saved = (pb.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
        body {
            pb.clearContents()
            let items = saved.map { pairs -> NSPasteboardItem in
                let item = NSPasteboardItem()
                for (type, data) in pairs { item.setData(data, forType: type) }
                return item
            }
            if !items.isEmpty { pb.writeObjects(items) }
        }
    }

    // MARK: Personal word list

    /// Should the word (or, mid-word, a word starting like it) be left as typed?
    private func isKept(_ word: Word, prefix: Bool) -> Bool {
        rules.contains { !$0.fix && $0.shown == word.shown && (prefix ? $0.keys.starts(with: word.keys) : $0.keys == word.keys) }
    }

    /// A word the user just flipped with double Shift: back to typed layout means never fix; other means teach fix.
    private func learn(_ word: Word) {
        guard word.keys.count >= 2 else { return }
        var words = Settings.personalWords
        let entry = "\(word.shown):\(word.keys.map { String(format: "%02x", $0) }.joined())"
        words.removeAll { $0.hasPrefix("\(word.shown):") && $0.contains(word.keys.map { String(format: "%02x", $0) }.joined()) }
        words.append(entry)
        Settings.personalWords = Array(words.suffix(500))
    }

    private struct Word {
        var keys: [UInt8] = []
        var shown = 0
        var typed = 0
        var trailing = 0
        var decided = false
    }

    private func convert(_ word: inout Word) {
        guard !word.keys.isEmpty else { return }
        let target = 1 - word.shown
        var keys = word.keys
        if keys.last == 0 { keys.removeLast() }
        let should = lf_should_convert(keys, Int32(keys.count), Int32(word.shown), true)
        guard should else { return }
        let converted = keys.withUnsafeBufferPointer { ptr in
            lf_convert_word(ptr.baseAddress, Int32(ptr.count), Int32(word.shown))
        }
        guard let converted else { return }
        word.keys = keys
        word.shown = target
        word.typed = 1 - target
        _ = lf_convert_word  // force bridge reference
    }

    private func post(keyCode: Int, flags: CGEventFlags) {
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(keyCode), keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(keyCode), keyDown: false) else { return }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}

// MARK: - Shortcuts

/// The presentation tools that have a shortcut of their own.
enum PresentTool: String, CaseIterable {
    case spotlight, zoom, draw
    var title: String {
        switch self {
        case .spotlight: return tr("Spotlight", "สปอตไลต์")
        case .zoom: return tr("Zoom", "ซูม")
        case .draw: return tr("Draw on Screen", "วาดบนจอ")
        }
    }
    var defaultShortcut: Shortcut {
        let key = [PresentTool.spotlight: kVK_ANSI_H, .zoom: kVK_ANSI_Z, .draw: kVK_ANSI_D][self]!
        return Shortcut(keyCode: key, modifiers: controlKey | optionKey)
    }
}

/// A key plus Carbon modifiers (controlKey, optionKey, shiftKey, cmdKey), as RegisterEventHotKey takes them.
struct Shortcut: Equatable {
    var keyCode: Int
    var modifiers: Int

    /// The keys a shortcut can use, by their US position, with the name shown for each.
    private static let names: [Int: String] = {
        var n: [Int: String] = [
            kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D", kVK_ANSI_E: "E", kVK_ANSI_F: "F",
            kVK_ANSI_G: "G", kVK_ANSI_H: "H", kVK_ANSI_I: "I", kVK_ANSI_J: "J", kVK_ANSI_K: "K", kVK_ANSI_L: "L",
            kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O", kVK_ANSI_P: "P", kVK_ANSI_Q: "Q", kVK_ANSI_R: "R",
            kVK_ANSI_S: "S", kVK_ANSI_T: "T", kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X",
            kVK_ANSI_Y: "Y", kVK_ANSI_Z: "Z",
            kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3", kVK_ANSI_4: "4",
            kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7", kVK_ANSI_8: "8", kVK_ANSI_9: "9",
            kVK_ANSI_Equal: "=", kVK_ANSI_Minus: "-", kVK_ANSI_LeftBracket: "[", kVK_ANSI_RightBracket: "]",
            kVK_ANSI_Semicolon: ";", kVK_ANSI_Quote: "'", kVK_ANSI_Comma: ",", kVK_ANSI_Period: ".",
            kVK_ANSI_Slash: "/", kVK_ANSI_Backslash: "\\", kVK_ANSI_Grave: "`",
            kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
            kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        ]
        return n
    }()

    static let reserved = [Shortcut(keyCode: kVK_ANSI_Equal, modifiers: controlKey | optionKey),
                           Shortcut(keyCode: kVK_ANSI_Minus, modifiers: controlKey | optionKey),
                           Shortcut(keyCode: kVK_ANSI_Z, modifiers: cmdKey)]

    init(keyCode: Int, modifiers: Int) { self.keyCode = keyCode; self.modifiers = modifiers }

    init?(event: NSEvent) {
        let f = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !f.isDisjoint(with: [.control, .option, .command]), Shortcut.names[Int(event.keyCode)] != nil else { return nil }
        keyCode = Int(event.keyCode)
        modifiers = (f.contains(.control) ? controlKey : 0) | (f.contains(.option) ? optionKey : 0)
                 | (f.contains(.shift) ? shiftKey : 0) | (f.contains(.command) ? cmdKey : 0)
        guard isValid else { return nil }
    }

    var isValid: Bool {
        let all = controlKey | optionKey | shiftKey | cmdKey
        return Shortcut.names[keyCode] != nil && modifiers & ~all == 0 && modifiers & (controlKey | optionKey | cmdKey) != 0
    }

    var display: String {
        var s = ""
        if modifiers & controlKey != 0 { s += "⌃" }
        if modifiers & optionKey != 0 { s += "⌥" }
        if modifiers & shiftKey != 0 { s += "⇧" }
        if modifiers & cmdKey != 0 { s += "⌘" }
        return s + (Shortcut.names[keyCode] ?? "?")
    }

    var keyEquivalent: String {
        let name = Shortcut.names[keyCode] ?? ""
        return name.count == 1 ? name.lowercased() : ""
    }

    var modifierFlags: NSEvent.ModifierFlags {
        var f: NSEvent.ModifierFlags = []
        if modifiers & controlKey != 0 { f.insert(.control) }
        if modifiers & optionKey != 0 { f.insert(.option) }
        if modifiers & shiftKey != 0 { f.insert(.shift) }
        if modifiers & cmdKey != 0 { f.insert(.command) }
        return f
    }
}

/// A system-wide shortcut through Carbon's hot key API, which needs no permission (unlike watching keys).
final class HotKey {
    private static var nextID: UInt32 = 1
    private let id: UInt32
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void
    /// False when the key couldn't be had, for example because another app holds it.
    private(set) var registered = false

    init(keyCode: Int, modifiers: Int, action: @escaping () -> Void) {
        self.action = action
        id = HotKey.nextID
        HotKey.nextID += 1
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        // Every handler sees every hot key of the app: act only on our own.
        let callback: EventHandlerUPP = { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var pressed = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &pressed)
            let me = Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue()
            guard pressed.id == me.id else { return OSStatus(eventNotHandledErr) }
            me.action()
            return noErr
        }
        InstallEventHandler(GetApplicationEventTarget(), callback, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
        let hotKeyID = EventHotKeyID(signature: OSType(0x434C_4750), id: id)  // "CLGP"
        registered = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hotKeyID, GetApplicationEventTarget(), 0, &ref) == noErr
    }
}

// MARK: - Settings window

/// The badge as it looks next to the pointer, for the Settings window.
final class BadgePreview: NSView {
    private let badge = BadgeView(frame: .zero)
    var code = "EN" { didSet { update() } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        addSubview(badge)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 180).isActive = true
        heightAnchor.constraint(equalToConstant: 128).isActive = true
    }
    required init?(coder: NSCoder) { nil }

    /// Picks up the style, size and colour as they are now.
    func update() {
        badge.code = code
        badge.style = Settings.style
        badge.scale = Settings.size.scale
        badge.needsDisplay = true
        needsLayout = true
        needsDisplay = true
    }

    private var pointer: NSPoint { NSPoint(x: bounds.midX - 30, y: bounds.midY + 18) }

    override func layout() {
        super.layout()
        // The same offset as the real badge (see AppDelegate.follow()).
        let s = badge.scale, size = BadgeView.size(style: badge.style, scale: s, code: code)
        badge.frame = NSRect(x: (pointer.x + 12 * s).rounded(), y: (pointer.y - 22 * s - size.height / 2).rounded(),
                             width: size.width, height: size.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        layer?.borderColor = NSColor.separatorColor.cgColor
        NSGradient(starting: NSColor(srgbRed: 0.33, green: 0.45, blue: 0.62, alpha: 1),
                   ending: NSColor(srgbRed: 0.62, green: 0.50, blue: 0.70, alpha: 1))?.draw(in: bounds, angle: -30)
        let arrow = NSCursor.arrow, image = arrow.image
        image.draw(at: NSPoint(x: pointer.x - arrow.hotSpot.x, y: pointer.y - (image.size.height - arrow.hotSpot.y)),
                   from: .zero, operation: .sourceOver, fraction: 1)
    }
}

/// Settings in four tabs: Badge, Fix Wrong Language, Presentation and General. Every change applies at once.
/// PromptPay, Thailand's bank transfer, for donations: the number, and the QR code that banking apps scan.
enum PromptPay {
    static let number = "0804782843"
    static let display = "080-478-2843"

    /// A static PromptPay QR (EMVCo) for `number` with no amount, so the payer types it in their banking app.
    private static let payload = "00020101021129370016A0000006770101110113006680478284305802TH530376454051.006304"

    static func image(size: CGFloat = 160) -> NSImage? {
        guard let data = payload.data(using: .utf8),
              let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let extent = output.extent.integral
        let scale = size / extent.width
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let rep = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}

/// Settings in four tabs: Badge, Fix Wrong Language, Presentation and General. Every change applies at once.
final class SettingsWindow: NSObject, NSWindowDelegate {
    enum Tab: Int { case badge, fix, presentation, general }

    weak var app: AppDelegate?
    private var window: NSWindow?
    private let tabs = SettingsTabs()
    private var preview = BadgePreview(frame: .zero)
    private var languages: [(code: String, layouts: [String])] = []
    private var wells: [NSColorWell] = []
    private var resets: [NSButton] = []
    private var shortcutFields: [PresentTool: ShortcutField] = [:]
    private var previewCode: String?
    private var reloadPending = false

    func show(_ tab: Tab? = nil) {
        if window == nil { makeWindow() }
        build()
        if let tab { tabs.selectedTabViewItemIndex = tab.rawValue }
        tabs.fitWindow()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// After a change made somewhere else (the menu, a shortcut): shows it, if the window is open.
    func reload() {
        guard window?.isVisible == true, !reloadPending else { return }
        reloadPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.reloadPending = false
            self.build()
        }
    }

    /// The keyboard language changed: the preview follows it, unless a language was picked in the list.
    func inputChanged() {
        if previewCode == nil { preview.code = InputSource.currentCode() }
    }

    private func makeWindow() {
        tabs.tabStyle = .toolbar
        let symbols = ["character.cursor.ibeam", "keyboard", "cursorarrow.rays", "gearshape"]
        for symbol in symbols {
            let page = NSViewController()
            page.view = NSView()
            let item = NSTabViewItem(viewController: page)
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            tabs.addTabViewItem(item)
        }
        let w = NSWindow(contentViewController: tabs)
        w.styleMask = [.titled, .closable]
        w.level = .floating
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.center()
        window = w
    }

    /// Fills every tab in the menu's current language, keeping the selected one.
    private func build() {
        window?.makeFirstResponder(nil)
        let titles = [tr("Badge", "ป้ายภาษา"), tr("Fix Wrong Language", "แก้คำผิดภาษา"), tr("Presentation", "นำเสนอ"),
                      tr("General", "ทั่วไป")]
        let views = [badgeTab(), fixTab(), presentationTab(), generalTab()]
        for (i, item) in tabs.tabViewItems.enumerated() {
            item.label = titles[i]
            item.viewController?.title = titles[i]
            guard let page = item.viewController?.view else { continue }
            page.subviews = [views[i]]
            views[i].translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                views[i].topAnchor.constraint(equalTo: page.topAnchor),
                views[i].leadingAnchor.constraint(equalTo: page.leadingAnchor),
            ])
        }
        window?.title = tabs.tabViewItems[tabs.selectedTabViewItemIndex].label
        tabs.fitWindow()
    }

    // MARK: Tabs

    private func badgeTab() -> NSView {
        languages = InputSource.installedLanguages()
        let current = InputSource.currentCode()
        if !languages.contains(where: { $0.code == current }) { languages.insert((current, []), at: 0) }
        if let previewCode, !languages.contains(where: { $0.code == previewCode }) { self.previewCode = nil }
        preview.code = previewCode ?? current
        preview.update()

        let looks = NSGridView(views: [
            [label(tr("Show:", "แสดง:")), popup(DisplayMode.allCases.map { ($0.rawValue, $0.title) }, Settings.mode.rawValue,
                                               #selector(AppDelegate.pickMode))],
            [label(tr("Style:", "รูปแบบ:")), popup(BadgeStyle.allCases.map { ($0.rawValue, $0.title) }, Settings.style.rawValue,
                                                 #selector(AppDelegate.pickStyle))],
            [label(tr("Size:", "ขนาด:")), popup(BadgeSize.allCases.map { ($0.rawValue, $0.title) }, Settings.size.rawValue,
                                               #selector(AppDelegate.pickSize))],
            [label(tr("Border:", "เส้นขอบ:")), toggle(Settings.badgeBorder, #selector(toggleBorder(_:)))],
        ])
        looks.rowSpacing = 8
        looks.column(at: 0).xPlacement = .trailing
        looks.rowAlignment = .firstBaseline
        looks.setContentHuggingPriority(.required, for: .vertical)
        let top = NSStackView(views: [preview, looks])
        top.spacing = 20
        top.alignment = .top

        wells = []
        resets = []
        let rows: [[NSView]] = languages.enumerated().map { i, lang in
            let name = NSMutableAttributedString(string: lang.code, attributes: [.font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)])
            if !lang.layouts.isEmpty {
                name.append(NSAttributedString(string: "   " + lang.layouts.joined(separator: ", "),
                                               attributes: [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
                                                            .foregroundColor: NSColor.secondaryLabelColor]))
            }
            let title = NSTextField(labelWithAttributedString: name)
            title.widthAnchor.constraint(greaterThanOrEqualToConstant: 150).isActive = true
            let show = toggle(!Settings.hidden.contains(lang.code), #selector(toggleLanguage(_:)))
            show.tag = i
            let well = NSColorWell()
            well.color = Palette.color(for: lang.code)
            well.target = self
            well.action = #selector(colorChanged(_:))
            well.tag = i
            well.widthAnchor.constraint(equalToConstant: 44).isActive = true
            well.heightAnchor.constraint(equalToConstant: 24).isActive = true
            wells.append(well)
            let reset = NSButton(title: tr("Default", "สีเดิม"), target: self, action: #selector(resetColor(_:)))
            reset.tag = i
            reset.controlSize = .small
            reset.isEnabled = Palette.hasCustomColor(for: lang.code)
            resets.append(reset)
            return [title, well, reset, show]
        }
        let column = { (text: String) -> NSTextField in
            let l = NSTextField(labelWithString: text)
            l.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            l.textColor = .secondaryLabelColor
            l.setContentCompressionResistancePriority(.required, for: .horizontal)
            return l
        }
        let list = NSGridView(views: [[column(tr("Keyboard", "แป้นพิมพ์")), column(tr("Color", "สี")), NSGridCell.emptyContentView,
                                       column(tr("Show badge", "แสดงป้าย"))]] + rows)
        list.column(at: 3).xPlacement = .center
        list.row(at: 0).bottomPadding = -2
        list.rowSpacing = 8
        list.columnSpacing = 12
        list.rowAlignment = .none
        for r in 0..<list.numberOfRows { list.row(at: r).yPlacement = .center }

        let heading = NSStackView(views: [header(tr("Languages", "ภาษา")),
                                          caption(tr("The keyboards added in System Settings → Keyboard → Input Sources.",
                                                     "แป้นพิมพ์ที่เพิ่มไว้ใน System Settings → Keyboard → Input Sources"))])
        heading.orientation = .vertical
        heading.alignment = .leading
        heading.spacing = 2
        return tab([top, heading, list])
    }

    private func fixTab() -> NSView {
        guard let app else { return NSView() }
        let mode = Settings.fixMode
        let modes: [(FixMode, String)] = [
            (.off, tr("Nothing is fixed, and CursorLingo doesn't look at your typing at all.", "ไม่แก้อะไรให้ และไม่ดูสิ่งที่คุณพิมพ์เลย")),
            (.manual, tr("Tap Shift twice to switch the last word (or the selected text) to the other language.",
                         "พิมพ์ผิดภาษาเมื่อไหร่ กด Shift 2 ครั้งติดกัน คำล่าสุด (หรือข้อความที่เลือกไว้) จะเปลี่ยนเป็นอีกภาษาให้")),
            (.automatic, tr("Words typed in the wrong language are fixed as you type. If a fix is wrong, double Shift puts it back.",
                            "แก้คำที่พิมพ์ผิดภาษาให้เองระหว่างพิมพ์ ถ้าแก้ไม่ตรงใจ กด Shift 2 ครั้งเพื่อย้อนคืน")),
        ]
        var views: [NSView] = [header(tr("Fix Wrong Language (EN ⇄ TH)", "แก้คำที่พิมพ์ผิดภาษา (EN ⇄ TH)"))]
        for (i, (mode, detail)) in modes.enumerated() {
            let radio = NSButton(radioButtonWithTitle: mode.title, target: self, action: #selector(fixModeChanged(_:)))
            radio.tag = i
            radio.state = mode == Settings.fixMode ? .on : .off
            let detailText = caption(detail)
            detailText.preferredMaxLayoutWidth = 450
            let item = NSStackView(views: [radio, indented(detailText)])
            item.orientation = .vertical
            item.alignment = .leading
            item.spacing = 2
            views.append(item)
        }
        views.append(separator())
        views.append(optionRow(tr("Enable Thai Digit Conversion (0-9 ↔ ๐-๙)", "เปิดใช้งานการแปลงเลขไทย ↔ อารบิก (0-9 ↔ ๐-๙)"),
                               tr("Select text and use ⌃⌥R to convert digits.", "เลือกข้อความแล้วกด ⌃⌥R เพื่อแปลงตัวเลข"),
                               toggle(Settings.enableThaiDigitConversion, #selector(digitConversionChanged(_:)))))
        if mode != .off {
            let status = app.autoFix.status
            let dot = NSTextField(labelWithString: "●")
            dot.textColor = status.problem == nil ? .systemGreen : .systemOrange
            var parts: [NSView] = [dot, label(status.text)]
            if status.problem == .permission {
                parts.append(button(tr("Open Privacy Settings…", "เปิด Privacy & Security…"), #selector(AppDelegate.openPrivacySettings), app))
            }
            if status.problem == .notRunning {
                parts.append(button(tr("Relaunch CursorLingo", "เปิด CursorLingo ใหม่"), #selector(AppDelegate.relaunch), app))
            }
            views.append(line(parts))
        }
        let editors = toggle(Settings.codeEditorsManual, #selector(codeEditorsChanged(_:)))
        editors.isEnabled = mode == .automatic
        views.append(optionRow(tr("Code editors: fix only on double Shift", "โปรแกรมเขียนโค้ด: แก้เฉพาะตอนกด Shift 2 ครั้ง"),
                               tr("Names in code often look like wrong-language words, so these apps aren't fixed automatically: "
                                  + AutoFix.codeEditorNames + ". Terminals (" + AutoFix.terminalNames + ") never are, whatever this is set to. "
                                  + "Both lists come with CursorLingo; ask for more on GitHub.",
                                  "ชื่อตัวแปรในโค้ดหน้าตาคล้ายคำพิมพ์ผิดภาษาบ่อยๆ เลยไม่แก้เองในแอปพวกนี้: " + AutoFix.codeEditorNames
                                  + " ส่วน Terminal (" + AutoFix.terminalNames + ") ไม่แก้เองเลย ไม่ว่าจะตั้งตรงนี้ไว้ยังไง "
                                  + "รายชื่อแอปมีมากับ CursorLingo อยากให้เพิ่มแอปไหน บอกได้ที่ GitHub"),
                               editors))
        let learned = app.autoFix.rules.count
        let forget = button(tr("Forget", "ล้าง"), #selector(AppDelegate.forgetLearned), app)
        forget.isEnabled = learned > 0
        views.append(optionRow(learned == 0 ? tr("Learned words: none yet", "คำที่จำไว้: ยังไม่มี")
                                            : tr("Learned words: \(learned)", "คำที่จำไว้: \(learned) คำ"),
                               tr("When you convert or undo a word with double Shift, CursorLingo remembers it and does the same next time. Kept on this Mac only.",
                                  "คำไหนที่คุณกด Shift 2 ครั้งเพื่อแปลงหรือย้อนคืน จะถูกจำไว้ แล้วครั้งหน้าทำแบบเดียวกันให้เอง เก็บไว้ในเครื่องนี้เท่านั้น"),
                               forget))
        views.append(separator())
        views.append(optionRow(tr("Remember language per app", "จำภาษาของแต่ละแอป"),
                               tr("Going back to an app switches to the keyboard you last used there. Works even with fixing off.",
                                  "กลับไปแอปไหน ก็สลับเป็นภาษาที่ใช้ล่าสุดในแอปนั้นให้เอง ใช้ได้แม้จะปิดการแก้คำไว้"),
                               toggle(Settings.perAppLanguage, #selector(perAppChanged(_:)))))
        return tab(views)
    }

    private func presentationTab() -> NSView {
        guard let app else { return NSView() }
        let tools: [(PresentTool, Bool, Selector, String)] = [
            (.spotlight, app.presenter.spotlight, #selector(spotlightChanged(_:)),
             tr("Dims the screen except for a circle around the pointer. You can still click and type as usual.",
                "หรี่จอ เหลือวงกลมใสรอบเมาส์ ยังคลิกและพิมพ์ได้ตามปกติ")),
            (.zoom, app.presenter.zoom, #selector(zoomToolChanged(_:)),
             tr("Magnifies what is under the pointer, inside the circle. Needs Screen Recording permission.",
                "ขยายจุดที่เมาส์ชี้ให้ใหญ่ขึ้นในวงกลม (ต้องอนุญาต Screen Recording ก่อน)")),
            (.draw, app.presenter.drawing, #selector(drawChanged(_:)),
             tr("Draw over the screen with the mouse. While it's on, clicks draw instead of reaching apps; Esc stops.",
                "ลากเมาส์ขีดเขียนบนจอได้เลย ระหว่างนี้คลิกจะเป็นการวาด ไม่โดนแอปข้างใต้ กด Esc เพื่อเลิกวาด")),
        ]
        shortcutFields = [:]
        let heading = NSStackView(views: [header(tr("Tools", "เครื่องมือ")),
                                          caption(tr("To change a shortcut, click it and press the new keys (⌃, ⌥ or ⌘ with a letter, "
                                                     + "number or F-key). Delete clears it.",
                                                     "อยากเปลี่ยนคีย์ลัด คลิกที่ช่องแล้วกดคีย์ใหม่ (⌃ ⌥ หรือ ⌘ คู่กับตัวอักษร ตัวเลข หรือปุ่ม F) "
                                                     + "ถ้าไม่อยากใช้คีย์ลัด กด Delete"))])
        heading.orientation = .vertical
        heading.alignment = .leading
        heading.spacing = 2
        var views: [NSView] = [heading]
        for (tool, on, action, detail) in tools {
            let field = ShortcutField()
            field.shortcut = Settings.shortcut(tool)
            field.onRecord = { [weak self] shortcut in self?.setShortcut(tool, shortcut) }
            field.onListening = { [weak app] listening in app?.pauseShortcuts(listening) }
            field.widthAnchor.constraint(equalToConstant: 104).isActive = true
            field.toolTip = tr("Click, then press the new keys. Delete clears it.", "คลิกแล้วกดคีย์ใหม่ กด Delete เพื่อล้าง")
            shortcutFields[tool] = field
            let onOff = toggle(on, action)
            if tool == .zoom { onOff.isEnabled = Presenter.zoomAvailable }
            let controls = NSStackView(views: [field, onOff])
            controls.spacing = 14
            let name = label(tool.title)
            let heading = NSStackView(views: [name, controls])
            heading.spacing = 18
            heading.alignment = .centerY
            let detailText = caption(detail)
            detailText.preferredMaxLayoutWidth = 450
            views.append(NSStackView(views: [heading, indented(detailText)]))
        }
        views.append(separator())
        views.append(optionRow(tr("Circle size", "ขนาดวงกลม"),
                               tr("Control–Option + scroll also changes this while a tool is on.", "กด Control–Option แล้วเลื่อนล้อเมาส์เพื่อปรับขนาดได้ด้วย"),
                               slider(40, 300, Double(app.presenter.radius), #selector(spotlightSizeChanged(_:)))))
        views.append(optionRow(tr("Zoom", "ระดับซูม"),
                               tr("Control–Option + = / − changes the magnification while zoom is on.", "กด Control–Option + = / − เพื่อปรับระดับซูม"),
                               slider(1.5, 8, Double(app.presenter.zoomLevel), #selector(zoomLevelChanged(_:)))))
        views.append(caption(tr("⌘Z undoes the last stroke. Esc stops drawing, then turns off all the tools.",
                                "กด ⌘Z เพื่อลบเส้นล่าสุด กด Esc เพื่อเลิกวาด แล้วกดอีกครั้งเพื่อปิดเครื่องมือทั้งหมด")))
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        return stack
    }

    private func generalTab() -> NSView {
        guard let app else { return NSView() }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let language = popup(UILanguage.allCases.map { ($0.rawValue, $0.title) }, Settings.uiLanguage.rawValue,
                             #selector(AppDelegate.pickUILanguage))

        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.widthAnchor.constraint(equalToConstant: 48).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 48).isActive = true
        let name = NSTextField(labelWithString: "CursorLingo")
        name.font = .systemFont(ofSize: 15, weight: .semibold)
        let about = NSStackView(views: [name, caption(tr("Version \(version) · Free and open source · No network access, no tracking",
                                                          "เวอร์ชัน \(version) · ฟรีและโอเพนซอร์ส · ไม่ต่อเน็ต ไม่เก็บข้อมูลการใช้งาน"))])
        about.orientation = .vertical
        about.alignment = .leading
        about.spacing = 2
        let top = NSStackView(views: [icon, about])
        top.spacing = 12

        let pitch = caption(tr("CursorLingo is a free, spare-time project. If it saves you some retyping, a star on GitHub, a "
                               + "share with friends or a coffee means a lot. Got an idea, a word it got wrong, or some code? "
                               + "Come say hi.",
                               "CursorLingo ทำในเวลาว่าง และแจกให้ใช้ฟรี ถ้ามันช่วยให้ไม่ต้องลบแล้วพิมพ์ใหม่บ่อยๆ "
                               + "ฝากกดดาวบน GitHub แชร์ให้เพื่อนๆ หรือเลี้ยงกาแฟสักแก้วก็ได้นะ "
                               + "มีไอเดีย เจอคำที่แก้ผิด หรืออยากช่วยเขียนโค้ด ทักมาได้เลย"))
        let support = NSStackView(views: [
            header(tr("Support CursorLingo", "สนับสนุน CursorLingo")),
            pitch,
            line(NSButton(title: tr("★ Star on GitHub", "★ ให้ดาวบน GitHub"), target: self, action: #selector(openRepo)),
                 NSButton(title: tr("How to Contribute", "วิธีร่วมพัฒนา"), target: self, action: #selector(openContributing)),
                 NSButton(title: tr("☕ Buy a Coffee on Ko-fi", "☕ เลี้ยงกาแฟผ่าน Ko-fi"), target: self, action: #selector(openKofi))),
            promptPayBox(),
        ])
        support.orientation = .vertical
        support.alignment = .leading
        support.spacing = 8

        return tab([
            top,
            separator(),
            optionRow(tr("Open at login", "เปิด CursorLingo อัตโนมัติ"),
                      tr("Starts by itself when you log in to your Mac, so the badge is always there.",
                         "เปิดเครื่องหรือล็อกอินเมื่อไหร่ CursorLingo ก็ทำงานเลย ไม่ต้องคอยเปิดเอง"),
                      toggle(LoginItem.isEnabled, #selector(loginChanged(_:)))),
            optionRow("Language / ภาษา", tr("The language of the menu and this window.", "ภาษาที่ใช้ในเมนูและหน้าต่างนี้"), language),
            optionRow(tr("Found a wrong fix or a bug?", "เจอคำที่แก้ผิด หรือเจอบั๊ก?"),
                      tr("Opens the report form on GitHub in your browser. Nothing you typed is attached.",
                         "จะเปิดหน้าแจ้งปัญหาบน GitHub ในเบราว์เซอร์ ไม่มีอะไรที่คุณพิมพ์ติดไปด้วย"),
                      button(tr("Report…", "แจ้งปัญหา…"), #selector(AppDelegate.reportIssue), app)),
            separator(),
            support,
        ])
    }

    // MARK: Actions

    @objc private func fixModeChanged(_ sender: NSButton) {
        let item = NSMenuItem()
        item.representedObject = [FixMode.off, .manual, .automatic][sender.tag].rawValue
        app?.pickFixMode(item)
        reload()
    }

    @objc private func loginChanged(_ sender: NSSwitch) {
        if (sender.state == .on) != LoginItem.isEnabled { app?.toggleLogin() }
    }

    @objc private func openRepo() {
        if let url = URL(string: "https://github.com/kittipongint/cursor-lingo") { NSWorkspace.shared.open(url) }
    }

    @objc private func openKofi() {
        if let url = URL(string: "https://ko-fi.com/kintstudio") { NSWorkspace.shared.open(url) }
    }

    @objc private func copyPromptPay(_ sender: NSButton) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(PromptPay.number, forType: .string)
        sender.title = tr("Copied ✓", "คัดลอกแล้ว ✓")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { sender.title = tr("Copy Number", "คัดลอกเลข") }
    }

    @objc private func openContributing() {
        if let url = URL(string: "https://github.com/kittipongint/cursor-lingo/blob/main/CONTRIBUTING.md") { NSWorkspace.shared.open(url) }
    }

    @objc private func spotlightChanged(_ sender: NSSwitch) {
        if (sender.state == .on) != app?.presenter.spotlight { app?.toggleSpotlight() }
    }

    @objc private func zoomToolChanged(_ sender: NSSwitch) {
        if (sender.state == .on) != app?.presenter.zoom { app?.toggleZoom() }
        reload()
    }

    @objc private func drawChanged(_ sender: NSSwitch) {
        if (sender.state == .on) != app?.presenter.drawing { app?.toggleDrawing() }
    }

    @objc private func digitConversionChanged(_ sender: NSSwitch) {
        Settings.enableThaiDigitConversion = sender.state == .on
        reload()
    }

    @objc private func codeEditorsChanged(_ sender: NSSwitch) {
        if (sender.state == .on) != Settings.codeEditorsManual { app?.toggleCodeEditorsManual() }
    }

    @objc private func perAppChanged(_ sender: NSSwitch) {
        if (sender.state == .on) != Settings.perAppLanguage { app?.togglePerAppLanguage() }
    }

    @objc private func toggleBorder(_ sender: NSControl) {
        Settings.badgeBorder = (sender as? NSSwitch)?.state == .on
        preview.update()
        app?.refresh(animated: false)
    }

    @objc private func toggleLanguage(_ sender: NSSwitch) {
        let code = languages[sender.tag].code
        var hidden = Settings.hidden
        if sender.state == .on { hidden.remove(code) } else { hidden.insert(code) }
        Settings.hidden = hidden
        previewCode = code
        preview.code = code
        app?.refresh(animated: true)
    }

    @objc private func colorChanged(_ sender: NSColorWell) {
        let code = languages[sender.tag].code
        Palette.setColor(sender.color, for: code)
        resets[sender.tag].isEnabled = Palette.hasCustomColor(for: code)
        previewCode = code
        preview.code = code
        app?.refresh(animated: true)
    }

    @objc private func resetColor(_ sender: NSButton) {
        let code = languages[sender.tag].code
        Palette.setColor(nil, for: code)
        wells[sender.tag].color = Palette.color(for: code)
        sender.isEnabled = false
        previewCode = code
        preview.code = code
        app?.refresh(animated: true)
    }

    @objc private func colorChanged(_ sender: NSColorWell) { }

    @objc private func showShortcuts() { }

    @objc private func showSettings() { settingsWindow.show() }

    @objc private func toggleSpotlight() { presenter.setSpotlight(!presenter.spotlight) }
    @objc private func toggleZoom() { presenter.setZoom(!presenter.zoom) }
    @objc private func toggleDrawing() { presenter.setDrawing(!presenter.drawing) }
    @objc private func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Menu

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "character.cursor.ibeam", accessibilityDescription: "CursorLingo")
            button.imagePosition = .imageLeading
            button.font = .monospacedSystemFont(ofSize: 11, weight: .semibold)
        }
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    /// The menu is rebuilt lazily each time it opens, so nothing menu-related lives in memory between uses.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let code = InputSource.currentCode()

        let header = NSMenuItem(title: tr("Current input: \(code)", "ภาษาที่ใช้อยู่: \(code)"), action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        menu.addItem(.separator())
        menu.addItem(presentationMenu())
        menu.addItem(item(tr("Convert Thai ↔ Arabic Digits", "แปลงเลขไทย ↔ อารบิก"), #selector(convertSelectedDigits)))
        menu.addItem(submenu(tr("Fix Wrong Language (EN ⇄ TH): ", "แก้คำที่พิมพ์ผิดภาษา (EN ⇄ TH): ") + Settings.fixMode.title,
                             FixMode.allCases.map { ($0.rawValue, $0.title) }, selected: Settings.fixMode.rawValue,
                             #selector(pickFixMode)))
        if Settings.fixMode != .off {
            let status = autoFix.status
            let line = NSMenuItem(title: "    " + status.text, action: nil, keyEquivalent: "")
            line.isEnabled = false
            menu.addItem(line)
            if status.problem == .permission {
                menu.addItem(item("    " + tr("Open Privacy Settings…", "เปิด Privacy & Security…"), #selector(openPrivacySettings)))
            }
            if status.problem == .notRunning {
                menu.addItem(item("    " + tr("Relaunch CursorLingo", "เปิด CursorLingo ใหม่"), #selector(relaunch)))
            }
        }
        menu.addItem(.separator())
        menu.addItem(item(tr("Settings…", "ตั้งค่า…"), #selector(showSettings), key: ","))
        menu.addItem(item(tr("Quit CursorLingo", "ปิด CursorLingo"), #selector(quit), key: "q"))
    }

    private func item(_ title: String, _ action: Selector, on: Bool = false, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        item.state = on ? .on : .off
        return item
    }

    /// `options` are (stored value, title shown) pairs.
    private func submenu(_ title: String, _ options: [(String, String)], selected: String, _ action: Selector) -> NSMenuItem {
        let sub = NSMenu()
        for (value, label) in options {
            let item = item(label, action, on: value == selected)
            item.representedObject = value
            sub.addItem(item)
        }
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        parent.submenu = sub
        return parent
    }

    @objc private func convertSelectedDigits() { autoFix.convertDigitsInSelection() }

    @objc func pickUILanguage(_ sender: NSMenuItem) {
        Settings.uiLanguage = UILanguage(rawValue: sender.representedObject as? String ?? "") ?? .system
    }

    @objc func pickMode(_ sender: NSMenuItem) {
        Settings.mode = DisplayMode(rawValue: sender.representedObject as? String ?? "") ?? .always
        refresh(animated: Settings.mode == .onSwitch)
    }

    @objc func pickStyle(_ sender: NSMenuItem) {
        Settings.style = BadgeStyle(rawValue: sender.representedObject as? String ?? "") ?? .color
        refresh(animated: true)
    }

    @objc func pickSize(_ sender: NSMenuItem) {
        Settings.size = BadgeSize(rawValue: sender.representedObject as? String ?? "") ?? .medium
        refresh(animated: true)
    }

    @objc func pickFixMode(_ sender: NSMenuItem) {
        let mode = FixMode(rawValue: sender.representedObject as? String ?? "") ?? .off
        guard mode != .off else {
            Settings.autoFix = false
            autoFixRetry?.invalidate()
            autoFix.stop()
            return
        }
        Settings.fixAsYouType = mode == .automatic
        autoFix.fixAsYouType = Settings.fixAsYouType
        if !Settings.autoFix { enableAutoFix() }
    }

    private func enableAutoFix() {
        Settings.autoFix = true
        startAutoFix()
        if autoFix.isRunning { return }
        autoFixRetry?.invalidate()
        autoFixRetry = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
            guard let self, Settings.autoFix else { timer.invalidate(); return }
            if self.autoFix.start() { timer.invalidate(); self.autoFixRetry = nil }
        }
    }

    private func startAutoFix() {
        guard Settings.autoFix, !autoFix.start() else { return }
        autoFixRetry?.invalidate()
        autoFixRetry = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
            guard let self, Settings.autoFix else { timer.invalidate(); return }
            if self.autoFix.start() { timer.invalidate(); self.autoFixRetry = nil }
        }
    }

    @objc private func openPrivacySettings() {
        let pane = CGPreflightListenEventAccess() ? "Privacy_Accessibility" : "Privacy_ListenEvent"
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc func relaunch() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
        try? process.run()
        NSApp.terminate(nil)
    }

    @objc func toggleCodeEditorsManual() {
        Settings.codeEditorsManual.toggle()
        autoFix.codeEditorsManual = Settings.codeEditorsManual
    }

    @objc func forgetLearned() { autoFix.forgetRules() }

    /// The tools' shortcuts (⌃⌥H, ⌃⌥Z, ⌃⌥D unless changed) work from anywhere. Returns the tools whose shortcut
    /// another app already has.
    @discardableResult
    func registerShortcuts() -> [PresentTool] {
        presentationKeys = []
        var failed: [PresentTool] = []
        for tool in PresentTool.allCases {
            guard let shortcut = Settings.shortcut(tool) else { continue }
            let key = HotKey(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers) { [weak self] in self?.toggle(tool) }
            if key.registered { presentationKeys.append(key) } else { failed.append(tool) }
        }
        let digitKey = HotKey(keyCode: kVK_ANSI_R, modifiers: controlKey | optionKey) { [weak self] in
            self?.autoFix.convertDigitsInSelection()
        }
        if digitKey.registered { presentationKeys.append(digitKey) }
        return failed
    }

    private func toggle(_ tool: PresentTool) {
        switch tool {
        case .spotlight: toggleSpotlight()
        case .zoom: toggleZoom()
        case .draw: toggleDrawing()
        }
    }

    /// While a shortcut box in Settings listens, the keys must reach it instead of toggling a tool.
    func pauseShortcuts(_ paused: Bool) {
        if paused { presentationKeys = [] } else { registerShortcuts() }
    }

    @objc private func showShortcuts() { settingsWindow.show(.presentation) }
    @objc private func showSettings() { settingsWindow.show() }
    @objc func toggleSpotlight() { presenter.setSpotlight(!presenter.spotlight) }
    @objc func toggleZoom() { presenter.setZoom(!presenter.zoom) }
    @objc func toggleDrawing() { presenter.setDrawing(!presenter.drawing) }
    @objc func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}
