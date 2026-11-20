import Cocoa
import Foundation

enum BrowserKind: String {
    case safari, chrome
}

enum BrowserVideoController {

    static func activeVideoBrowser() -> BrowserKind? {
        guard let front = NSWorkspace.shared.frontmostApplication else { return nil }
        let bundle = front.bundleIdentifier ?? ""
        if bundle == "com.apple.Safari" { return .safari }
        if bundle.hasPrefix("com.google.Chrome") { return .chrome }
        return nil
    }

    /// True when any running Safari/Chrome has a playing video.
    /// Used as the game-gate bypass, since the game occupies the screen while the
    /// browser sits behind it and its play state still needs controlling.
    static func anyBrowserHasVideo() -> Bool {
        for bundle in ["com.apple.Safari", "com.google.Chrome"] {
            guard NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first != nil else { continue }
            let kind: BrowserKind = bundle == "com.apple.Safari" ? .safari : .chrome
            let js = "!!document.querySelector('video') && !document.querySelector('video').paused"
            if let out = runJS(js, in: kind), out.trimmingCharacters(in: .whitespacesAndNewlines) == "true" {
                cachedBrowser = kind
                cacheStamp = Date()
                return true
            }
        }
        return false
    }

    /// Which browser had a playing video last. Reused for a short window so the
    /// browser probe (an Apple Events call) runs once per burst, not per keypress.
    private(set) static var cachedBrowser: BrowserKind?
    private static var cacheStamp = Date.distantPast
    private static let cacheTTL: TimeInterval = 20

    static func cachedVideoBrowser() -> BrowserKind? {
        guard let b = cachedBrowser else { return nil }
        if cachedBrowser != nil, Date().timeIntervalSince(cacheStamp) <= cacheTTL,
           let out = runJSIfTrusted("!!document.querySelector('video') && !document.querySelector('video').paused", in: b),
           out.trimmingCharacters(in: .whitespacesAndNewlines) == "true" {
            cacheStamp = Date()
            return b
        }
        return nil
    }

    /// Runs JS only when Automation permission is already granted, so a missing
    /// grant never triggers a new system prompt.
    @discardableResult
    static func runJSIfTrusted(_ js: String, in browser: BrowserKind) -> String? {
        guard hasAutomationTrust(browser) else { return nil }
        return runJS(js, in: browser)
    }

    static func hasAutomationTrust(_ browser: BrowserKind) -> Bool {
        let target = browser == .safari ? "Safari" : "Google Chrome"
        let q = String(UnicodeScalar(34))
        let src = "tell application " + q + "System Events" + q + " to (exists application process " + q + target + q + ")"
        var err: NSDictionary?
        guard let res = NSAppleScript(source: src)?.executeAndReturnError(&err) else { return false }
        if let e = err {
            Logger.log("trust probe error: " + String(describing: e))
            _ = res
            return false
        }
        return true
    }

    /// Runs JS in the given browser by writing the script to a temp file first,
    /// which avoids every AppleScript quoting problem.
    @discardableResult
    static func runJS(_ js: String, in browser: BrowserKind) -> String? {
        // AppleScript string escape: backslash then quote.
        let escaped = js.replacingOccurrences(of: "\\", with: "\\\\")
                        .replacingOccurrences(of: "\"", with: "\\\"")
        let q = String(UnicodeScalar(34))
        let bracket = String(UnicodeScalar(0x00AB)!) + String(UnicodeScalar(0x00BB)!)  // «»
        _ = bracket
        let script: String
        switch browser {
        case .safari:
            script = "tell application \"Safari\" to do JavaScript " + q + escaped + q + " in current tab of window 1"
        case .chrome:
            script = "tell application \"Google Chrome\" to execute front window's active tab javascript " + q + escaped + q
        }
        Logger.log("SCRIPT: " + script)
        var err: NSDictionary?
        let apple = NSAppleScript(source: script)
        let result = apple?.executeAndReturnError(&err)
        if let e = err {
            Logger.log("AppleScript ERROR: " + String(describing: e))
            return nil
        }
        return result?.stringValue
    }

    static func isBilibiliVideo(_ browser: BrowserKind) -> Bool {
        let js = "location.hostname.includes('bilibili.com') && !!document.querySelector('video')"
        guard let out = runJS(js, in: browser) else { return false }
        return out.lowercased().contains("true")
    }

    static func togglePlayback(_ browser: BrowserKind) -> Bool? {
        let js = "(function(){var v=document.querySelector('video');if(!v)return 'none';"
            + "if(v.paused){v.play();return 'playing';}else{v.pause();return 'paused';}})()"
        guard let out = runJS(js, in: browser) else { return nil }
        if out.contains("playing") { return false }
        if out.contains("paused") { return true }
        return nil
    }

    static func seek(_ browser: BrowserKind, seconds: Double) -> Bool {
        let js = "(function(){var v=document.querySelector('video');if(!v)return 'none';"
            + "v.currentTime=Math.max(0,Math.min(v.duration||1e9,v.currentTime+(" + String(seconds) + ")));"
            + "return 'ok';})()"
        return runJS(js, in: browser)?.contains("ok") ?? false
    }
}

