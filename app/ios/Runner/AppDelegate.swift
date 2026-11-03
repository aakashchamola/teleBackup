import Flutter
import UIKit
import BackgroundTasks
import Photos

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private let host = CoreHost()

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    BackgroundWork.register()   // must happen before the app finishes launching
    Notifier.shared.setup()
    observeLifecycle()
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    let messenger = engineBridge.applicationRegistrar.messenger()
    CoreHostApiSetup.setUp(binaryMessenger: messenger, api: host)
    Runtime.shared.events_ = CoreEventsApi(binaryMessenger: messenger)
    Runtime.shared.refreshSignature()
    Runtime.shared.flushPendingRoute()
  }

  private func observeLifecycle() {
    NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
      Notifier.shared.clearProgress()
      Runtime.shared.startRun()
      Runtime.shared.pushStatus()
      Runtime.shared.flushPendingRoute()
      Runtime.shared.armDelayTimer()
    }
    NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
      BackgroundWork.schedule()
    }
  }
}
