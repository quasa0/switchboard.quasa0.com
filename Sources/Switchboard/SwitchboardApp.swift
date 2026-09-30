import SwiftUI
import AppKit

@main struct SwitchboardApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model: DashboardModel
    private let launchOptions: UILaunchOptions
    init() {
        let options = UILaunchOptions(arguments: ProcessInfo.processInfo.arguments)
        launchOptions = options
        _model = StateObject(wrappedValue: DashboardModel(demo: options.requiresDemo,
                                                  previewState: options.requiresDemo ? options.previewState : nil,
                                                  previewProvider: options.requiresDemo ? options.previewProvider : nil))
    }
    var body: some Scene {
        Window("Switchboard", id: "dashboard") {
            AccountListView(model: model)
                .preferredColorScheme(launchOptions.requiresDemo ? (launchOptions.isDark ? .dark : .light) : .dark)
                .task {
                    delegate.model = model
                    if let error = launchOptions.validationError {
                        fputs("FAIL: \(error)\n", stderr)
                        exit(1)
                    }
                    if ProcessInfo.processInfo.arguments.contains("--update-smoke") {
                        guard !delegate.didStartAutomation else { return }
                        delegate.didStartAutomation = true
                        do { try await UpdateSmokeCheck.run(model: model, arguments: ProcessInfo.processInfo.arguments) }
                        catch { await model.shutdown(); fputs("FAIL: updater fixture: \(error.localizedDescription)\n", stderr); exit(1) }
                    } else if let marker = UpdateSmokeCheck.fixtureMarker {
                        try? Data((Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown").utf8).write(to: marker)
                        NSApp.terminate(nil)
                    } else if launchOptions.runsUISmoke {
                        guard !delegate.didStartAutomation else { return }
                        delegate.didStartAutomation = true
                        do {
                            let report = try await UISmokeCheck.run(model: model, output: launchOptions.smokeOutput)
                            delegate.uiSmokeQuitCheck = {
                                do {
                                    try report.writeAfterQuitCleanup(to: launchOptions.smokeOutput)
                                    print("PASS: unified dashboard actions, native preview states, and quit cleanup. No account engine or credential access.")
                                    print("Artifacts: \(launchOptions.smokeOutput.path)")
                                } catch {
                                    fputs("FAIL: could not write UI smoke report.\n", stderr)
                                    exit(1)
                                }
                            }
                            NSApplication.shared.terminate(nil)
                        } catch {
                            await model.shutdown()
                            fputs("FAIL: \(error.localizedDescription)\n", stderr)
                            exit(1)
                        }
                    } else if launchOptions.rendersPreview, let output = launchOptions.renderOutput {
                        guard !delegate.didStartAutomation else { return }
                        delegate.didStartAutomation = true
                        do {
                            _ = try await UIPreviewRenderer.render(model: model, state: launchOptions.previewState,
                                to: output, width: launchOptions.previewWidth, height: launchOptions.previewHeight, dark: launchOptions.isDark)
                            NSApplication.shared.terminate(nil)
                        } catch {
                            fputs("FAIL: \(error.localizedDescription)\n", stderr)
                            exit(1)
                        }
                    } else if launchOptions.checksQuit {
                        NSApplication.shared.terminate(nil)
                    } else if launchOptions.runsCredentialSmoke {
                        do {
                            try await Task.detached { try SmokeCheck.keychainRoundTrip() }.value
                            let second = model.claude.accounts[1]
                            await model.claude.switchAccount(second)
                            guard model.claude.activeID == second.id else { throw CocoaError(.validationMissingMandatoryProperty) }
                            await model.claude.rename(second, label: "Renamed")
                            guard model.claude.accounts[1].label == "Renamed" else { throw CocoaError(.validationMissingMandatoryProperty) }
                            print("PASS: native app loaded; real Keychain and isolated configs switched A → B → A → B; rotated credentials survived; UI actions passed; test secrets removed.")
                            exit(0)
                        } catch {
                            fputs("FAIL: \(error.localizedDescription)\n", stderr)
                            exit(1)
                        }
                    } else if !model.isDemo {
                        model.updates.start()
                        await model.refresh()
                        model.startAutoRefresh()
                    }
                }
        }
        .defaultSize(width: launchOptions.previewWidth, height: launchOptions.previewHeight)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
            DesktopUpdateCommands(updates: model.updates)
        }
        MenuBarExtra("Switchboard", systemImage: "person.2.crop.square.stack") {
            MenuContentView(model: model)
        }
    }
}

private struct DesktopUpdateCommands: Commands {
    @ObservedObject var updates: DesktopUpdates
    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { updates.check() }.disabled(!updates.canCheck)
        }
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: DashboardModel?
    var didStartAutomation = false
    var uiSmokeQuitCheck: (() -> Void)?
    private var stopping = false
    private var readyToQuit = false
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if readyToQuit { return .terminateNow }
        if stopping { return .terminateCancel }
        guard let model else { return .terminateNow }
        stopping = true
        // Keep AppKit's normal run loop active while async child cleanup completes.
        Task {
            await model.shutdown()
            uiSmokeQuitCheck?()
            uiSmokeQuitCheck = nil
            readyToQuit = true
            sender.terminate(nil)
        }
        return .terminateCancel
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
