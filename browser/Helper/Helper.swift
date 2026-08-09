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
	private static var heartbeatTimer: DispatchSourceTimer?
	// One bootstrap per process. Nothing here enforced that before: the
	// retained* arrays grew unboundedly, heartbeatTimer was overwritten
	// (which leaks the old timer rather than cancelling it - libdispatch
	// retains an active source), and childMain would run a second Gecko
	// init in the same process. Worse, the host invalidates a duplicate
	// incoming connection, which trips invalidationHandler below and takes
	// the whole process down - killing the healthy first child with it.
	private static var didBootstrap = false

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

		guard !didBootstrap else {
			throw NSError(
				domain: "Reynard.ProcessBootstrap",
				code: 3,
				userInfo: [NSLocalizedDescriptionKey: "Helper process has already bootstrapped"]
			)
		}
		// Latched on entry, not on success: a second childMain is destructive
		// whether or not the first attempt got that far.
		didBootstrap = true

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
		    _exit(EXIT_SUCCESS)
		}
		connection.invalidationHandler = {
		    NSLog("[ReynardHelper] XPC connection invalidated — exiting")
		    _exit(EXIT_SUCCESS)
		}
		connection.resume()

		// Bridging to libxpc is the only step in this function that can fail,
		// so it runs before anything with a lifetime attached to it. It used
		// to sit AFTER the heartbeat timer was created, resumed and stored:
		// on the throw path nothing cancelled the timer and nothing
		// invalidated the connection, and the timer's event handler captures
		// `connection` strongly - so a failed bootstrap left a live XPC
		// connection and a timer firing every 30s forever, in a process that
		// had just reported failure. Ordering it first removes the need for
		// any teardown code, which is better than adding some.
		guard let xpcConnection = XPCConnectionFromNSXPC(connection) else {
			// Clear the handlers before invalidating: invalidate() would
			// otherwise re-enter invalidationHandler and _exit before this
			// error ever reached beginRequest's cancelRequest(withError:).
			connection.interruptionHandler = nil
			connection.invalidationHandler = nil
			connection.invalidate()
			throw NSError(
				domain: "Reynard.ProcessBootstrap",
				code: 2,
				userInfo: [NSLocalizedDescriptionKey: "Failed to bridge NSXPCConnection to libxpc"]
			)
		}

		// WHAT THIS HEARTBEAT ACTUALLY GUARANTEES - less than the comment it
		// replaces claimed.
		//
		// ping() is one-way: ExtensionBootstrapPing declares only
		// -(void)ping with no reply block, and the host returns early on
		// every call after the first (mDidPing). A one-way send reaches this
		// error handler only when the connection is ALREADY known broken -
		// exactly what interruptionHandler/invalidationHandler above already
		// catch. A host that is suspended, hung, or silently gone accepts
		// queued messages without error, so this timer does NOT detect the
		// "alive and suspended well after its host was gone" case it was
		// originally written for. It is kept as a cheap backstop for the
		// narrow window where a send surfaces a dead port before either
		// handler has run.
		//
		// FOLLOW-UP, deliberately not done here: a real liveness check needs a
		// reply-with-deadline ping on BOTH sides. Changing only this side is
		// actively harmful - the selector becomes pingWithReply:, the host
		// exports an interface built from a protocol with no such method, the
		// send fails, and the helper kills itself on its first heartbeat 30
		// seconds into every session. Keep the wire format until the host
		// protocol changes with it.
		let heartbeatInterval: TimeInterval = 30
		let timer = DispatchSource.makeTimerSource(queue: .main)
		timer.schedule(deadline: .now() + heartbeatInterval, repeating: heartbeatInterval)
		timer.setEventHandler {
			guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in
				NSLog("[ReynardHelper] Heartbeat ping failed - connection already broken, exiting")
				_exit(EXIT_SUCCESS)
			}) as? BootstrapPing else {
				return
			}
			proxy.ping()
		}
		timer.resume()
		heartbeatTimer = timer

		retainedContexts.append(context)
		retainedProcesses.append(process)
		retainedConnections.append(connection)

		GeckoRuntime.childMain(xpcConnection: xpcConnection, process: process)

		// Not a courtesy. The host gates its launch completion on this exact
		// message - ExtensionBootstrapPingTarget.ping calls completeOnce(nil)
		// - with an 8-second dispatch_after fallback that fails the launch,
		// releases ExtensionProcess, and reaches _kill:9 through -dealloc ->
		// -invalidate. The previous `{ _ in }` swallowed a failed send, and
		// the trailing `?.` swallowed a nil proxy, so either one left the
		// helper idling silently until the host reaped it with nothing in the
		// log to say why.
		guard let bootstrapProxy = connection.remoteObjectProxyWithErrorHandler({ error in
			NSLog("[ReynardHelper] bootstrap ping failed, host launch will time out: \(error)")
			_exit(EXIT_FAILURE)
		}) as? BootstrapPing else {
			throw NSError(
				domain: "Reynard.ProcessBootstrap",
				code: 4,
				userInfo: [NSLocalizedDescriptionKey: "Bootstrap ping proxy unavailable"]
			)
		}
		bootstrapProxy.ping()
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

	// Gecko asks the child to seal its sandbox after bootstrap
	// (LockdownNSExtensionProcess -> lockdownSandbox:"1.0"). In the
	// NSExtension-based child path there is no public platform API to
	// tighten the sandbox further at runtime — that requires the
	// BrowserEngineKit extension types and the web-browser
	// entitlement. Until then, surface the request instead of silently
	// dropping it, so logs show whether lockdown was requested and
	// with which revision. NOTE: this is visibility, not enforcement —
	// the sandbox is NOT tightened here.
	open func lockdownSandbox(_ revision: String!) {
		NSLog("[ReynardHelper] lockdownSandbox(revision: \(revision ?? "nil")) requested — not enforced: no platform lockdown API in the NSExtension child path")
	}
}

@objc(ReynardHelperMain)
final class ReynardHelperMain: BrowserHelper {}
