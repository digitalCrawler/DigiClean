import BackgroundTasks
import Flutter
import Photos
import UIKit
import UniformTypeIdentifiers
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Background tasks must be registered before launch finishes.
    BackgroundCheck.register()
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "DigiCleanPlatformPlugin") {
      DigiCleanPlatformPlugin.register(with: registrar)
    }
  }
}

/// `digiclean/platform` channel for iOS.
///
/// iOS apps are sandboxed: DigiClean can only read folders the user picks in
/// the Files picker (On My iPhone, iCloud Drive, external drives, other
/// providers). Each pick yields a security-scoped URL; a bookmark of it is
/// persisted by Dart so access survives app restarts.
final class DigiCleanPlatformPlugin: NSObject, FlutterPlugin, UIDocumentPickerDelegate {
  private var pendingPick: FlutterResult?
  /// URLs whose security-scoped access is currently active, by path.
  private var activeURLs: [String: URL] = [:]
  private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "digiclean/platform", binaryMessenger: registrar.messenger())
    let instance = DigiCleanPlatformPlugin()
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "pickFolder":
      pickFolder(result: result)
    case "resolveBookmarks":
      result(resolveBookmarks(args["bookmarks"] as? [String] ?? []))
    case "releaseFolder":
      if let path = args["path"] as? String, let url = activeURLs.removeValue(forKey: path) {
        url.stopAccessingSecurityScopedResource()
      }
      result(nil)
    case "beginBackgroundTask":
      beginBackgroundTask()
      result(nil)
    case "endBackgroundTask":
      endBackgroundTask()
      result(nil)
    case "scheduleBackgroundCheck":
      BackgroundCheck.setEnabled(args["enabled"] as? Bool ?? false, snapshot: args["snapshot"] as? String)
      result(nil)
    case "photoLibraryAccess":
      PhotoLibrary.requestAccess(result)
    case "exportPhotoPreviews":
      PhotoLibrary.exportPreviews(dir: args["dir"] as? String ?? NSTemporaryDirectory(), result: result)
    case "deletePhotos":
      PhotoLibrary.delete(ids: args["ids"] as? [String] ?? [], result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: Folder access

  private func pickFolder(result: @escaping FlutterResult) {
    guard pendingPick == nil else {
      result(FlutterError(code: "busy", message: "A folder picker is already open", details: nil))
      return
    }
    guard let presenter = Self.topViewController() else {
      result(FlutterError(code: "no_ui", message: "No window to present the picker", details: nil))
      return
    }
    let picker: UIDocumentPickerViewController
    if #available(iOS 14.0, *) {
      picker = UIDocumentPickerViewController(forOpeningContentTypes: [UTType.folder], asCopy: false)
    } else {
      picker = UIDocumentPickerViewController(documentTypes: ["public.folder"], in: .open)
    }
    picker.allowsMultipleSelection = false
    picker.delegate = self
    pendingPick = result
    presenter.present(picker, animated: true)
  }

  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    guard let result = pendingPick else { return }
    pendingPick = nil
    guard let url = urls.first else {
      result(nil)
      return
    }
    guard url.startAccessingSecurityScopedResource() else {
      result(FlutterError(code: "denied", message: "Access to the folder was not granted", details: nil))
      return
    }
    activeURLs[url.path] = url
    do {
      let bookmark = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
      result(["path": url.path, "bookmark": bookmark.base64EncodedString()])
    } catch {
      result(FlutterError(code: "bookmark", message: error.localizedDescription, details: nil))
    }
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    pendingPick?(nil)
    pendingPick = nil
  }

  /// Returns one entry per input bookmark, in order. Entries whose bookmark
  /// can no longer be resolved have no "path".
  private func resolveBookmarks(_ bookmarks: [String]) -> [[String: Any]] {
    return bookmarks.map { encoded in
      guard let data = Data(base64Encoded: encoded) else { return ["bookmark": encoded] }
      var stale = false
      guard let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale),
            url.startAccessingSecurityScopedResource()
      else {
        return ["bookmark": encoded]
      }
      activeURLs[url.path] = url
      var refreshed = encoded
      if stale, let fresh = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
        refreshed = fresh.base64EncodedString()
      }
      return ["path": url.path, "bookmark": refreshed]
    }
  }

  // MARK: Background execution

  /// Asks iOS for extra time so a scan is not suspended the moment the user
  /// switches apps.
  private func beginBackgroundTask() {
    guard backgroundTask == .invalid else { return }
    backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "DigiClean scan") { [weak self] in
      self?.endBackgroundTask()
    }
  }

  private func endBackgroundTask() {
    guard backgroundTask != .invalid else { return }
    UIApplication.shared.endBackgroundTask(backgroundTask)
    backgroundTask = .invalid
  }

  // MARK: Helpers

  private static func topViewController() -> UIViewController? {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    let window = scenes
      .sorted { ($0.activationState == .foregroundActive ? 0 : 1) < ($1.activationState == .foregroundActive ? 0 : 1) }
      .flatMap { $0.windows }
      .first { $0.isKeyWindow } ?? scenes.first?.windows.first
    var top = window?.rootViewController
    while let presented = top?.presentedViewController {
      top = presented
    }
    return top
  }
}

// MARK: - Photos library

/// The Photos library is not made of files the scanner can read, so small
/// previews are written to the app's cache and analysed like files.
/// Deleting goes through PhotoKit: iOS asks the user to confirm and keeps the
/// photos in Recently Deleted for 30 days.
enum PhotoLibrary {
  static func requestAccess(_ result: @escaping FlutterResult) {
    let reply: (PHAuthorizationStatus) -> Void = { status in
      DispatchQueue.main.async {
        if status == .authorized {
          result("granted")
        } else if #available(iOS 14, *), status == .limited {
          result("limited")
        } else {
          result("denied")
        }
      }
    }
    if #available(iOS 14, *) {
      PHPhotoLibrary.requestAuthorization(for: .readWrite, handler: reply)
    } else {
      PHPhotoLibrary.requestAuthorization(reply)
    }
  }

  /// Writes a 512-px JPEG preview of every photo (reusing earlier ones) and
  /// returns what is known about each original. Only local data is used:
  /// nothing is downloaded from iCloud.
  static func exportPreviews(dir: String, result: @escaping FlutterResult) {
    DispatchQueue.global(qos: .userInitiated).async {
      let folder = URL(fileURLWithPath: dir, isDirectory: true)
      try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      let fetch = PHFetchOptions()
      fetch.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
      let assets = PHAsset.fetchAssets(with: .image, options: fetch)
      let manager = PHImageManager.default()
      let request = PHImageRequestOptions()
      request.isSynchronous = true
      request.deliveryMode = .highQualityFormat
      request.resizeMode = .fast
      request.isNetworkAccessAllowed = false
      var items: [[String: Any]] = []
      assets.enumerateObjects { asset, _, _ in
        autoreleasepool {
          let name = asset.localIdentifier.replacingOccurrences(of: "/", with: "_") + ".jpg"
          let file = folder.appendingPathComponent(name)
          if !FileManager.default.fileExists(atPath: file.path) {
            var data: Data?
            manager.requestImage(
              for: asset, targetSize: CGSize(width: 512, height: 512), contentMode: .aspectFit, options: request
            ) { image, _ in
              data = image?.jpegData(compressionQuality: 0.85)
            }
            guard let data = data, (try? data.write(to: file)) != nil else { return }
          }
          items.append([
            "id": asset.localIdentifier,
            "file": file.path,
            "width": asset.pixelWidth,
            "height": asset.pixelHeight,
            "created": Int64((asset.creationDate ?? Date.distantPast).timeIntervalSince1970 * 1000),
            "screenshot": asset.mediaSubtypes.contains(.photoScreenshot),
            "favorite": asset.isFavorite,
          ])
        }
      }
      DispatchQueue.main.async { result(items) }
    }
  }

  static func delete(ids: [String], result: @escaping FlutterResult) {
    let assets = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
    let count = assets.count
    PHPhotoLibrary.shared().performChanges({
      PHAssetChangeRequest.deleteAssets(assets)
    }) { success, error in
      DispatchQueue.main.async {
        if success {
          result(count)
        } else if (error as NSError?)?.code == 3072 {
          result(0)  // PHPhotosError.userCancelled: the user said no.
        } else {
          result(FlutterError(code: "delete_failed", message: error?.localizedDescription, details: nil))
        }
      }
    }
  }
}

// MARK: - Background check

/// A daily background refresh that notifies when storage is almost full or
/// the user's automatic rescan is due. Scanning happens in the app.
enum BackgroundCheck {
  static let taskId = "com.digiclean.check"
  private static let enabledKey = "digiclean.backgroundCheck.enabled"
  private static let snapshotKey = "digiclean.backgroundCheck.snapshot"
  private static let lowSpaceKey = "digiclean.backgroundCheck.lastLowSpace"
  private static let rescanKey = "digiclean.backgroundCheck.lastRescan"
  private static let day: TimeInterval = 86_400

  static func register() {
    // Keep the next check queued whenever the app goes to the background
    // (posted with and without scenes).
    for name in [UIScene.didEnterBackgroundNotification, UIApplication.didEnterBackgroundNotification] {
      NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in schedule() }
    }
    BGTaskScheduler.shared.register(forTaskWithIdentifier: taskId, using: nil) { task in
      guard let refresh = task as? BGAppRefreshTask else {
        task.setTaskCompleted(success: false)
        return
      }
      schedule()
      refresh.expirationHandler = { refresh.setTaskCompleted(success: false) }
      check()
      refresh.setTaskCompleted(success: true)
    }
  }

  static func setEnabled(_ enabled: Bool, snapshot: String?) {
    let defaults = UserDefaults.standard
    defaults.set(enabled, forKey: enabledKey)
    defaults.set(snapshot, forKey: snapshotKey)
    if enabled {
      UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
      schedule()
    } else {
      BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: taskId)
    }
  }

  static func schedule() {
    guard UserDefaults.standard.bool(forKey: enabledKey) else { return }
    let request = BGAppRefreshTaskRequest(identifier: taskId)
    request.earliestBeginDate = Date(timeIntervalSinceNow: day)
    try? BGTaskScheduler.shared.submit(request)
  }

  static func check() {
    let defaults = UserDefaults.standard
    let now = Date().timeIntervalSince1970
    let keys: Set<URLResourceKey> = [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]
    if let values = try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: keys),
      let free = values.volumeAvailableCapacityForImportantUsage,
      let total = values.volumeTotalCapacity, total > 0,
      free * 100 < Int64(total) * 10,
      now - defaults.double(forKey: lowSpaceKey) > 3 * day
    {
      let freeText = ByteCountFormatter.string(fromByteCount: free, countStyle: .file)
      notify(title: "Your iPhone is almost full", body: "\(freeText) free. Open DigiClean to free up space.")
      defaults.set(now, forKey: lowSpaceKey)
      return
    }
    // The Flutter app keeps its settings in UserDefaults under "flutter.".
    var rescanDays = 0
    if let raw = defaults.string(forKey: "flutter.settings.v1"), let data = raw.data(using: .utf8),
      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    {
      rescanDays = json["autoRescanDays"] as? Int ?? 0
    }
    guard rescanDays > 0 else { return }
    let interval = Double(rescanDays) * day
    var lastScan: TimeInterval = 0
    if let path = defaults.string(forKey: snapshotKey),
      let date = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    {
      lastScan = date.timeIntervalSince1970
    }
    if now - lastScan >= interval && now - defaults.double(forKey: rescanKey) >= interval {
      let body =
        lastScan == 0
        ? "Scan your folders to find duplicates and junk."
        : "Your last scan was \(Int((now - lastScan) / day)) days ago. Open DigiClean to scan again."
      notify(title: "Time for a clean-up", body: body)
      defaults.set(now, forKey: rescanKey)
    }
  }

  private static func notify(title: String, body: String) {
    let content = UNMutableNotificationContent()
    content.title = title
    content.body = body
    UNUserNotificationCenter.current().add(
      UNNotificationRequest(identifier: "digiclean.check", content: content, trigger: nil))
  }
}
