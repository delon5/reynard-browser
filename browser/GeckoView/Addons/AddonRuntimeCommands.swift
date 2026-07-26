//
//  AddonRuntimeCommands.swift
//  Reynard
//
//  Created by Minh Ton on 17/6/26.
//

import Foundation

public extension AddonRuntime {
    func list() async throws -> [Addon] {
        let response = try await GeckoEventDispatcherWrapper.runtimeInstance.query(type: "GeckoView:WebExtension:List")
        guard let payload = response as? [String: Any?] else {
            return Array(addonsByID.values)
        }
        
        let entries = payload["extensions"] as? [[String: Any?]] ?? []
        let listedAddonIDs = Set(entries.compactMap { $0["webExtensionId"] as? String })
        let staleAddonIDs = addonsByID.keys.filter { !listedAddonIDs.contains($0) }
        let removedAddons = staleAddonIDs.compactMap { removeAddon(byID: $0) }
        entries.forEach { _ = upsertAddon(from: $0) }
        removedAddons.forEach { delegate?.addonController(self, didUpdate: $0) }
        return installedAddons
    }
    
    func addon(byID id: String) async throws -> Addon? {
        if let cached = addonsByID[id] {
            return cached
        }
        
        let response = try await GeckoEventDispatcherWrapper.runtimeInstance.query(
            type: "GeckoView:WebExtension:Get",
            message: ["extensionId": id]
        )
        guard let payload = response as? [String: Any?],
              let addonPayload = payload["extension"] as? [String: Any?] else {
            return nil
        }
        
        return upsertAddon(from: addonPayload)
    }
    
    func install(url: String, installMethod: AddonInstallMethod? = nil) async throws -> Addon {
        installCounter += 1
        let response = try await GeckoEventDispatcherWrapper.runtimeInstance.query(
            type: "GeckoView:WebExtension:Install",
            message: [
                "locationUri": url,
                "installId": "reynard-\(installCounter)",
                "installMethod": installMethod?.rawValue as Any,
            ]
        )
        guard let payload = response as? [String: Any?],
              let addonPayload = payload["extension"] as? [String: Any?] else {
            throw GeckoHandlerError("Invalid install response")
        }
        let addon = upsertAddon(from: addonPayload)
        delegate?.addonController(self, didUpdate: addon)
        return addon
    }
    
    /// Installs a first-party, app-bundled extension — distinct from
    /// `install(url:)` above, which is for user-initiated installs of
    /// signed, third-party .xpi packages. Built-in extensions don't
    /// require Mozilla's own signature and gain access to native
    /// messaging, exactly matching the official GeckoView platform API
    /// this project's engine is built on (WebExtensionController's own
    /// installBuiltIn, documented to require a resource:// URI pointing
    /// at a folder bundled inside the app itself, not a downloaded
    /// .xpi). Genuinely new to this project — no existing caller uses
    /// this message type yet, so the exact resource:// path convention
    /// this specific iOS port expects still needs empirical
    /// confirmation before this is relied on for anything real.
    func installBuiltIn(uri: String) async throws -> Addon {
        let response = try await GeckoEventDispatcherWrapper.runtimeInstance.query(
            type: "GeckoView:WebExtension:InstallBuiltIn",
            message: [
                "locationUri": uri,
            ]
        )
        guard let payload = response as? [String: Any?],
              let addonPayload = payload["extension"] as? [String: Any?] else {
            throw GeckoHandlerError("Invalid installBuiltIn response")
        }
        let addon = upsertAddon(from: addonPayload)
        delegate?.addonController(self, didUpdate: addon)
        return addon
    }
    
    func enable(_ addon: Addon, source: AddonEnableSource = .user) async throws -> Addon {
        try await mutateAddon(
            type: "GeckoView:WebExtension:Enable",
            message: ["webExtensionId": addon.id, "source": source.rawValue]
        )
    }
    
    func disable(_ addon: Addon, source: AddonEnableSource = .user) async throws -> Addon {
        try await mutateAddon(
            type: "GeckoView:WebExtension:Disable",
            message: ["webExtensionId": addon.id, "source": source.rawValue]
        )
    }
    
    func setAllowedInPrivateBrowsing(_ addon: Addon, allowed: Bool) async throws -> Addon {
        try await mutateAddon(
            type: "GeckoView:WebExtension:SetPBAllowed",
            message: ["extensionId": addon.id, "allowed": allowed]
        )
    }
    
    func addOptionalPermissions(_ request: AddonPermissionChangeRequest, to addon: Addon) async throws -> Addon {
        try await mutateAddon(
            type: "GeckoView:WebExtension:AddOptionalPermissions",
            message: [
                "extensionId": addon.id,
                "permissions": request.permissions,
                "origins": request.origins,
                "dataCollectionPermissions": request.dataCollectionPermissions,
            ]
        )
    }
    
    func removeOptionalPermissions(_ request: AddonPermissionChangeRequest, from addon: Addon) async throws -> Addon {
        try await mutateAddon(
            type: "GeckoView:WebExtension:RemoveOptionalPermissions",
            message: [
                "extensionId": addon.id,
                "permissions": request.permissions,
                "origins": request.origins,
                "dataCollectionPermissions": request.dataCollectionPermissions,
            ]
        )
    }
    
    func uninstall(_ addon: Addon) async throws {
        _ = try await GeckoEventDispatcherWrapper.runtimeInstance.query(
            type: "GeckoView:WebExtension:Uninstall",
            message: ["webExtensionId": addon.id]
        )
        if let removedAddon = removeAddon(byID: addon.id) {
            delegate?.addonController(self, didUpdate: removedAddon)
        }
    }
    
    func update(_ addon: Addon) async throws -> Addon? {
        let response = try await GeckoEventDispatcherWrapper.runtimeInstance.query(
            type: "GeckoView:WebExtension:Update",
            message: ["webExtensionId": addon.id]
        )
        guard let payload = response as? [String: Any?],
              let addonPayload = payload["extension"] as? [String: Any?] else {
            return nil
        }
        let updatedAddon = upsertAddon(from: addonPayload)
        delegate?.addonController(self, didUpdate: updatedAddon)
        return updatedAddon
    }
    
    func clickAction(kind: AddonActionKind, addon: Addon) async throws -> String? {
        let event = kind == .browser ? "GeckoView:BrowserAction:Click" : "GeckoView:PageAction:Click"
        let response = try await GeckoEventDispatcherWrapper.runtimeInstance.query(
            type: event,
            message: ["extensionId": addon.id]
        )
        return response as? String
    }
}

extension AddonRuntime {
    func mutateAddon(type: String, message: [String: Any?]) async throws -> Addon {
        let response = try await GeckoEventDispatcherWrapper.runtimeInstance.query(type: type, message: message)
        guard let payload = response as? [String: Any?],
              let addonPayload = payload["extension"] as? [String: Any?] else {
            throw GeckoHandlerError("Invalid extension response")
        }
        let updatedAddon = upsertAddon(from: addonPayload)
        delegate?.addonController(self, didUpdate: updatedAddon)
        return updatedAddon
    }
}
