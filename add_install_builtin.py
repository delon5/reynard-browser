import sys

path = "browser/GeckoView/Addons/AddonRuntimeCommands.swift"

with open(path, "r") as f:
    content = f.read()

old = '''    func install(url: String, installMethod: AddonInstallMethod? = nil) async throws -> Addon {
        installCounter += 1
        let response = try await GeckoEventDispatcherWrapper.runtimeInstance.query(
            type: "GeckoView:WebExtension:Install",
            message: [
                "locationUri": url,
                "installId": "reynard-\\(installCounter)",
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
    }'''
new = '''    func install(url: String, installMethod: AddonInstallMethod? = nil) async throws -> Addon {
        installCounter += 1
        let response = try await GeckoEventDispatcherWrapper.runtimeInstance.query(
            type: "GeckoView:WebExtension:Install",
            message: [
                "locationUri": url,
                "installId": "reynard-\\(installCounter)",
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
    }'''

count = content.count(old)
if count != 1:
    print(f"ERROR: expected 1 match, found {count}")
    sys.exit(1)
content = content.replace(old, new)

with open(path, "w") as f:
    f.write(content)

print("installBuiltIn method added successfully.")
