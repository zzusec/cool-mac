import AppKit
import ServiceManagement
import CoolMacCore
import CoolMacHardware
import CoolMacClient
import CoolMacUpdates
import CIPC

private actor ReadOnlyMonitor {
    private var hardware: FanHardware?
    func sample() throws -> HardwareSnapshot {
        if hardware == nil { hardware = try FanHardware() }
        return try hardware!.sample()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let client = ServiceClient()
    private let monitor = ReadOnlyMonitor()
    private let session = UUID().uuidString
    private var status = ServiceStatus()
    private var timer: Timer?
    private var polling = false
    private var controlling = false
    private var commissioning = false
    private var initialModeApplied = false
    private var quitting = false
    private var uiError: String?
    private var enhancement = 0
    private let enhancementPanel = EnhancementPanelController()
    private let updateCoordinator = UpdateCoordinator()
    private let updateWindow = UpdateWindowController()
    private var updating = false
    private var runningCDHash = ""
    private var modeItems: [CoolingMode: NSMenuItem] = [:]
    private let summaryView = CompactSummaryView()
    private let noticeItem = NSMenuItem()
    private let commissionItem = NSMenuItem()
    private let loginItem = NSMenuItem()
    private let updateItem = NSMenuItem()
    private let automaticUpdateItem = NSMenuItem()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Capture before Installer can replace the bundle on disk.
        runningCDHash = bundleCDHash
        enhancement = UserDefaults.standard.object(forKey: "enhancement") as? Int ?? 0
        if !Enhancement.isValid(enhancement) { enhancement = 0 }
        enhancementPanel.onChange = { [weak self] step in
            Task { @MainActor in await self?.applyEnhancement(step) }
        }
        updateCoordinator.onChange = { [weak self] state in
            guard let self else { return }
            // A background check only updates the menu notice; the window opens
            // only when the user asked for it.
            if self.updateCoordinator.presentsWindow {
                self.updateWindow.render(state: state, automatic: self.updateCoordinator.automaticEnabled)
            }
            self.refresh()
        }
        updateWindow.onCheck = { [weak self] in self?.updateCoordinator.check(autoInstall: true) }
        updateWindow.onToggleAutomatic = { [weak self] enabled in
            self?.updateCoordinator.automaticEnabled = enabled
            self?.refresh()
        }
        updateWindow.onClose = { [weak self] in self?.updateCoordinator.presentsWindow = false }
        updateWindow.onInstall = { [weak self] manifest in self?.installUpdate(manifest) }
        updateCoordinator.onVerifiedUpdate = { [weak self] manifest, automatic in self?.installUpdate(manifest, automatic: automatic) }
        item.autosaveName = "CoolMacStatusItem"
        item.button?.image = NSImage(systemSymbolName: "fanblades", accessibilityDescription: "清凉风扇")
        item.button?.imagePosition = .imageLeading
        item.button?.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        item.menu = menu
        menu.delegate = self
        buildMenu()
        refresh()
        if CommandLine.arguments.contains("--check-menu-layout") {
            checkMenuLayout()
            return
        }
        startPolling()
        Task {
            await poll()
            if AppInstallation.shouldOfferInstaller(backgroundAvailable: status.available) {
                presentInstaller()
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(willSleep), name: NSWorkspace.willSleepNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
        if CommandLine.arguments.contains("--show-menu") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.item.button?.performClick(nil) }
        }
    }

    private func startPolling() {
        timer?.invalidate()
        timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.poll() }
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        item.button?.performClick(nil)
        return true
    }

    private func add(_ title: String, action: Selector? = nil, key: String = "", to destination: NSMenu? = nil) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: key)
        entry.target = self
        (destination ?? menu).addItem(entry)
        return entry
    }

    private func buildMenu() {
        menu.autoenablesItems = false
        menu.minimumWidth = CompactSummaryView.width
        let summary = NSMenuItem()
        summary.view = summaryView
        menu.addItem(summary)
        noticeItem.action = #selector(noticeClicked)
        noticeItem.target = self
        noticeItem.isHidden = true
        menu.addItem(noticeItem)
        menu.addItem(.separator())
        let titles: [CoolingMode: String] = [.system: "系统自动", .cool: "凉爽自动", .boost: "强力散热（2 分钟）"]
        for (index, mode) in CoolingMode.allCases.enumerated() {
            let entry = add(titles[mode]!, action: #selector(selectMode(_:)), key: String(index))
            entry.representedObject = mode.rawValue
            modeItems[mode] = entry
        }
        menu.addItem(.separator())
        let settings = NSMenu(title: "设置")
        settings.autoenablesItems = false
        settings.minimumWidth = CompactSummaryView.width
        let settingsItem = add("设置")
        settingsItem.submenu = settings
        let enhancementItem = add("增强转速…", action: #selector(showEnhancement), to: settings)
        enhancementItem.toolTip = "在系统当前转速上增加"
        loginItem.title = "登录时启动"
        loginItem.action = #selector(toggleLogin)
        loginItem.target = self
        settings.addItem(loginItem)
        commissionItem.title = "安全自检…"
        commissionItem.action = #selector(commission)
        commissionItem.target = self
        settings.addItem(commissionItem)
        settings.addItem(.separator())
        let versionItem = add("版本 \(Product.version)", to: settings)
        versionItem.isEnabled = false
        versionItem.toolTip = "构建 \(Product.build)"
        automaticUpdateItem.title = "自动更新"
        automaticUpdateItem.action = #selector(toggleAutomaticUpdates)
        automaticUpdateItem.target = self
        automaticUpdateItem.toolTip = "启动后及每 6 小时检查，验证后自动安装并重启"
        settings.addItem(automaticUpdateItem)
        _ = add("查看详情…", action: #selector(showHelp), to: settings)
        updateItem.title = "检查更新…"
        updateItem.action = #selector(showUpdate)
        updateItem.target = self
        settings.addItem(updateItem)
        settings.addItem(.separator())
        _ = add("退出", action: #selector(quit), key: "q")
    }

    private func refresh() {
        let snapshot = status.snapshot
        let fresh = snapshot.map { abs(Date().timeIntervalSince1970 - $0.sampledAt) <= 5 } ?? false
        let hottest = fresh ? snapshot?.hottest : nil
        item.button?.title = hottest.map { String(format: " %.0f°", $0) } ?? " —"
        item.button?.setAccessibilityLabel(hottest.map { String(format: "清凉风扇，芯片最高温度 %.0f 摄氏度", $0) } ?? "清凉风扇，温度暂无有效读数")
        let fanRPM = fresh ? snapshot?.fans.map(\.actualRPM).max() : nil
        summaryView.update(temperature: hottest, rpm: fanRPM, enhancement: enhancement)
        let ceiling = snapshot?.fans.map { $0.maximumRPM * Enhancement.maximumManualFraction }.max()
        enhancementPanel.refresh(baseline: status.baselineRPM, commanded: status.commandedRPM, ceiling: ceiling, blocked: status.phase == .fault)
        if status.enhancement != enhancement {
            enhancement = status.enhancement
            UserDefaults.standard.set(enhancement, forKey: "enhancement")
        }
        let needsAttention = uiError != nil || status.phase == .fault || status.phase == .unavailable || (status.available && !status.commissioned)
        let hasUpdate = updateCoordinator.needsAttention
        noticeItem.isHidden = !needsAttention && !hasUpdate && !commissioning && status.phase != .restoring
        switch status.phase {
        case .fault: noticeItem.title = "需要处理…"
        case .unavailable: noticeItem.title = "后台未连接…"
        case .restoring: noticeItem.title = "正在恢复…"
        default:
            if hasUpdate {
                if case .failed = updateCoordinator.state { noticeItem.title = "更新未完成…" }
                else { noticeItem.title = "有可用更新…" }
            }
            else if commissioning { noticeItem.title = "正在自检…" }
            else if uiError != nil { noticeItem.title = "需要处理…" }
            else { noticeItem.title = "尚未启用控制…" }
        }
        for (mode, entry) in modeItems {
            entry.state = status.selectedMode == mode ? .on : .off
            entry.isEnabled = !updating && status.available && !commissioning && (mode == .system || (status.commissioned && status.phase != .fault && fresh))
        }
        commissionItem.isEnabled = !updating && status.available && fresh && snapshot?.supported == true && !commissioning && !controlling
        commissionItem.title = commissioning ? "正在自检…" : "安全自检…"
        automaticUpdateItem.state = updateCoordinator.automaticEnabled ? .on : .off
        automaticUpdateItem.isEnabled = !updating
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        item.button?.toolTip = status.selectedMode.title
    }

    private func checkMenuLayout() {
        let phases: [ControlPhase] = [.monitoring, .system, .cooling, .boosting, .restoring, .fault, .unavailable]
        let notices = ["", "需要处理…", "后台未连接…", "正在恢复…", "正在自检…", "尚未启用控制…", "有可用更新…", "更新未完成…"]
        var widths: [String: CGFloat] = [:]
        for phase in phases {
            for step in Enhancement.steps {
                enhancement = step
                status = ServiceStatus(
                    available: phase != .unavailable,
                    commissioned: true,
                    selectedMode: phase == .boosting ? .boost : .cool,
                    phase: phase,
                    message: String(repeating: "这是一段不应该撑宽菜单的底层状态与错误说明", count: 100),
                    snapshot: HardwareSnapshot(
                        sampledAt: Date().timeIntervalSince1970,
                        model: "Mac14,7",
                        temperatures: [TemperatureReading(key: "test", name: "布局测试值", celsius: 99, group: "cpu")],
                        fans: [FanReading(id: 0, actualRPM: 7199, minimumRPM: 1199, maximumRPM: 7199, targetRPM: 7199, manual: false)],
                        thermalPressure: 0,
                        supported: true,
                        issues: []
                    ),
                    enhancement: step,
                    baselineRPM: 7199,
                    commandedRPM: 7199
                )
                uiError = phase == .fault ? status.message : nil
                commissioning = phase == .monitoring
                refresh()
                menu.update()
                widths["\(phase.rawValue)-\(step)"] = menu.size.width
                widths["\(phase.rawValue)-\(step)-settings"] = menu.items.first(where: { $0.submenu != nil })!.submenu!.size.width
                // Every notice wording must fit the same fixed width too.
                for notice in notices {
                    noticeItem.isHidden = notice.isEmpty
                    noticeItem.title = notice
                    menu.update()
                    widths["\(phase.rawValue)-\(step)-notice-\(notice)"] = menu.size.width
                }
                noticeItem.isHidden = false
            }
        }
        let measured = Array(widths.values)
        guard let first = measured.first, first <= CompactSummaryView.width + 24,
              measured.allSatisfy({ $0 == first }) else {
            FileHandle.standardError.write(Data("菜单宽度回归失败：\(widths)\n".utf8))
            exit(1)
        }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            FileHandle.standardOutput.write(try encoder.encode(widths))
            FileHandle.standardOutput.write(Data("\n菜单宽度回归通过；未连接后台、未访问硬件。\n".utf8))
        } catch {
            FileHandle.standardError.write(Data("布局结果编码失败：\(error)\n".utf8))
            exit(1)
        }
        NSApp.terminate(nil)
    }

    private func poll() async {
        guard !polling, !quitting else { return }
        polling = true
        defer { polling = false; refresh() }
        if !updating { updateCoordinator.checkIfDue() }
        do {
            let response = try await client.request(ServiceRequest(operation: .status, session: session))
            guard response.ok else { throw HardwareError(response.error ?? response.status.message) }
            status = response.status
            guard !updating else { return }
            if commissioning && status.commissioned {
                commissioning = false
                controlling = false
                await choose(.cool)
            } else if status.phase == .fault {
                commissioning = false
                controlling = false
            } else if controlling && status.selectedMode == .system && status.phase != .restoring {
                controlling = false
            }
            if controlling || commissioning {
                let renew = try await client.request(ServiceRequest(operation: .renew, session: session, enhancement: enhancement))
                if !renew.ok {
                    controlling = false
                    commissioning = false
                    uiError = renew.error
                }
            } else if !initialModeApplied && !updating && status.commissioned && status.phase != .fault {
                initialModeApplied = true
                let saved = UserDefaults.standard.string(forKey: "preferredMode").flatMap(CoolingMode.init(rawValue:)) ?? .cool
                if saved == .cool { await choose(.cool) }
            }
        } catch {
            controlling = false
            commissioning = false
            status.available = false
            status.phase = .unavailable
            status.message = "后台未连接：\(error.localizedDescription)"
            // The installer replaces this bundle underneath a running copy. The
            // new manifest only authorizes the new build, so this process stays
            // refused forever; relaunching is the only way back. Only a real
            // replacement counts — a daemon restart must not restart the app.
            if !updating && !updateCoordinator.requiresInstallConfirmation && replacedOnDisk { relaunch() ; return }
            do { status.snapshot = try await monitor.sample() }
            catch { status.snapshot = nil; uiError = "温度读取失败：\(error.localizedDescription)" }
        }
    }

    /// True when the bundle on disk is no longer the build this process runs.
    /// Authorization is by cdhash, so a reinstall makes the running copy a
    /// stranger to the daemon: every request is refused until it restarts.
    private var replacedOnDisk: Bool {
        if AppInstallation.wasReplaced(at: Bundle.main.bundleURL) { return true }
        let path = Bundle.main.bundleURL.path
        guard !runningCDHash.isEmpty else { return false }
        var buffer = [CChar](repeating: 0, count: Int(CM_CODE_HASH_CAPACITY))
        guard cm_code_hash(path, &buffer, buffer.count) == 0 else { return false }
        let onDisk = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return !onDisk.isEmpty && onDisk != runningCDHash
    }

    private var bundleCDHash: String {
        var buffer = [CChar](repeating: 0, count: Int(CM_CODE_HASH_CAPACITY))
        guard let path = Bundle.main.executableURL?.path,
              cm_code_hash(path, &buffer, buffer.count) == 0 else { return "" }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// Replaces this process with the build now on disk, keeping the fan handed
    /// back first so a restart never leaves the previous build controlling it.
    ///
    /// The relaunch must happen *after* this process is gone. `open -a` while
    /// this copy is still running is a no-op ("already running"), and the exit
    /// that follows then leaves no instance at all. A detached helper waits for
    /// our PID to disappear and only then launches the new build.
    private func relaunch() {
        guard !quitting else { return }
        quitting = true
        timer?.invalidate()
        Task {
            _ = try? await client.request(ServiceRequest(operation: .restore, session: session))
            let path = Bundle.main.bundleURL.path
            let pid = ProcessInfo.processInfo.processIdentifier
            let script = "while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done; /usr/bin/open \(shellQuoted(path))"
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", script]
            // Detach so the waiting shell outlives this process.
            try? process.run()
            NSApp.terminate(nil)
        }
    }

    private func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func choose(_ mode: CoolingMode) async {
        guard !updating, !quitting else { return }
        do {
            let response = try await client.request(ServiceRequest(operation: .select, session: session, mode: mode, enhancement: mode == .system ? nil : enhancement))
            guard !updating, !quitting else { return }
            guard response.ok else { throw HardwareError(response.error ?? response.status.message) }
            status = response.status
            controlling = mode != .system
            uiError = nil
            if mode != .boost { UserDefaults.standard.set(mode.rawValue, forKey: "preferredMode") }
        } catch { uiError = error.localizedDescription; controlling = false }
        refresh()
    }

    private func applyEnhancement(_ step: Int) async {
        guard !updating else { return }
        guard Enhancement.isValid(step) else { uiError = "增强档位无效"; refresh(); return }
        enhancement = step
        UserDefaults.standard.set(step, forKey: "enhancement")
        guard status.available else { refresh(); return }
        // A latched fault blocks every takeover; the safety check must pass again
        // first. Keep the chosen step for when it does.
        guard status.phase != .fault else {
            uiError = "风扇处于故障锁定，请先完成「安全自检…」"
            refresh()
            return
        }
        // Enhancement only takes effect while this app controls the fan, so a
        // non-zero step moves a purely automatic selection to 凉爽自动.
        let mode: CoolingMode = step > 0 ? (status.selectedMode == .system ? .cool : status.selectedMode) : status.selectedMode
        guard mode != .system else { refresh(); return }
        await choose(mode)
    }

    @objc private func noticeClicked() {
        if !status.available && AppInstallation.shouldOfferInstaller(backgroundAvailable: false) {
            presentInstaller()
        } else if updateCoordinator.needsAttention, uiError == nil, status.phase != .fault {
            showUpdate()
        } else if status.phase == .fault, uiError == nil {
            // A fault latches until the fan is verified again; offer that check
            // here instead of only describing the state.
            commission()
        } else if status.available, !status.commissioned, uiError == nil {
            // "尚未启用控制" is an invitation, not a status blurb: the next step
            // is the safety check that enables control.
            commission()
        } else {
            showHelp()
        }
    }

    @objc private func showUpdate() {
        updateCoordinator.presentsWindow = true
        updateWindow.present(state: updateCoordinator.state, automatic: updateCoordinator.automaticEnabled, relativeTo: item.button)
        if case .idle = updateCoordinator.state { updateCoordinator.check(autoInstall: true) }
    }

    /// Hold the control lock across restore, staging, installation and confirmation.
    private func installUpdate(_ manifest: UpdateManifest, automatic: Bool = false) {
        guard !updating, !quitting, !automatic || updateCoordinator.automaticEnabled else { return }
        updating = true
        controlling = false
        commissioning = false
        refresh()
        Task {
            defer { updating = false; refresh() }
            await updateCoordinator.install(manifest, automatic: automatic, prepare: {
                let restored = try await self.client.request(ServiceRequest(operation: .restore, session: self.session))
                guard restored.ok else { throw HardwareError(restored.error ?? restored.status.message) }
                for _ in 0..<8 {
                    try await Task.sleep(for: .milliseconds(600))
                    let response = try await self.client.request(ServiceRequest(operation: .status, session: self.session))
                    if response.ok, response.status.phase == .system,
                       response.status.snapshot?.fans.allSatisfy({ !$0.manual }) == true {
                        self.status = response.status
                        return
                    }
                }
                throw HardwareError("系统自动模式尚未确认，已中止安装")
            }, apply: { identifier in
                let response = try await self.client.request(ServiceRequest(
                    operation: .installUpdate, session: self.session,
                    updateID: identifier.uuidString.lowercased()))
                guard response.ok else { throw HardwareError(response.error ?? response.status.message) }
            })
            if case .installed = updateCoordinator.state { relaunch() }
        }
    }

    @objc private func toggleAutomaticUpdates() {
        guard !updating else { return }
        updateCoordinator.automaticEnabled.toggle()
        updateWindow.render(state: updateCoordinator.state, automatic: updateCoordinator.automaticEnabled)
        refresh()
    }

    @objc private func showEnhancement() {
        let ceiling = status.snapshot?.fans.map { $0.maximumRPM * Enhancement.maximumManualFraction }.max()
        enhancementPanel.present(enhancement: enhancement, baseline: status.baselineRPM, commanded: status.commandedRPM, ceiling: ceiling, relativeTo: item.button)
    }

    @objc private func selectMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let mode = CoolingMode(rawValue: raw) else { return }
        Task { await choose(mode) }
    }

    @objc private func commission() {
        guard !updating, !quitting else { return }
        let alert = NSAlert()
        alert.messageText = "验证风扇升速与自动恢复"
        let steps = "风扇将短时加速约 6 秒，然后检查是否恢复系统自动。请先退出 Macs Fan Control、Stats 或其他风扇控制工具。\n\n自检通过后将启用凉爽自动。更早散热会增加风扇声音和耗电，无法保证持续高负载时机身不热。"
        // A latched fault is only actionable if the dialog says what latched it.
        alert.informativeText = status.phase == .fault ? "\(status.message)\n\n\(steps)" : steps
        alert.addButton(withTitle: "开始安全自检")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn, !updating, !quitting else { return }
        commissioning = true
        uiError = nil
        refresh()
        Task {
            guard !updating, !quitting else { return }
            do {
                let response = try await client.request(ServiceRequest(operation: .commission, session: session))
                guard !updating, !quitting else { return }
                guard response.ok else { throw HardwareError(response.error ?? response.status.message) }
                status = response.status
            } catch { commissioning = false; uiError = error.localizedDescription }
            refresh()
        }
    }

    @objc private func restore() {
        controlling = false
        commissioning = false
        UserDefaults.standard.set(CoolingMode.system.rawValue, forKey: "preferredMode")
        Task {
            do {
                let response = try await client.request(ServiceRequest(operation: .restore, session: session))
                guard response.ok else { throw HardwareError(response.error ?? response.status.message) }
                status = response.status
                uiError = nil
            } catch { uiError = "恢复请求未确认：\(error.localizedDescription)" }
            refresh()
        }
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
            uiError = SMAppService.mainApp.status == .requiresApproval ? "请在系统设置 → 通用 → 登录项中允许清凉风扇" : nil
        } catch { uiError = "登录启动设置失败：\(error.localizedDescription)" }
        refresh()
    }

    private func presentInstaller() {
        let alert = NSAlert()
        let package = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("安装清凉风扇.pkg")
        let hasPackage = FileManager.default.fileExists(atPath: package.path)
        alert.messageText = "请完成安装"
        alert.informativeText = "双击 DMG 中的「安装清凉风扇.pkg」，一次装好应用和后台。仅拖拽应用不能完成安装。\n\n如果刚刚开始安装，请等待安装器完成后再打开应用。"
        alert.addButton(withTitle: hasPackage ? "打开安装包" : "下载安装包")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async { [weak self] in
            guard let self, alert.runModal() == .alertFirstButtonReturn else { return }
            let destination = hasPackage ? package : URL(string: "https://github.com/zzusec/cool-mac/releases/latest")!
            if !NSWorkspace.shared.open(destination) {
                self.uiError = "无法打开安装包，请从 GitHub Releases 下载后双击安装。"
                self.refresh()
            }
        }
    }

    @objc private func showHelp() {
        let alert = NSAlert()
        alert.messageText = "清凉风扇 \(Product.version)"
        alert.informativeText = "原生菜单栏工具，不占 Dock。\n\n凉爽自动：50°C 以上接管风扇持续散热，降到 42°C 才交还系统自动；发生异常、失联或严重热压力时立即交还。手动期间不主动降速。\n\n强力散热：最多 2 分钟，可能明显增加噪声和耗电。\n\n显示的是芯片传感器温度，不是机身表面温度。不要与其他风扇工具同时控制。\n\n\(uiError ?? status.message)\n\n诊断工具：应用包 Contents/Helpers/coolmacctl"
        alert.addButton(withTitle: "知道了")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    @objc private func willSleep() {
        controlling = false
        commissioning = false
        Task { _ = try? await client.request(ServiceRequest(operation: .restore, session: session)) }
    }
    @objc private func didWake() {
        controlling = false
        initialModeApplied = false
        Task { await poll() }
    }

    @objc private func quit() {
        guard !quitting else { return }
        quitting = true
        timer?.invalidate()
        controlling = false
        Task {
            if status.available {
                do {
                    _ = try await client.request(ServiceRequest(operation: .restore, session: session))
                    for _ in 0..<5 {
                        try await Task.sleep(for: .milliseconds(500))
                        let response = try await client.request(ServiceRequest(operation: .status, session: session))
                        if response.status.phase == .system, response.status.snapshot?.fans.allSatisfy({ !$0.manual }) == true { NSApp.terminate(nil); return }
                    }
                    throw HardwareError("硬件自动模式尚未确认")
                } catch {
                    let alert = NSAlert()
                    alert.messageText = "自动恢复尚未确认"
                    alert.informativeText = "\(error.localizedDescription)\n\n建议保持程序并重试恢复。强行退出后后台会撤销许可并尝试恢复，但当前不能显示为已完成。"
                    alert.addButton(withTitle: "保持运行")
                    alert.addButton(withTitle: "仍然退出")
                    if alert.runModal() == .alertSecondButtonReturn { NSApp.terminate(nil); return }
                    quitting = false
                    startPolling()
                    return
                }
            }
            NSApp.terminate(nil)
        }
    }
}
