//
//  PrivateBrowsingAuthenticator.swift
//  Reynard
//

import Foundation
import LocalAuthentication

/// Thin wrapper around `LAContext` used to gate access to private tabs
/// behind Face ID / Touch ID (falling back to the device passcode, which
/// is required so users who haven't enrolled biometrics, or whose Face ID
/// briefly fails, aren't permanently locked out of their own tabs).
final class PrivateBrowsingAuthenticator {
    static let shared = PrivateBrowsingAuthenticator()

    enum AuthenticationResult {
        case success
        /// No passcode/biometrics are configured on the device at all, or
        /// the policy otherwise can't be evaluated. Callers should treat
        /// this as "allow access" since there's nothing to authenticate
        /// against.
        case unavailable
        case cancelled
        case failed(Error?)
    }

    private init() {}

    /// Whether the device can evaluate device-owner authentication at all
    /// (Face ID, Touch ID, or a passcode). Used to decide whether the
    /// "Require Face ID for Private Tabs" setting can be offered.
    var isAvailable: Bool {
        var error: NSError?
        return LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: &error)
    }

    /// The kind of biometry the device supports, if any. Only meaningful
    /// after `canEvaluatePolicy` has been queried, so this creates its own
    /// throwaway context.
    var biometryType: LABiometryType {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
        return context.biometryType
    }

    func authenticate(
        reason: String,
        completion: @escaping (AuthenticationResult) -> Void
    ) {
        let context = LAContext()
        context.localizedFallbackTitle = NSLocalizedString("Use Passcode", comment: "")

        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            DispatchQueue.main.async {
                completion(.unavailable)
            }
            return
        }

        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, evaluationError in
            DispatchQueue.main.async {
                if success {
                    completion(.success)
                    return
                }

                if let laError = evaluationError as? LAError,
                   laError.code == .userCancel || laError.code == .systemCancel || laError.code == .appCancel {
                    completion(.cancelled)
                    return
                }

                completion(.failed(evaluationError))
            }
        }
    }
}
