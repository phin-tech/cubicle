import AppKit

#if canImport(Sparkle)
import Sparkle

/// In-place updates with Sparkle: it reads the appcast on GitHub (SUFeedURL in Info.plist), downloads the newer
/// notarized zip, checks its EdDSA signature and replaces the app. The window, the daily check and the
/// automatic-update choice are Sparkle's.
///
/// Betas are in the same appcast, marked with Sparkle's `beta` channel; only copies that opted in are offered them.
/// Build numbers only go up, so a beta tester is moved on to the release that follows the beta.
@MainActor
final class UpdateChecker {
  static let shared = UpdateChecker()

  /// True when this build includes Sparkle. The SwiftPM development build does not, and hides the update UI.
  static let isAvailable = true

  private let channels = Channels()
  private lazy var controller = SPUStandardUpdaterController(
    startingUpdater: false, updaterDelegate: channels, userDriverDelegate: nil)
  private var started = false

  /// The defaults key of the Settings toggle for betas.
  nonisolated static let betaKey = "betaUpdates"
  /// Whether this copy is a beta (its version is like 0.7.0-beta.1). The beta toggle defaults to this, so a beta
  /// keeps getting betas until it is switched off.
  nonisolated static let runningBeta =
    (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)?.contains("-beta") ?? false

  /// The Settings toggle; Sparkle keeps it in the app's defaults.
  var automaticChecks: Bool {
    get { controller.updater.automaticallyChecksForUpdates }
    set { controller.updater.automaticallyChecksForUpdates = newValue }
  }

  var betaUpdates: Bool {
    get { UserDefaults.standard.object(forKey: Self.betaKey) as? Bool ?? Self.runningBeta }
    set { UserDefaults.standard.set(newValue, forKey: Self.betaKey) }
  }

  /// Starts Sparkle's scheduled checks, once. Debug builds skip them so working on Cubicle does not keep asking.
  func start() {
    #if !DEBUG
    guard !started else { return }
    started = true
    controller.startUpdater()
    #endif
  }

  /// Check for Updates…: Sparkle also says when Cubicle is up to date or the check failed.
  func checkForUpdates() {
    #if DEBUG
    NSApp.activate(ignoringOtherApps: true)
    let alert = NSAlert()
    alert.messageText = "Updates are off in debug builds"
    alert.informativeText = "Sparkle only runs in Release builds."
    alert.runModal()
    #else
    // A menu bar app is not frontmost, and Sparkle's window would open behind other apps.
    NSApp.activate(ignoringOtherApps: true)
    start()
    controller.checkForUpdates(nil)
    #endif
  }
}

/// Tells Sparkle which appcast channels this copy takes: the default one always, `beta` when opted in.
private final class Channels: NSObject, SPUUpdaterDelegate {
  func allowedChannels(for updater: SPUUpdater) -> Set<String> {
    let beta = UserDefaults.standard.object(forKey: UpdateChecker.betaKey) as? Bool ?? UpdateChecker.runningBeta
    return beta ? ["beta"] : []
  }
}

#else

/// Stand-in for builds without Sparkle (the SwiftPM development build), so callers need no conditionals.
@MainActor
final class UpdateChecker {
  static let shared = UpdateChecker()
  static let isAvailable = false
  var automaticChecks = false
  var betaUpdates = false
  func start() {}
  func checkForUpdates() {}
}

#endif
