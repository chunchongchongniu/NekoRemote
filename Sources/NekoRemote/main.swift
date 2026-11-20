import Cocoa

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let hotkeys = CarbonHotkeys()
    private let tap = HotkeyTap()
    private let optionMonitor = TabMonitor()
    private var enabledItem: NSMenuItem!
    private var gateItem: NSMenuItem!
    private var seekLabel: NSMenuItem!
    private var settings: Settings = .load()

    // MARK: lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        Logger.log("didFinishLaunching")
        NSApp.setActivationPolicy(.accessory)   // menu-bar only
        buildMenu()
        wireHotkeys()
        hotkeys.start()
        optionMonitor.start()
        if HotkeyTap.canCreateTap() {
            Logger.log("accessibility + input monitoring granted, starting tap")
            tap.start()
        } else {
            Logger.log("tap skipped: missing Accessibility/Input Monitoring; Carbon hotkeys only")
            requestPermissionsIfNeeded()
        }
    }

    private func requestPermissionsIfNeeded() {
        let opts: NSDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        if !AXIsProcessTrustedWithOptions(opts) {
            NSLog("NekoRemote: waiting for Accessibility permission")
        }
    }

    // MARK: menu

    private func buildMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "🐾"

        let menu = NSMenu()

        enabledItem = NSMenuItem(title: "启用遥控", action: #selector(toggleEnabled), keyEquivalent: "")
        enabledItem.state = settings.enabled ? .on : .off
        menu.addItem(enabledItem)

        gateItem = NSMenuItem(title: "仅在游戏窗口时生效", action: #selector(toggleGate), keyEquivalent: "")
        gateItem.state = settings.onlyInGame ? .on : .off
        menu.addItem(gateItem)

        menu.addItem(.separator())

        let legend = NSMenuItem(title: "Tab 暂停/继续 · ← → 跳转", action: nil, keyEquivalent: "")
        legend.isEnabled = false
        menu.addItem(legend)
        menu.addItem(.separator())

        seekLabel = NSMenuItem(title: "步进：\(Int(settings.seekSeconds)) 秒", action: nil, keyEquivalent: "")
        seekLabel.isEnabled = false
        menu.addItem(seekLabel)
        for s in [3.0, 5.0, 10.0, 15.0, 30.0] {
            let it = NSMenuItem(title: "  \(Int(s)) 秒", action: #selector(pickSeek(_:)), keyEquivalent: "")
            it.tag = Int(s)
            it.state = Int(settings.seekSeconds) == Int(s) ? .on : .off
            menu.addItem(it)
        }

        menu.addItem(.separator())

        let gameItem = NSMenuItem(title: "游戏窗口关键词（逗号分隔）…", action: #selector(editGameName), keyEquivalent: "g")
        menu.addItem(gameItem)

        let testItem = NSMenuItem(title: "测试：暂停/继续视频", action: #selector(testToggle), keyEquivalent: "t")
        menu.addItem(testItem)

        menu.addItem(.separator())

        menu.addItem(NSMenuItem(title: "打开辅助功能设置", action: #selector(openAccessibility), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q"))

        statusItem.menu = menu
    }

    // MARK: hotkeys

    private func wireHotkeys() {
        tap.shouldHandle = { [weak self] in
            guard let self else { return false }
            guard self.settings.enabled else { return false }
            guard self.settings.onlyInGame else { return true }
            // Allow when the game is front, OR when a browser playing bilibili is front.
            if self.isGameFrontmost() { return true }
            if BrowserVideoController.activeVideoBrowser() != nil { return true }
            if BrowserVideoController.cachedVideoBrowser() != nil { return true }
            if BrowserVideoController.anyBrowserHasVideo() { return true }
            return false
        }

        let toggleHandler: () -> Void = { [weak self] in
            guard let self else { return }
            guard let browser = self.currentBrowser() else { return }
            Logger.log("tab -> toggle")
            if let paused = BrowserVideoController.togglePlayback(browser) {
                self.flash(paused ? "PAUSE" : "PLAY")
            }
        }
        let backHandler: () -> Void = { [weak self] in
            guard let self, let b = self.currentBrowser() else { return }
            _ = BrowserVideoController.seek(b, seconds: -self.settings.seekSeconds)
            self.flash("<<")
        }
        let fwdHandler: () -> Void = { [weak self] in
            guard let self, let b = self.currentBrowser() else { return }
            _ = BrowserVideoController.seek(b, seconds: self.settings.seekSeconds)
            self.flash(">>")
        }

        tap.onToggle = toggleHandler
        tap.onSeekBackward = backHandler
        tap.onSeekForward = fwdHandler
        hotkeys.onToggle = toggleHandler
        hotkeys.onSeekBackward = backHandler
        hotkeys.onSeekForward = fwdHandler
        hotkeys.shouldHandle = tap.shouldHandle
        optionMonitor.onToggle = toggleHandler
        optionMonitor.shouldHandle = tap.shouldHandle
    }

    /// The browser we control: the frontmost one, or Safari/Chrome if the game is in front.
    private func currentBrowser() -> BrowserKind? {
        let frontName = NSWorkspace.shared.frontmostApplication?.localizedName ?? "nil"
        Logger.log("resolving browser, frontmost=\(frontName)"); NSLog("NekoRemote: resolving browser, frontmost=\(frontName)")
        if let front = BrowserVideoController.activeVideoBrowser() { return front }
        if NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Safari").first != nil { return .safari }
        return nil
    }

    private func isGameFrontmost() -> Bool {
        guard let front = NSWorkspace.shared.frontmostApplication else { return false }
        let name = front.localizedName ?? ""
        let bundle = front.bundleIdentifier ?? ""
        let nameLower = name.lowercased()
        let bundleLower = bundle.lowercased()
        return settings.gameKeywords.contains { kw in
            let n = kw.lowercased()
            guard !n.isEmpty else { return false }
            return nameLower.contains(n) || bundleLower.contains(n)
        }
    }

    // MARK: actions

    @objc private func toggleEnabled() {
        settings.enabled.toggle()
        settings.save()
        enabledItem.state = settings.enabled ? .on : .off
    }

    @objc private func toggleGate() {
        settings.onlyInGame.toggle()
        settings.save()
        gateItem.state = settings.onlyInGame ? .on : .off
    }

    @objc private func pickSeek(_ sender: NSMenuItem) {
        settings.seekSeconds = Double(sender.tag)
        settings.save()
        seekLabel.title = "步进：\(sender.tag) 秒"
        for item in statusItem.menu?.items ?? [] where item.action == #selector(pickSeek(_:)) {
            item.state = item.tag == sender.tag ? .on : .off
        }
    }

    @objc private func editGameName() {
        let alert = NSAlert()
        alert.messageText = "游戏窗口关键词"
        alert.informativeText = "多个名字用逗号分隔。任一个出现在前台 App 名称里时才响应按键。"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = settings.gameKeywords.joined(separator: ", ")
        alert.accessoryView = field
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            settings.gameKeywords = field.stringValue
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            settings.save()
        }
    }

    @objc private func testToggle() {
        guard let browser = BrowserVideoController.activeVideoBrowser() else {
            flash("无浏览器")
            return
        }
        let out = BrowserVideoController.runJS("document.title", in: browser) ?? "无响应"
        NSLog("NekoRemote test: title=\(out)")
        if let paused = BrowserVideoController.togglePlayback(browser) {
            flash(paused ? "⏸" : "▶︎")
        } else {
            flash("失败")
        }
    }

    @objc private func openAccessibility() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    @objc private func quit() { NSApp.terminate(nil) }

    private func flash(_ text: String) {
        statusItem.button?.title = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.statusItem.button?.title = "🐾"
        }
    }
}

// MARK: - Settings

struct Settings {
    var enabled = true
    var onlyInGame = true
    var seekSeconds = 5.0
    var gameKeywords: [String] = ["原神", "Yuanshen", "hkrpg", "星穹铁道", "崩坏"]

    private static let key = "NekoRemoteSettings"

    static func load() -> Settings {
        var s = Settings()
        guard let d = UserDefaults.standard.dictionary(forKey: key) else { return s }
        if let v = d["enabled"] as? Bool { s.enabled = v }
        if let v = d["onlyInGame"] as? Bool { s.onlyInGame = v }
        if let v = d["seekSeconds"] as? Double { s.seekSeconds = v }
        if let v = d["gameKeywords"] as? [String] { s.gameKeywords = v }
        else if let v = d["gameKeyword"] as? String { s.gameKeywords = [v] }
        return s
    }

    func save() {
        UserDefaults.standard.set([
            "enabled": enabled,
            "onlyInGame": onlyInGame,
            "seekSeconds": seekSeconds,
            "gameKeywords": gameKeywords
        ], forKey: Settings.key)
    }
}



enum Logger {
    static let path = NSHomeDirectory() + "/Library/Logs/NekoRemote.log"
    static func log(_ s: String) {
        let line = "\(Date()) \(s)" + "\n"
        if let h = FileHandle(forWritingAtPath: path) {
            h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); h.closeFile()
        } else {
            try? line.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }
}


// Explicit entry point (SPM + @main on AppDelegate is unreliable)
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
