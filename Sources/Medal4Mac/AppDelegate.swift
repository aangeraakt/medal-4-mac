import AppKit
import ServiceManagement
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private var statusItem: NSStatusItem!
    private let engine = ReplayEngine()
    private let hotKeys = HotKeyManager()
    private let settings = AppSettings.shared

    private var isRecording = false
    private var statusText = "Starting…"
    private var savingCount = 0
    private var restartWorkItem: DispatchWorkItem?

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateIcon()

        try? FileManager.default.createDirectory(at: settings.clipsFolder, withIntermediateDirectories: true)

        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }

        engine.onStop = { [weak self] _ in
            Task { @MainActor in self?.streamStoppedUnexpectedly() }
        }

        registerHotKeys()
        rebuildMenu()
        startRecording()
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotKeys.unregisterAll()
    }

    // MARK: - Recording

    private func startRecording() {
        restartWorkItem?.cancel()
        if !CGPreflightScreenCaptureAccess() {
            // Shows the macOS permission prompt the first time.
            CGRequestScreenCaptureAccess()
        }

        isRecording = false
        statusText = "Starting…"
        updateIcon()
        rebuildMenu()

        let options = settings.captureOptions
        Task { @MainActor in
            do {
                let description = try await engine.start(options: options)
                isRecording = true
                statusText = "Recording · \(description)"
            } catch {
                isRecording = false
                statusText = "Not recording"
                showStartError(error)
            }
            updateIcon()
            rebuildMenu()
        }
    }

    private func streamStoppedUnexpectedly() {
        isRecording = false
        statusText = "Stopped — restarting…"
        updateIcon()
        rebuildMenu()
        // Usually caused by sleep / display changes; try again shortly.
        let item = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.startRecording() }
        }
        restartWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: item)
    }

    private func showStartError(_ error: Error) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        if !CGPreflightScreenCaptureAccess() {
            alert.messageText = "Medal 4 Mac needs Screen Recording permission"
            alert.informativeText = """
                Open System Settings → Privacy & Security → Screen Recording, turn on Medal4Mac, \
                then quit and reopen Medal 4 Mac.
                """
            alert.addButton(withTitle: "Open System Settings")
            alert.addButton(withTitle: "Later")
            if alert.runModal() == .alertFirstButtonReturn,
               let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
        } else {
            alert.messageText = "Could not start recording"
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    // MARK: - Clipping

    private func saveClip(seconds: Int) {
        guard isRecording else {
            NSSound.beep()
            notify(title: "Not recording", body: "Medal 4 Mac isn't recording right now.", fileURL: nil)
            return
        }

        savingCount += 1
        updateIcon()

        let url = settings.newClipURL(seconds: seconds)
        try? FileManager.default.createDirectory(at: settings.clipsFolder, withIntermediateDirectories: true)

        engine.saveClip(seconds: Double(seconds), to: url) { [weak self] result in
            Task { @MainActor in self?.clipFinished(result, seconds: seconds) }
        }
    }

    private func clipFinished(_ result: Result<URL, Error>, seconds: Int) {
        savingCount -= 1
        switch result {
        case .success(let url):
            NSSound(named: "Glass")?.play()
            notify(title: "Clip saved (\(clipLengthShort(seconds)))", body: url.lastPathComponent, fileURL: url)
            flashIcon()
        case .failure(let error):
            NSSound(named: "Basso")?.play()
            notify(title: "Clip failed", body: error.localizedDescription, fileURL: nil)
            updateIcon()
        }
    }

    // MARK: - Hotkeys

    private func registerHotKeys() {
        hotKeys.unregisterAll()

        let preset = settings.hotKeyPreset
        hotKeys.register(keyCode: preset.keyCode, modifiers: preset.modifiers) { [weak self] in
            Task { @MainActor in
                guard let self = self else { return }
                self.saveClip(seconds: self.settings.defaultClipSeconds)
            }
        }

        for (index, seconds) in clipLengths.enumerated() {
            hotKeys.register(keyCode: durationKeyCodes[index], modifiers: durationModifiers) { [weak self] in
                Task { @MainActor in self?.saveClip(seconds: seconds) }
            }
        }
    }

    // MARK: - Status bar icon

    private func updateIcon() {
        let symbol: String
        if savingCount > 0 {
            symbol = "arrow.down.circle"
        } else if isRecording {
            symbol = "record.circle.fill"
        } else {
            symbol = "record.circle"
        }
        statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Medal 4 Mac")
    }

    private func flashIcon() {
        statusItem.button?.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: "Clip saved")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            Task { @MainActor in self?.updateIcon() }
        }
    }

    // MARK: - Menu

    private func rebuildMenu() {
        let menu = NSMenu()

        let header = NSMenuItem(title: "Medal 4 Mac", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        let status = NSMenuItem(title: statusText, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())

        let preset = settings.hotKeyPreset
        let mainItem = item("Save Clip (\(clipLengthTitle(settings.defaultClipSeconds)))  —  \(preset.title)",
                            #selector(saveDefaultClip(_:)))
        menu.addItem(mainItem)
        for (index, seconds) in clipLengths.enumerated() {
            let clipItem = item("Save Last \(clipLengthTitle(seconds))  —  ⌃⌥\(index + 1)", #selector(saveClipItem(_:)))
            clipItem.tag = seconds
            menu.addItem(clipItem)
        }
        menu.addItem(.separator())

        // Clip hotkey
        let hotKeyMenu = NSMenu()
        for p in hotKeyPresets {
            let i = item(p.title, #selector(chooseHotKey(_:)))
            i.representedObject = p.id
            i.state = p.id == preset.id ? .on : .off
            hotKeyMenu.addItem(i)
        }
        menu.addItem(submenu("Clip Hotkey", hotKeyMenu))

        // Default length
        let lengthMenu = NSMenu()
        for seconds in clipLengths {
            let i = item(clipLengthTitle(seconds), #selector(chooseDefaultLength(_:)))
            i.tag = seconds
            i.state = seconds == settings.defaultClipSeconds ? .on : .off
            lengthMenu.addItem(i)
        }
        menu.addItem(submenu("Hotkey Clip Length", lengthMenu))

        // Resolution
        let resolutionMenu = NSMenu()
        for option in ResolutionOption.allCases {
            let i = item(option.title, #selector(chooseResolution(_:)))
            i.representedObject = option.rawValue
            i.state = option == settings.resolution ? .on : .off
            resolutionMenu.addItem(i)
        }
        menu.addItem(submenu("Resolution", resolutionMenu))

        // Frame rate
        let fpsMenu = NSMenu()
        for fps in [30, 60] {
            let i = item("\(fps) FPS", #selector(chooseFPS(_:)))
            i.tag = fps
            i.state = fps == settings.fps ? .on : .off
            fpsMenu.addItem(i)
        }
        menu.addItem(submenu("Frame Rate", fpsMenu))

        // Quality
        let qualityMenu = NSMenu()
        for option in QualityOption.allCases {
            let i = item(option.title, #selector(chooseQuality(_:)))
            i.representedObject = option.rawValue
            i.state = option == settings.quality ? .on : .off
            qualityMenu.addItem(i)
        }
        menu.addItem(submenu("Quality", qualityMenu))

        let audioItem = item("Record Game/System Audio", #selector(toggleAudio(_:)))
        audioItem.state = settings.captureAudio ? .on : .off
        menu.addItem(audioItem)

        menu.addItem(.separator())
        menu.addItem(item("Open Clips Folder", #selector(openClipsFolder(_:))))
        let loginItem = item("Open at Login", #selector(toggleLaunchAtLogin(_:)))
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(loginItem)
        menu.addItem(item("Restart Recording", #selector(restartRecording(_:))))
        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit Medal 4 Mac", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)

        statusItem.menu = menu
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: "")
        menuItem.target = self
        return menuItem
    }

    private func submenu(_ title: String, _ menu: NSMenu) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        menuItem.submenu = menu
        return menuItem
    }

    // MARK: - Menu actions

    @objc private func saveDefaultClip(_ sender: NSMenuItem) {
        saveClip(seconds: settings.defaultClipSeconds)
    }

    @objc private func saveClipItem(_ sender: NSMenuItem) {
        saveClip(seconds: sender.tag)
    }

    @objc private func chooseHotKey(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let preset = hotKeyPresets.first(where: { $0.id == id }) else { return }
        settings.hotKeyPreset = preset
        registerHotKeys()
        rebuildMenu()
    }

    @objc private func chooseDefaultLength(_ sender: NSMenuItem) {
        settings.defaultClipSeconds = sender.tag
        rebuildMenu()
    }

    @objc private func chooseResolution(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let option = ResolutionOption(rawValue: raw) else { return }
        settings.resolution = option
        startRecording()
    }

    @objc private func chooseFPS(_ sender: NSMenuItem) {
        settings.fps = sender.tag
        startRecording()
    }

    @objc private func chooseQuality(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let option = QualityOption(rawValue: raw) else { return }
        settings.quality = option
        startRecording()
    }

    @objc private func toggleAudio(_ sender: NSMenuItem) {
        settings.captureAudio.toggle()
        startRecording()
    }

    @objc private func openClipsFolder(_ sender: NSMenuItem) {
        try? FileManager.default.createDirectory(at: settings.clipsFolder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(settings.clipsFolder)
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("Medal4Mac: launch at login failed: \(error.localizedDescription)")
        }
        rebuildMenu()
    }

    @objc private func restartRecording(_ sender: NSMenuItem) {
        startRecording()
    }

    // MARK: - Notifications

    private func notify(title: String, body: String, fileURL: URL?) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if let fileURL = fileURL {
            content.userInfo = ["path": fileURL.path]
        }
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        // Clicking "Clip saved" shows the file in Finder.
        if let path = response.notification.request.content.userInfo["path"] as? String {
            let url = URL(fileURLWithPath: path)
            DispatchQueue.main.async {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        }
        completionHandler()
    }
}
