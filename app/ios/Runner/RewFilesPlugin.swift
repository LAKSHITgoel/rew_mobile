// iOS half of the `rew_mobile/files` channel: where tunes are stored, loading a
// UMIK-1 calibration .txt, and getting a measured graph out of the app as PNG or
// CSV. Mirrors the Android implementation in MainActivity.kt — same method names
// and argument shapes, because the Dart side (platform/file_picker.dart) is
// shared.
//
// Everything that shows UI must run on the main thread, and every FlutterResult
// must be called exactly once — including when the user cancels the picker.
import Flutter
import UIKit

public final class RewFilesPlugin: NSObject, FlutterPlugin {

    /// Retains the active picker delegate; UIKit does not own it.
    private var pending: PickerDelegate?

    public static func register(with registrar: FlutterPluginRegistrar) {
        let instance = RewFilesPlugin()
        let channel = FlutterMethodChannel(name: "rew_mobile/files",
                                           binaryMessenger: registrar.messenger())
        registrar.addMethodCallDelegate(instance, channel: channel)
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any] ?? [:]

        switch call.method {
        case "appDir":
            // Tunes live here and must survive a restart; on iOS this is the
            // app's Documents directory.
            result(RewFilesPlugin.documentsDir()?.path)

        case "exportDir":
            guard let dir = RewFilesPlugin.documentsDir()?
                    .appendingPathComponent("exports", isDirectory: true) else {
                result(nil)
                return
            }
            try? FileManager.default.createDirectory(at: dir,
                                                     withIntermediateDirectories: true)
            result(dir.path)

        case "pickTextFile":
            pickTextFile(result: result)

        case "saveFileAs":
            guard let path = args["path"] as? String,
                  let name = args["name"] as? String else {
                result(FlutterError(code: "bad_args",
                                    message: "path and name are required",
                                    details: nil))
                return
            }
            saveFileAs(path: path, name: name, result: result)

        case "shareFiles":
            let paths = args["paths"] as? [String] ?? []
            shareFiles(paths: paths, result: result)

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - Calibration file

    /// Opens the system picker and returns the file's *contents*, which is what
    /// the Dart side parses. Returns nil if the user cancels.
    private func pickTextFile(result: @escaping FlutterResult) {
        DispatchQueue.main.async {
            guard let host = RewFilesPlugin.topViewController() else {
                result(nil)
                return
            }
            // A UMIK-1 calibration file is plain text; allow generic data too,
            // since some are handed over with an unhelpful type.
            let picker = UIDocumentPickerViewController(
                documentTypes: ["public.plain-text", "public.text", "public.data"],
                in: .import)
            let delegate = PickerDelegate { [weak self] urls in
                defer { self?.pending = nil }
                guard let url = urls.first else {
                    result(nil)
                    return
                }
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                result(try? String(contentsOf: url, encoding: .utf8))
            }
            self.pending = delegate
            picker.delegate = delegate
            picker.allowsMultipleSelection = false
            host.present(picker, animated: true)
        }
    }

    // MARK: - Export

    /// "Save as": the user picks the folder and confirms the name, so an exported
    /// graph lands in Files where they can hand it to someone.
    private func saveFileAs(path: String, name: String,
                            result: @escaping FlutterResult) {
        DispatchQueue.main.async {
            let source = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: path),
                  let host = RewFilesPlugin.topViewController() else {
                result(false)
                return
            }
            // Export copies whatever URL it is given under that URL's own name,
            // so stage a copy carrying the name the user asked for.
            let staged = FileManager.default.temporaryDirectory
                .appendingPathComponent(name)
            try? FileManager.default.removeItem(at: staged)
            do {
                try FileManager.default.copyItem(at: source, to: staged)
            } catch {
                result(false)
                return
            }

            let picker = UIDocumentPickerViewController(url: staged,
                                                        in: .exportToService)
            let delegate = PickerDelegate { [weak self] urls in
                self?.pending = nil
                result(!urls.isEmpty)
            }
            self.pending = delegate
            picker.delegate = delegate
            host.present(picker, animated: true)
        }
    }

    private func shareFiles(paths: [String], result: @escaping FlutterResult) {
        DispatchQueue.main.async {
            let urls = paths.map { URL(fileURLWithPath: $0) }
                .filter { FileManager.default.fileExists(atPath: $0.path) }
            guard !urls.isEmpty, let host = RewFilesPlugin.topViewController() else {
                result(nil)
                return
            }
            let sheet = UIActivityViewController(activityItems: urls,
                                                 applicationActivities: nil)
            // On iPad a share sheet without an anchor crashes.
            if let pop = sheet.popoverPresentationController {
                pop.sourceView = host.view
                pop.sourceRect = CGRect(x: host.view.bounds.midX,
                                        y: host.view.bounds.midY,
                                        width: 0, height: 0)
                pop.permittedArrowDirections = []
            }
            host.present(sheet, animated: true)
            result(nil)
        }
    }

    // MARK: - Helpers

    private static func documentsDir() -> URL? {
        return FileManager.default.urls(for: .documentDirectory,
                                        in: .userDomainMask).first
    }

    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
        let window = scenes.flatMap { $0.windows }.first { $0.isKeyWindow }
            ?? scenes.first?.windows.first
        var top = window?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }
}

/// Bridges the picker's delegate callbacks to a single completion, so a cancel
/// answers the Dart side too instead of leaving the call hanging forever.
private final class PickerDelegate: NSObject, UIDocumentPickerDelegate {
    private let completion: ([URL]) -> Void
    private var finished = false

    init(completion: @escaping ([URL]) -> Void) {
        self.completion = completion
    }

    func documentPicker(_ controller: UIDocumentPickerViewController,
                        didPickDocumentsAt urls: [URL]) {
        finish(urls)
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        finish([])
    }

    private func finish(_ urls: [URL]) {
        guard !finished else { return }
        finished = true
        completion(urls)
    }
}
