//
//  Helper.swift
//  Reynard
//
//  Created by Minh Ton on 25/2/26.
//

import GeckoView
import Foundation

@objc private protocol BootstrapPing {
	func ping()
}

@MainActor
private final class ProcessBootstrap {
	private static var retainedConnections: [NSXPCConnection] = []
	private static var retainedContexts: [NSExtensionContext] = []
	private static var retainedProcesses: [any GeckoProcessExtension] = []

	static func start(
		context: NSExtensionContext,
		process: GeckoProcessExtension
	) throws {
		guard
			let input = context.inputItems.first as? NSExtensionItem,
			let userInfo = input.userInfo,
			let endpoint = userInfo["ReynardXPCListenerEndpoint"] as? NSXPCListenerEndpoint
		else {
			throw NSError(
				domain: "Reynard.ProcessBootstrap",
				code: 1,
				userInfo: [NSLocalizedDescriptionKey: "Missing NSXPC listener endpoint"]
			)
		}

		let connection = NSXPCConnection(listenerEndpoint: endpoint)
		connection.remoteObjectInterface = NSXPCInterface(with: BootstrapPing.self)
		connection.interruptionHandler = {
		    // The main app's end of this connection broke — it may
		    // have crashed, or explicitly torn this connection down.
		    // Previously this was a no-op, meaning this process would
		    // keep running indefinitely with no way to communicate
		    // back to anything. Nothing left for this process to
		    // usefully do at that point; exit rather than linger as
		    // dead weight competing for memory/CPU.
		    NSLog("[ReynardHelper] XPC connection interrupted — main app connection lost, exiting")
		    exit(EXIT_SUCCESS)
		}
		connection.invalidationHandler = {
		    NSLog("[ReynardHelper] XPC connection invalidated — exiting")
		    exit(EXIT_SUCCESS)
		}
		connection.resume()

		guard let xpcConnection = XPCConnectionFromNSXPC(connection) else {
			throw NSError(
				domain: "Reynard.ProcessBootstrap",
				code: 2,
				userInfo: [NSLocalizedDescriptionKey: "Failed to bridge NSXPCConnection to libxpc"]
			)
		}

		retainedContexts.append(context)
		retainedProcesses.append(process)
		retainedConnections.append(connection)

		GeckoRuntime.childMain(xpcConnection: xpcConnection, process: process)

		(connection.remoteObjectProxyWithErrorHandler({ _ in }) as? BootstrapPing)?.ping()
	}
}

open class BrowserHelper: NSObject, GeckoProcessExtension, NSExtensionRequestHandling {
	public required override init() {
		super.init()
	}

	open func beginRequest(with context: NSExtensionContext) {
		Task { @MainActor in
			do {
				try ProcessBootstrap.start(context: context, process: self)
			} catch {
				context.cancelRequest(withError: error)
			}
		}
	}

	open func lockdownSandbox(_ revision: String!) {}
}

@objc(ReynardHelperMain)
final class ReynardHelperMain: BrowserHelper {}
