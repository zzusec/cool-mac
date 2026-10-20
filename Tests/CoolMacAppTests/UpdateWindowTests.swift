import AppKit
import Testing
import CoolMacCore
import CoolMacUpdates
@testable import CoolMacApp

@MainActor
@Suite struct UpdateWindowTests {
    private func makeWindow() -> UpdateWindowController {
        _ = NSApplication.shared
        return UpdateWindowController()
    }

    private func manifest() -> UpdateManifest {
        UpdateManifest(
            bundleID: Product.bundleID,
            version: "99.0.0",
            build: Product.build + 1,
            minimumSystemVersion: "14.0",
            architectures: ["arm64"],
            assetURL: URL(string: "https://github.com/zzusec/cool-mac/releases/download/v99.0.0/CoolMac.pkg")!,
            assetBytes: 1,
            assetSHA256: String(repeating: "0", count: 64),
            notes: "Window test release notes"
        )
    }

    private func buttons(_ controller: UpdateWindowController) throws -> (check: NSButton, install: NSButton, automatic: NSButton) {
        let content = try #require(controller.window?.contentView)
        let buttons = content.subviews.compactMap { $0 as? NSButton }
        return (
            try #require(buttons.first { $0.action == NSSelectorFromString("check") }),
            try #require(buttons.first { $0.action == NSSelectorFromString("install") }),
            try #require(buttons.first { $0.action == NSSelectorFromString("toggleAutomatic") })
        )
    }

    @Test func renderingEveryStatePreservesVisibilityAndControls() throws {
        let controller = makeWindow()
        let window = try #require(controller.window)
        let controls = try buttons(controller)
        let update = manifest()
        let states: [(UpdateCoordinator.State, Bool, Bool, Bool)] = [
            (.idle, true, false, true),
            (.checking, false, false, true),
            (.upToDate, true, false, true),
            (.downloading(42), false, false, true),
            (.ready(update), true, true, true),
            (.installing, false, false, false),
            (.installed(update.version), false, false, true),
            (.failed("Test failure"), true, false, true),
        ]
        #expect(!window.isVisible)
        for (state, checkEnabled, installEnabled, automaticEnabled) in states {
            controller.render(state: .ready(update), automatic: true)
            controller.render(state: state, automatic: false)
            #expect(!window.isVisible)
            #expect(controls.check.isEnabled == checkEnabled)
            #expect(controls.install.isEnabled == installEnabled)
            #expect(controls.automatic.isEnabled == automaticEnabled)
            #expect(controls.automatic.state == .off)
        }
        controller.render(state: .idle, automatic: true)
        #expect(controls.automatic.state == .on)
    }

    @Test func onlyReadyStateRetainsAnInstallableManifest() throws {
        let controller = makeWindow()
        let controls = try buttons(controller)
        let action = try #require(controls.install.action)
        let update = manifest()
        var requested: [UpdateManifest] = []
        controller.onInstall = { requested.append($0) }

        controller.render(state: .ready(update), automatic: true)
        controls.install.performClick(nil)
        #expect(requested == [update])

        let states: [UpdateCoordinator.State] = [
            .idle, .checking, .upToDate, .downloading(10), .installing,
            .installed(update.version), .failed("Test failure"),
        ]
        for state in states {
            controller.render(state: .ready(update), automatic: true)
            controller.render(state: state, automatic: true)
            #expect(!controls.install.isEnabled)
            // Bypass the disabled button to prove its old manifest was cleared.
            NSApplication.shared.sendAction(action, to: controls.install.target, from: controls.install)
            #expect(requested == [update])
        }
        #expect(controller.window?.isVisible == false)
    }

    @Test func downloadProgressAndReleaseNotesDoNotLeakIntoOtherStates() throws {
        let controller = makeWindow()
        let content = try #require(controller.window?.contentView)
        let progress = try #require(content.subviews.compactMap { $0 as? NSProgressIndicator }.first)
        let labels = content.subviews.compactMap { $0 as? NSTextField }
        let update = manifest()

        controller.render(state: .ready(update), automatic: true)
        #expect(labels.contains { $0.stringValue == update.notes })
        controller.render(state: .downloading(42), automatic: true)
        #expect(!progress.isHidden)
        #expect(progress.doubleValue == 42)
        #expect(!labels.contains { $0.stringValue == update.notes })
        controller.render(state: .installing, automatic: true)
        #expect(progress.isHidden)
        #expect(controller.window?.isVisible == false)
    }

    @Test func windowDelegateForwardsCloseWithoutShowingTheWindow() throws {
        let controller = makeWindow()
        let window = try #require(controller.window)
        var closeCount = 0
        controller.onClose = { closeCount += 1 }
        #expect(window.delegate === controller)
        window.delegate?.windowWillClose?(Notification(name: NSWindow.willCloseNotification, object: window))
        #expect(closeCount == 1)
        #expect(!window.isVisible)
        controller.render(state: .checking, automatic: true)
        #expect(!window.isVisible)
        #expect(closeCount == 1)
    }
}
