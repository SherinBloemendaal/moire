import Combine
import Foundation
import Sparkle
import SwiftUI

/// Finds new versions of Moire on GitHub, shows what changed, and installs them, through Sparkle.
@Observable
final class Updates {
    static let shared = Updates()

    /// Nil when the app runs outside its bundle (`swift run`, the tests): there is nothing to
    /// replace there, and no feed or key to check against.
    private let controller: SPUStandardUpdaterController?
    /// False while a check is already running.
    private(set) var canCheck = false
    @ObservationIgnored private var watch: AnyCancellable?

    private init() {
        guard Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") != nil else {
            controller = nil
            return
        }
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        self.controller = controller
        watch = controller.updater.publisher(for: \.canCheckForUpdates).sink { [weak self] canCheck in
            MainActor.assumeIsolated { self?.canCheck = canCheck }
        }
    }

    var isAvailable: Bool { controller != nil }

    /// Checks now and shows the result, also when Moire is up to date.
    func check() {
        controller?.checkForUpdates(nil)
    }

    var checksAutomatically: Bool {
        get {
            access(keyPath: \.checksAutomatically)
            return controller?.updater.automaticallyChecksForUpdates ?? false
        }
        set {
            withMutation(keyPath: \.checksAutomatically) {
                controller?.updater.automaticallyChecksForUpdates = newValue
            }
        }
    }

    var installsAutomatically: Bool {
        get {
            access(keyPath: \.installsAutomatically)
            return controller?.updater.automaticallyDownloadsUpdates ?? false
        }
        set {
            withMutation(keyPath: \.installsAutomatically) {
                controller?.updater.automaticallyDownloadsUpdates = newValue
            }
        }
    }

    var lastCheck: Date? { controller?.updater.lastUpdateCheckDate }
}

/// The Updates tab of the settings.
struct UpdateSettingsView: View {
    @Bindable private var updates = Updates.shared

    var body: some View {
        Form {
            if updates.isAvailable {
                Toggle("Check for updates automatically", isOn: $updates.checksAutomatically)
                Toggle("Download and install updates automatically", isOn: $updates.installsAutomatically)
                    .disabled(!updates.checksAutomatically)
                LabeledContent("Last checked") {
                    Text(updates.lastCheck.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "Never")
                }
                Button("Check Now") { updates.check() }
                    .disabled(!updates.canCheck)
            } else {
                Text("Updates are checked only in the installed app.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
    }
}
