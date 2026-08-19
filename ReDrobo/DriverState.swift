//  DriverState.swift
//
//  Asking macOS about the driver, rather than inferring it.
//
//  The old check was "is there a DroboDext service in the registry", and it was
//  wrong in a way that showed: a DriverKit service only exists once the driver
//  has *matched an enclosure*, so unplugging the Drobo made a perfectly well
//  installed driver report as missing. Install state and device presence are
//  two different questions and are answered separately here.

import Foundation
import SystemExtensions
import AppKit

// MARK: - What the system says about our extension

enum DriverInstallState: Equatable, Sendable {
    case checking
    case notInstalled
    case awaitingApproval
    case installed(build: String?, enabled: Bool)
    case error(String)

    var isUsable: Bool {
        if case .installed(_, let enabled) = self { return enabled }
        return false
    }

    var installedBuild: String? {
        if case .installed(let build, _) = self { return build }
        return nil
    }
}

// MARK: - Talking to sysextd

/// One delegate per request, keeping itself alive until the request ends.
/// OSSystemExtensionRequest holds its delegate weakly, so something has to.
///
/// Every request here is submitted on the main queue, so the callbacks arrive
/// one at a time and `finish` needs no locking to fire exactly once.
private final class RequestDelegate: NSObject, OSSystemExtensionRequestDelegate {
    private var keepAlive: RequestDelegate?
    private var properties: (([OSSystemExtensionProperties]) -> Void)?
    private var approval: (() -> Void)?
    private var finish: ((Result<OSSystemExtensionRequest.Result, any Error>) -> Void)?

    init(properties: (([OSSystemExtensionProperties]) -> Void)? = nil,
         approval: (() -> Void)? = nil,
         finish: ((Result<OSSystemExtensionRequest.Result, any Error>) -> Void)? = nil) {
        self.properties = properties
        self.approval = approval
        self.finish = finish
        super.init()
    }

    func submit(_ request: OSSystemExtensionRequest) {
        keepAlive = self
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    private func done(_ result: Result<OSSystemExtensionRequest.Result, any Error>) {
        let f = finish
        finish = nil
        properties = nil
        approval = nil
        f?(result)
        keepAlive = nil
    }

    func request(_ request: OSSystemExtensionRequest,
                 foundProperties props: [OSSystemExtensionProperties]) {
        properties?(props)
        properties = nil
    }

    func request(_ request: OSSystemExtensionRequest,
                 actionForReplacingExtension existing: OSSystemExtensionProperties,
                 withExtension ext: OSSystemExtensionProperties)
    -> OSSystemExtensionRequest.ReplacementAction { .replace }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        approval?()
    }

    func request(_ request: OSSystemExtensionRequest,
                 didFinishWithResult result: OSSystemExtensionRequest.Result) {
        done(.success(result))
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: any Error) {
        done(.failure(error))
    }
}

enum DriverExtension {

    /// The build of the driver this app is carrying, read out of the embedded
    /// bundle. Compared against what is installed, it answers "does pressing
    /// Install actually change anything".
    static var carriedBuild: String? {
        let plist = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/SystemExtensions")
            .appendingPathComponent("\(kDextBundleID).dext")
            .appendingPathComponent("Info.plist")
        return (NSDictionary(contentsOf: plist))?["CFBundleVersion"] as? String
    }

    /// Ask sysextd what it has for our identifier. Nothing else can distinguish
    /// "never installed" from "installed but waiting for approval".
    /// An instant answer, read off disk.
    ///
    /// `/Library/SystemExtensions/db.plist` is the database `systemextensionsctl
    /// list` prints. It is world readable and answers in microseconds, where
    /// `OSSystemExtensionRequest` sometimes takes twenty seconds — long enough
    /// that the window sat on "Checking…" with nothing actually wrong.
    ///
    /// It is unofficial, so it is treated strictly as a hint: the real request
    /// still runs and overwrites whatever this said, and anything unexpected in
    /// the file yields nil rather than a guess.
    static func cachedStatus() -> DriverInstallState? {
        let url = URL(fileURLWithPath: "/Library/SystemExtensions/db.plist")
        guard let data = try? Data(contentsOf: url),
              let root = try? PropertyListSerialization
                  .propertyList(from: data, format: nil) as? [String: Any],
              let extensions = root["extensions"] as? [[String: Any]]
        else { return nil }

        let ours = extensions.filter { $0["identifier"] as? String == kDextBundleID }
        guard !ours.isEmpty else { return .notInstalled }

        func build(_ entry: [String: Any]) -> String? {
            if let v = entry["bundleVersion"] as? [String: Any] {
                return v["CFBundleVersion"] as? String
            }
            return entry["bundleVersion"] as? String
        }

        let states = ours.map { ($0["state"] as? String ?? "", build($0)) }
        if states.contains(where: { $0.0.contains("waiting_for_user") }) {
            return .awaitingApproval
        }
        if let enabled = states.first(where: { $0.0 == "activated_enabled" }) {
            return .installed(build: enabled.1, enabled: true)
        }
        if let disabled = states.first(where: { $0.0 == "activated_disabled" }) {
            return .installed(build: disabled.1, enabled: false)
        }
        if states.allSatisfy({ $0.0.contains("uninstall") }) { return .notInstalled }
        return nil
    }

    private final class StateBox {
        var state: DriverInstallState?
        var answered = false
    }

    static func status(_ completion: @escaping (DriverInstallState) -> Void) {
        let request = OSSystemExtensionRequest.propertiesRequest(
            forExtensionWithIdentifier: kDextBundleID, queue: .main)

        // foundProperties, when it comes at all, always precedes the finish
        // callback on the same queue. A request that finds nothing simply
        // finishes without it, which is what "not installed" looks like.
        let box = StateBox()

        let delegate = RequestDelegate(
            properties: { props in
                let ours = props.filter { $0.bundleIdentifier == kDextBundleID
                                       && !$0.isUninstalling }
                if ours.contains(where: { $0.isAwaitingUserApproval }) {
                    box.state = .awaitingApproval
                } else if let live = ours.first(where: { $0.isEnabled }) {
                    box.state = .installed(build: live.bundleVersion, enabled: true)
                } else if let any = ours.first {
                    box.state = .installed(build: any.bundleVersion, enabled: false)
                } else {
                    box.state = .notInstalled
                }
            },
            finish: { result in
                guard !box.answered else { return }
                box.answered = true
                if case .failure(let e) = result, box.state == nil {
                    completion(.error(e.localizedDescription))
                } else {
                    completion(box.state ?? .notInstalled)
                }
            })

        delegate.submit(request)

        // sysextd can take a long time to answer, especially the first time
        // after a boot, and a request that never comes back would leave the
        // window saying "Checking…" indefinitely. The app has a faster and
        // better signal anyway — whether a service is bound in the registry —
        // so this only has to stop the slow path from hanging.
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
            guard !box.answered else { return }
            box.answered = true
            completion(box.state ?? .error("macOS did not answer in time."))
        }
    }

    static func activate(message: @escaping (String, Bool) -> Void) {
        let request = OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: kDextBundleID, queue: .main)

        let delegate = RequestDelegate(
            approval: {
                message("Approve ReDrobo Driver in System Settings, under General ▸ "
                      + "Login Items & Extensions ▸ Driver Extensions.", false)
            },
            finish: { result in
                switch result {
                case .success:
                    message("Driver installed. Restart your Mac to start using it, "
                          + "because macOS keeps running the previous driver until then.",
                            true)
                case .failure(let error):
                    message("Installation failed. \(error.localizedDescription)", true)
                }
            })

        delegate.submit(request)
        message("Asking macOS to install the driver…", false)
    }

    /// Take the driver back out. macOS unloads it at the next restart rather
    /// than immediately, same as it replaces one.
    static func deactivate(message: @escaping (String, Bool) -> Void) {
        Log.info("requesting driver deactivation")
        let request = OSSystemExtensionRequest.deactivationRequest(
            forExtensionWithIdentifier: kDextBundleID, queue: .main)

        let delegate = RequestDelegate(
            approval: {
                message("Approve the removal in System Settings, under General ▸ "
                      + "Login Items & Extensions ▸ Driver Extensions.", false)
            },
            finish: { result in
                switch result {
                case .success:
                    Log.info("driver deactivation accepted")
                    message("Driver removed. Restart your Mac to finish: macOS keeps "
                          + "running it until then.", true)
                case .failure(let error):
                    Log.error("driver deactivation failed: \(error.localizedDescription)")
                    message("Removal failed. \(error.localizedDescription)", true)
                }
            })

        delegate.submit(request)
        message("Asking macOS to remove the driver…", false)
    }

    /// Where the approval switch lives. Falls back to System Settings at large
    /// if that pane identifier ever moves.
    static func openExtensionSettings() {
        let pane = "x-apple.systempreferences:com.apple.LoginItems-Settings.extension"
        if let url = URL(string: pane), NSWorkspace.shared.open(url) { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
    }
}
