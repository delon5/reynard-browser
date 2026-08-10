//
//  GeckoEventDispatcher.swift
//  Reynard
//
//  Created by Minh Ton on 1/2/26.
//

import Foundation

struct GeckoHandlerError: Error {
    let value: Any?
    
    init(_ value: Any?) {
        self.value = value
    }
}

protocol GeckoEventListenerInternal {
    @MainActor
    func handleMessage(type: String, message: [String: Any?]?) async throws -> Any?
}

extension GeckoEventListenerInternal {
    func handleMessage(type: String, message: [String: Any?]?, callback: EventCallback?) {
        Task { @MainActor in
            do {
                let result = try await self.handleMessage(type: type, message: message)
                callback?.sendSuccess(result)
            } catch let error as GeckoHandlerError {
                callback?.sendError(error.value)
            } catch {
                callback?.sendError("\(error)")
            }
        }
    }
}

public class GeckoEventDispatcherWrapper: NSObject, SwiftEventDispatcher {
    static var runtimeInstance = GeckoEventDispatcherWrapper()

    /// Named dispatchers, created on demand and kept for the process
    /// lifetime.
    ///
    /// Deliberately never pruned. The keys come from the engine's own
    /// EventDispatcher.byName() (Messaging.sys.mjs -> nsIOSBridge
    /// ::GetDispatcherByName -> `dispatcherByName:` here), which names a
    /// small, fixed set of modules rather than anything per-tab or
    /// per-session, so this cannot grow with usage. Each entry is also a
    /// long-lived endpoint the engine expects to resolve to the SAME
    /// object on every lookup - dropping one would silently detach any
    /// listener already registered against it.
    static var dispatchers: [String: GeckoEventDispatcherWrapper] = [:]
    
    struct QueuedMessage {
        let type: String
        let message: [String: Any?]?
        let callback: EventCallback?
    }
    
    var gecko: (any GeckoEventDispatcher)?
    var queue: [QueuedMessage]? = []
    var listeners: [String: [GeckoEventListenerInternal]] = [:]
    var name: String?

    /// Set when the engine called activate() before attach(). The old
    /// code discarded every queued message in that order - including a
    /// user's LoadUri - and permanently disabled queueing; attach() now
    /// flushes the held queue the moment the endpoint arrives.
    private var awaitingAttachFlush = false
    
    override init() {}
    
    init(name: String) {
        self.name = name
    }
    
    public static func lookup(byName: String) -> GeckoEventDispatcherWrapper {
        if let dispatcher = dispatchers[byName] {
            return dispatcher
        }
        let dispatcher = GeckoEventDispatcherWrapper(name: byName)
        dispatchers[byName] = dispatcher
        return dispatcher
    }
    
    func addListener(type: String, listener: GeckoEventListenerInternal) {
        listeners[type, default: []] += [listener]
    }
    
    /// How an outbound message left (or failed to leave) this
    /// dispatcher. GeckoView:LoadUri is fire-and-forget, so this
    /// disposition is the only record of whether a user's load ever
    /// reached the engine.
    enum DispatchDisposition: String {
        case handledLocally
        case queued
        case delivered
        case dropped
    }

    @discardableResult
    public func dispatch(
        type: String, message: [String: Any?]? = nil, callback: EventCallback? = nil
    ) -> DispatchDisposition {
        if let registeredListeners = listeners[type] {
            for listener in registeredListeners {
                listener.handleMessage(type: type, message: message, callback: callback)
            }
            return .handledLocally
        }
        if queue != nil {
            queue?.append(QueuedMessage(type: type, message: message, callback: callback))
            return .queued
        }
        guard let gecko else {
            // A detached endpoint used to swallow the message with no
            // trace anywhere - a dropped LoadUri is exactly "pressed Go
            // and nothing happened". Failing the callback also lets
            // query() error immediately instead of burning its full
            // timeout waiting for a reply that can never come.
            NSLog("[EventDispatcher] DROPPED %@ - no Gecko endpoint attached (name=%@)", type, name ?? "session")
            callback?.sendError("no gecko endpoint attached")
            return .dropped
        }
        gecko.dispatch(toGecko: type, message: message, callback: callback)
        return .delivered
    }
    
    /// Asks the content process a question and waits for its answer.
    ///
    /// - Parameter timeout: how long to wait before giving up. A query
    ///   that never gets an answer used to hang its caller forever: the
    ///   continuation is only resumed by the callback, and the callback
    ///   is owned by the content process, so a content actor that never
    ///   replies parks the awaiting task permanently.
    ///
    ///   That is not hypothetical. GetFocusedInputMetrics waits on a
    ///   double requestAnimationFrame in the child and on MozAfterPaint
    ///   in the parent; neither fires for a document that is not
    ///   painting, so on device the query never returned, the input
    ///   never lifted above the keyboard, and NOTHING was logged at
    ///   either end - the await simply never came back.
    ///
    ///   deinit's "callback never invoked" only covers the callback
    ///   being DEALLOCATED. A pending promise in content holds it alive,
    ///   which is exactly the case that hangs.
    public func query(
        type: String,
        message: [String: Any?]? = nil,
        timeout: TimeInterval = 5
    ) async throws -> Any? {
        // Resumes at most once, from whichever arrives first - the
        // engine's reply or the deadline. Both can land on different
        // threads, so the guard is a lock rather than a nil check.
        final class AsyncCallback: NSObject, EventCallback {
            private var continuation: CheckedContinuation<Any?, Error>?
            private let lock = NSLock()

            init(_ continuation: CheckedContinuation<Any?, Error>) {
                self.continuation = continuation
            }

            private func take() -> CheckedContinuation<Any?, Error>? {
                lock.lock()
                defer { lock.unlock() }
                let taken = continuation
                continuation = nil
                return taken
            }

            func sendSuccess(_ response: Any?) {
                take()?.resume(returning: response)
            }

            func sendError(_ response: Any?) {
                take()?.resume(throwing: GeckoHandlerError(response))
            }

            func timedOut(_ type: String) {
                guard let continuation = take() else {
                    return
                }
                NSLog("[EventDispatcher] %@ timed out - no reply from content", type)
                continuation.resume(throwing: GeckoHandlerError("timed out"))
            }

            deinit {
                take()?.resume(throwing: GeckoHandlerError("callback never invoked"))
            }
        }

        return try await withCheckedThrowingContinuation { continuation in
            let callback = AsyncCallback(continuation)
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak callback] in
                callback?.timedOut(type)
            }
            dispatch(type: type, message: message, callback: callback)
        }
    }
    
    public func attach(_ dispatcher: (any GeckoEventDispatcher)?) {
        gecko = dispatcher
        if let dispatcher, awaitingAttachFlush {
            awaitingAttachFlush = false
            NSLog("[EventDispatcher] attach() arrived after activate() - flushing deferred queue (name=%@)", name ?? "session")
            flush(to: dispatcher)
        }
    }
    
    public func dispatch(toSwift type: String!, message: Any!, callback: EventCallback?) {
        let typedMessage = message as? [String: Any?]
        if message != nil, typedMessage == nil {
            // The engine only ever sends a bundle (NSDictionary) or nil
            // here; anything else means a bridging bug on the Gecko
            // side. Drop it rather than crash the app over it.
            NSLog("[EventDispatcher] Dropping %@ — message is not a dictionary", type ?? "<nil type>")
            callback?.sendError("invalid message payload")
            return
        }
        if let registeredListeners = listeners[type] {
            for listener in registeredListeners {
                listener.handleMessage(type: type, message: typedMessage, callback: callback)
            }
        }
    }
    
    public func activate() {
        guard let gecko else {
            // The engine activated this endpoint before attaching its
            // native dispatcher. Nilling the queue here used to discard
            // every parked message - including a user's LoadUri - and
            // permanently disabled queueing for the session. Hold the
            // queue instead; attach() flushes it when the endpoint
            // arrives.
            awaitingAttachFlush = true
            NSLog("[EventDispatcher] activate() before attach - holding %d queued message(s) (name=%@)", queue?.count ?? 0, name ?? "session")
            return
        }
        flush(to: gecko)
    }

    private func flush(to endpoint: any GeckoEventDispatcher) {
        guard let queue = self.queue else {
            return
        }
        self.queue = nil
        for event in queue {
            endpoint.dispatch(toGecko: event.type, message: event.message, callback: event.callback)
        }
    }
    
    public func hasListener(_ type: String!) -> Bool {
        listeners.keys.contains(type)
    }
}
