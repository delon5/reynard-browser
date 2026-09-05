//
//  AVPlayerHost.swift
//  Reynard
//
//  The embedder side of AVPlayerDecoder.
//
//  Lives in the GeckoView framework, not the app: MediaDecoder runs
//  in whichever Gecko process owns the media element - content
//  processes included - and every such process links this framework
//  and reaches this object through its own GeckoRuntimeImpl
//  .avPlayerHost. App-target placement would leave content
//  processes with no host at all.
//
//  stderr rather than the app's logger(): logger's implementation
//  (JITUtils.m) is app-target-only and does not link into this
//  framework - the exact linker failure GeckoRuntime.swift already
//  documents.
//
//  And stderr rather than NSLog, which is what this used to be.
//  Everything here runs in the CONTENT process, and the device capture
//  only picks up stderr from those - every NSLog-format line in a
//  capture carries the parent's pid, never a content pid. So none of
//  this file's output ever reached a log, and "did createPlayer even
//  run?" could not be answered from one: the C++ side would print
//  "avPlayer: Create()" and then nothing followed it, whether the
//  player was built or not. printf_stderr on that side lands fine, so
//  avLog matches its channel.
//
//  FairPlay forces this split: only AVURLAsset conforms to
//  AVContentKeyRecipient, so an AVContentKeySession can never be attached
//  to samples Gecko demuxed. AVFoundation has to own the URL from the
//  network down, and Gecko drives it from a distance.
//
//  Reached from C++ through GetSwiftRuntime(), the same way every other
//  Gecko-to-app call works here. Raw C symbols would not link, since
//  libxul is a framework and cannot leave undefined symbols pointing at
//  the app.
//
//  Besides pixels and metadata, this file reports the playback CLOCK to
//  Gecko - ReynardAVPlayerNotifyTime / ReynardAVPlayerNotifyEnded - which
//  is what lets the media element's currentTime advance, timeupdate fire,
//  and "ended" land at the stream's real end. See installClockReporting
//  and pushTime.
//

import AVFoundation
import Foundation
// CADisplayLink, which drives the frame pull below.
import QuartzCore

/// Unbuffered stderr, matching the C++ side's printf_stderr - see the
/// file comment for why this is not NSLog. Flushed every time: a
/// content process that is about to be killed still gets its last line
/// out, which is the case this logging exists to catch.
private func avLog(_ message: String) {
    fputs("avPlayer: \(message)\n", stderr)
    fflush(stderr)
}

@objc(ReynardAVPlayerHost)
public final class AVPlayerHost: NSObject {
    public static let shared = AVPlayerHost()

    /// Private: the C++ side reaches the one instance through
    /// GeckoRuntimeImpl.avPlayerHost, never by constructing another.
    /// The route and interruption observers are installed here rather
    /// than in createPlayer because the stall-detector grace they arm
    /// has to know the route BEFORE the first player exists - a route
    /// already on AirPlay when a tab starts playing is the ordinary
    /// case, not the edge case.
    private override init() {
        super.init()
        installAudioRouteObservers()
    }

    /// Players by opaque id. The decoder holds only the id, so a player
    /// outliving its decoder - or the reverse - cannot dereference
    /// anything freed.
    private var players: [UInt: Player] = [:]
    /// The player most recently handed a FairPlay licence, or 0.
    ///
    /// The compositor builds a layer for protected video knowing only
    /// that the surface was marked DRM - one bit, with no player id and
    /// no way to carry one, since a global IOSurface id does not resolve
    /// across processes on iOS. It does not need to: the compositor and
    /// this host share a process, so the id never crosses a boundary and
    /// this answers which player the layer belongs to.
    ///
    /// A licence rather than a key session, deliberately: every player
    /// has a session, only a protected one is ever given a CKC.
    private var lastProtectedPlayerId: UInt = 0
    /// AirPlay policy, pushed by the app (AirPlayPolicyController through
    /// the public setters below). Never read from Prefs here: this file
    /// is in the GeckoView framework, which cannot see the app's
    /// preference store, so the app decides and this host obeys. All
    /// guarded by stateLock.
    ///
    /// The global default is "allowed": with nothing pushed yet the
    /// ownership rule alone decides, which is the behaviour the
    /// kill switch defaults to as well.
    private var externalPlaybackAllowedGlobally = true
    private var fullscreenExternalPlayback = false
    private var detachesVideoOutputWhileExternal = false
    /// Whether the current AVAudioSession route has an .airPlay output.
    /// Written on the GCD main queue by the route-change observer and
    /// seeded from currentRoute at install; read by the stall detector
    /// on every display-link tick, which is exactly why it is cached -
    /// AVAudioSession is never queried from the tick. Guarded by
    /// stateLock.
    private var audioRouteIsAirPlay = false
    /// Set between an audio-session interruption's .began and .ended,
    /// so a pause that lands in between is remembered as the
    /// interruption's rather than the receiver's. Also cleared on
    /// AirPlay route loss, and never set by iOS 17's route-disconnect
    /// interruption, which has no .ended - see
    /// audioSessionInterruptionDidChange. Guarded by stateLock.
    private var audioInterruptionActive = false
    /// True while any player reports isExternalPlaybackActive.
    /// Recomputed under stateLock on every KVO edge and on destroy; the
    /// app reads it to keep the content process alive and PiP away
    /// while something is on the TV.
    public private(set) var isAnyExternalPlaybackActive = false
    /// Posted on the main queue with userInfo ["playerId": UInt,
    /// "active": Bool] on every external-playback edge, including the
    /// one destroy() implies.
    public static let externalPlaybackDidChange =
        Notification.Name("ReynardAVPlayerHost.ExternalPlaybackDidChange")
    /// Item-time grace the stall detector grants an eligible player
    /// before it will consider "no buffer" a DRM signal - see
    /// noteProtectedStall. One constant on purpose: a receiver that
    /// needs longer changes one number.
    private static let airPlayStallGraceSeconds: Double = 3.0
    /// How long after a receiver-attributed pause an interruption's
    /// .began still claims that pause as its own. See
    /// Player.lastReceiverPauseHostTime.
    private static let interruptionPauseAttributionSeconds: CFTimeInterval = 1.0
    /// Parser sessions already created, by session id. One per content
    /// process; see parserAppendInitData. Held here rather than asking
    /// FairPlayStreamParser, so the create is decided under this host's
    /// own lock and two init segments arriving together cannot both
    /// think they are first.
    private var parserSessions: Set<String> = []
    /// FPS application certificates by child id, for parser sessions.
    ///
    /// The per-player store cannot serve MSE: setAppCertificate(_:
    /// forPlayer:) looks a player up, an MSE child owns none, and the
    /// certificate was dropped for exactly the path that needed it.
    ///
    /// Kept here because the certificate and the init data race - the
    /// page sets the certificate while handling the 'encrypted' event
    /// that the key request produced - so whichever lands second applies
    /// it and neither order loses.
    private var parserCertificates: [UInt: Data] = [:]
    /// Layers bound by attachLayer, so destroy() can unbind them.
    ///
    /// Without this a destroyed player leaves layer.player pointing at it.
    /// Prime tears an element down and builds another mid-session - a
    /// capture caught player=1 and player=2 in one run - so the compositor
    /// can be left showing a layer bound to a player that no longer exists.
    private var attachedLayers: [UInt: AVPlayerLayer] = [:]
    /// ADDED - see fix_layer_attach_retries_on_licence.py's docstring.
    /// A protected layer handed over before any player was known to be
    /// protected, held until one is.
    ///
    /// The compositor builds the AVPlayerLayer as soon as the surface
    /// carries the DRM mark and offers it exactly once; the licence that
    /// resolves a player is a network round trip behind that, and a
    /// republish at the same geometry and mark no longer rebuilds the
    /// layer. Without this slot that one offer is dropped and the picture
    /// stays black for the whole title.
    ///
    /// One slot, most recent wins. A player draws into one layer at a
    /// time and protectedPlayerId() resolves exactly one player, so a
    /// queue would only bind layers that then unbind one another.
    private var pendingProtectedLayer: AVPlayerLayer?
    // Display link -> player id. Kept out of the Player so the link never
    // holds a strong reference back to the object whose lifetime it is
    // supposed to follow.
    private var frameLinkIDs: [ObjectIdentifier: UInt] = [:]
    private var nextID: UInt = 1
    /// Guards players, frameLinkIDs and nextID. They are reached from
    /// TWO different threads: every decoder entry point (createPlayer,
    /// destroy, play, seek, ...) runs on GECKO's main thread - which
    /// in a content process is a spawned thread, not the GCD main
    /// queue; see ReynardAVPlayerNotifyMetadata's comment in
    /// AVPlayerDecoder.mm for the capture that proved they differ -
    /// while pullFrames fires on the GCD main queue's display link.
    /// Swift dictionaries corrupt under concurrent read/write, so
    /// every touch of these maps goes through withState.
    private let stateLock = NSLock()

    private func withState<T>(_ body: () -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return body()
    }

    /// The AVContentKeySession the EME licence exchange is bound to,
    /// published by FairPlayCDMProxy the moment it creates one.
    ///
    /// Held weakly: the proxy owns it and tears it down with the page's
    /// MediaKeys, and a strong reference here would keep a dead session
    /// - and its delegate, which retains the proxy - alive for the
    /// process lifetime.
    ///
    /// Holds whatever publish landed last, so on the unpaired path this
    /// is the most RECENT session rather than one bound per decoder.
    /// That is a fallback now, not the limitation it once was:
    /// MediaDecoder::SetCDMProxy is virtual, AVPlayerDecoder overrides
    /// it to name the player it owns, and
    /// FairPlayCDMProxy::PublishKeySessionIfBound hands that player to
    /// useContentKeySession(_:forPlayer:) below for an exact pairing.
    /// The unpaired value therefore only decides anything when nothing
    /// ever binds - and with a single protected element playing it is
    /// the same pairing regardless.
    private weak var emeContentKeySession: AVContentKeySession?

    // MARK: - Called from FairPlayCDMProxy

    /// Publishes the session the EME key exchange runs on, so assets
    /// created here can be registered as recipients of it.
    @objc public func useContentKeySession(_ session: AVContentKeySession) {
        emeContentKeySession = session
        avLog("EME published a content key session")

        // Re-register anything already created. There is no ordering
        // guarantee between the page setting src (which reaches
        // createPlayer) and its EME handshake reaching
        // FairPlayCDMProxy::Init, and a player made first was registered
        // on the local no-licence session - which never receives a key,
        // so the asset stays encrypted no matter how correct the rest of
        // the exchange is. FairPlay only decrypts an asset registered as
        // a recipient of the SAME session the keys arrive on.
        //
        // addContentKeyRecipient is idempotent per session, so the
        // already-correct case costs nothing.
        let existing = withState { Array(players.values) }
        for entry in existing where entry.keySession !== session {
            // Off the licence-less fallback FIRST. An asset registered
            // on two sessions can have its key request routed to either,
            // and the fallback's delegate fails every request by design
            // - so leaving the old registration in place can kill the
            // item even though the EME session is perfectly bound.
            entry.keySession.removeContentKeyRecipient(entry.asset)
            session.addContentKeyRecipient(entry.asset)
            entry.keySession = session
            avLog("re-registered an existing asset on the EME key session")
        }
    }

    /// The paired form: these keys are for THIS player.
    ///
    /// FairPlay decrypts only an asset registered on the same session
    /// its licence arrived on, so with two protected elements the
    /// unpaired call above can hand the second one's asset to the first
    /// one's session. AVPlayerDecoder::SetCDMProxy names the player it
    /// owns, FairPlayCDMProxy forwards it here, and the registration is
    /// exact. Callable in either order relative to createPlayer: the
    /// proxy waits until it has both halves.
    @objc public func useContentKeySession(_ session: AVContentKeySession,
                                           forPlayer playerId: UInt) {
        emeContentKeySession = session
        guard let entry = withState({ players[playerId] }) else {
            avLog("EME key session for player \(playerId), which does not exist yet")
            return
        }
        if entry.keySession !== session {
            // Same rule as the unpaired path: never leave the asset
            // registered on the fallback session as well.
            entry.keySession.removeContentKeyRecipient(entry.asset)
        }
        session.addContentKeyRecipient(entry.asset)
        entry.keySession = session
        avLog("EME key session bound to player \(playerId)")
    }

    // MARK: - FairPlay, relayed from the content process

    /// The FPS application certificate, from the page's
    /// setServerCertificate. Until this arrives there is no SPC to
    /// make, so the delegate holds every key request it has raised.
    @objc public func setAppCertificate(_ certificate: Data,
                                        forPlayer playerId: UInt) {
        guard let delegate = withState({ players[playerId]?.delegate }) else {
            avLog("app certificate for player \(playerId), which has no "
                  + "delegate of ours")
            return
        }
        delegate.setAppCertificate(certificate)
    }

    /// generateRequest(): produce an SPC covering this identifier.
    @objc public func generateKeyRequest(_ playerId: UInt,
                                         contentId: String,
                                         initDataType: String,
                                         initData: Data) {
        guard let entry = withState({ players[playerId] }),
              let delegate = entry.delegate else {
            avLog("generateRequest for player \(playerId), which has no "
                  + "delegate of ours")
            return
        }
        delegate.generateRequest(contentId: contentId,
                                 initDataType: initDataType,
                                 initData: initData,
                                 session: entry.keySession)
    }

    /// update(): the CKC from the page's licence server.
    @objc public func provideKeyResponse(_ playerId: UInt,
                                         contentId: String,
                                         response: Data) {
        guard let delegate = withState({ players[playerId]?.delegate }) else {
            avLog("CKC for player \(playerId), which has no delegate of ours")
            return
        }
        withState { lastProtectedPlayerId = playerId }
        delegate.provideResponse(response, contentId: contentId)
        // ADDED - see fix_layer_attach_retries_on_licence.py's docstring.
        // The assignment above is the first moment protectedPlayerId()
        // answers anything but 0, and the compositor asked its one
        // question a licence round trip ago. Bind what it left stashed.
        drainPendingProtectedLayer()
    }

    /// The player a protected layer should bind to, or 0 if none.
    @objc public func protectedPlayerId() -> UInt {
        withState { lastProtectedPlayerId }
    }

    // MARK: - MSE FairPlay, via the stream parser

    /// MSE init data, on its way to a key request that has no player.
    ///
    /// Everything else here is keyed by player id, because a player is
    /// what AVFoundation owns a URL for. MSE has no URL and so no player,
    /// which is the entire problem: FairPlayCDMProxy parked every
    /// generateRequest because BindToPlayer never ran, and a device
    /// capture counted four parked against zero replayed. This routes
    /// those bytes to FairPlayStreamParser, which originates key requests
    /// from an init segment with no asset anywhere - measured on device,
    /// not assumed.
    ///
    /// Keyed by CHILD id, not player id, for two reasons. The broker
    /// reserves player id 0 for "no player" already, so an MSE request
    /// arrives with the player half of its composite key zeroed and the
    /// child half intact. And the application certificate is delivered
    /// per child, so one parser session per content process is the
    /// coarsest scope the certificate path can still serve.
    ///
    /// The SPC return leg is deliberately not here yet. It needs a
    /// per-child certificate store this host does not have - certificates
    /// currently live on a player's delegate - and an owner actor that
    /// ContentParent only records at AVPlayerCreate, which never runs for
    /// MSE. Both are real work; this slice proves the bytes arrive first.
    @objc public func parserAppendInitData(_ childId: UInt,
                                           contentId: String,
                                           initData: Data) {
        let sessionId = "child-\(childId)"
        let parser = FairPlayStreamParser.shared
        if withState({ parserSessions.insert(sessionId).inserted }) {
            guard parser.createSession(sessionId) else {
                withState { _ = parserSessions.remove(sessionId) }
                return
            }
            // A certificate that arrived before any init data, applied
            // now rather than lost.
            if let stored = withState({ parserCertificates[childId] }) {
                parser.setCertificate(sessionId, certificate: stored)
            }
        }
        avLog("parser init data for child \(childId), id \(contentId), "
              + "\(initData.count) bytes")
        // Two routes, because the bytes decide which one can work, and
        // only one of them has ever been observed to.
        //
        // The append is kept for the case this file was written for: a
        // real fMP4 init segment, ftyp/moov carrying sinf, which the
        // parser does originate a key request from. What arrives today
        // is an EME PSSH - "type=cenc 104 bytes" in the capture - and
        // the parser ignores one in silence, so an append alone leaves
        // the page waiting forever.
        //
        // The direct call is what carries this path: the same bytes to
        // the SESSION, which takes initialisation data rather than a
        // parsed track and raises a request that can make an SPC.
        //
        // The append's answer is a HOST-side precondition, not a parse
        // result, and saying otherwise here was wrong: append() returns
        // false only for an unknown session or a missing
        // appendStreamData:, and true the moment the bytes are handed
        // over. perform() discards whatever the parser makes of them, so
        // a parser that silently ignores a PSSH - the entire reason this
        // route exists - still returns true.
        //
        // Worth reading anyway, because false means the SPI is gone and
        // that is a real thing to know. What it can never mean is that
        // the parser looked at the bytes and declined them; the only
        // report of that is didFailToParseStreamDataWithError, on the
        // delegate.
        if !parser.append(sessionId, initSegment: initData) {
            avLog("parser has no appendStreamData: for child \(childId) - "
                  + "the OS moved, and only the direct key request below "
                  + "can still work")
        }
        parser.requestKey(sessionId, contentId: contentId, initData: initData)
    }

    /// The page's FPS application certificate, for a child's parser
    /// session. The MSE counterpart of setAppCertificate(_:forPlayer:).
    /// A fragmented-MP4 init segment the page appended, handed to the
    /// parser so it can raise a key request the way it actually does.
    ///
    /// ADDED - see fix_forward_init_segment_to_parser.py's docstring.
    /// Deliberately does NOT call requestKey. The session resolves a
    /// requirement a recipient has raised rather than originating one,
    /// so the direct call produced no request across two builds; what
    /// should fire here is the parser's own
    /// didProvideContentKeySpecifier, which processSpecifier already
    /// handles and which is the only path that has produced an SPC on
    /// this device.
    @objc public func parserAppendMediaSegment(_ childId: UInt,
                                               stream: String,
                                               segment: Data) {
        let sessionId = "child-\(childId)"
        let parser = FairPlayStreamParser.shared
        if withState({ parserSessions.insert(sessionId).inserted }) {
            guard parser.createSession(sessionId) else {
                withState { _ = parserSessions.remove(sessionId) }
                return
            }
            if let stored = withState({ parserCertificates[childId] }) {
                parser.setCertificate(sessionId, certificate: stored)
            }
        }
        avLog("parser segment for child \(childId) stream \(stream), "
              + "\(segment.count) bytes")
        // Routed to the parser for THIS SourceBuffer. One parser per
        // stream: a page's audio and video are separate presentations,
        // and one AVStreamDataParser fed both ends up -11853 and stays
        // failed for good.
        if !parser.append(sessionId, stream: stream, segment: segment) {
            avLog("parser declined the segment for child \(childId) "
                  + "stream \(stream)")
        }
    }

    /// That SourceBuffer has ended.
    ///
    /// ADDED - see mse_fix_99's docstring. No session is created here
    /// and none is looked up: a retire for a stream that was never built
    /// is the ordinary case, not an error - Netflix makes nine
    /// SourceBuffers to probe codec support and appends to none of them.
    @objc public func parserRetireStream(_ childId: UInt, stream: String) {
        let sessionId = "child-\(childId)"
        avLog("retire for child \(childId) stream \(stream)")
        FairPlayStreamParser.shared.retireStream(sessionId, stream: stream)
    }

    /// The element's play state, for this child's parser session.
    ///
    /// Straight through: the parser holds this per session and applies
    /// it to whatever streams exist, because play() can arrive before
    /// the certificate that builds a session at all. No session is
    /// created here for the same reason - a play state on its own is
    /// not a reason to build a parser.
    @objc public func parserSetPlaying(_ childId: UInt, owner: UInt64,
                                       playing: Bool) {
        avLog("play state for child \(childId) -> "
              + (playing ? "playing" : "paused"))
        FairPlayStreamParser.shared.setSessionPlaying("child-\(childId)",
                                                      owner: owner,
                                                      playing: playing)
    }

    /// Which element a SourceBuffer belongs to.
    ///
    /// ADDED - see mse_fix_101's docstring. No session is built here: an
    /// owner for a stream that does not exist yet is ordinary, and the
    /// parser keeps it against the key either way.
    /// Where that element is playing.
    ///
    /// ADDED - see mse_fix_102's docstring. Not logged here: four a
    /// second per element would bury everything else, and the parser
    /// says something only when it acts on one.
    @objc public func parserSetPosition(_ childId: UInt, owner: UInt64,
                                        seconds: Double) {
        FairPlayStreamParser.shared.setPosition("child-\(childId)",
                                                owner: owner,
                                                seconds: seconds)
    }

    @objc public func parserSetStreamOwner(_ childId: UInt, stream: String,
                                           owner: UInt64, offset: Double) {
        FairPlayStreamParser.shared.setStreamOwner("child-\(childId)",
                                                   stream: stream,
                                                   owner: owner,
                                                   offset: offset)
    }

    /// The element's volume, for this child's parser session.
    @objc public func parserSetVolume(_ childId: UInt, owner: UInt64,
                                      volume: Double) {
        avLog("volume for child \(childId) element \(owner) -> \(volume)")
        FairPlayStreamParser.shared.setSessionVolume("child-\(childId)",
                                                     owner: owner,
                                                     volume: volume)
    }

    @objc public func parserSetCertificate(_ childId: UInt,
                                           certificate: Data) {
        withState { parserCertificates[childId] = certificate }
        avLog("parser certificate for child \(childId), "
              + "\(certificate.count) bytes")
        // Applied to a session already built. If none exists yet the
        // store above covers it, and parserAppendInitData applies it at
        // creation.
        FairPlayStreamParser.shared.setCertificate("child-\(childId)",
                                                   certificate: certificate)
    }

    /// update(): the CKC from the page's licence server, for a parser
    /// session. The MSE counterpart of provideKeyResponse(_:contentId:
    /// response:).
    @objc public func parserProvideKeyResponse(_ childId: UInt,
                                               contentId: String,
                                               response: Data) {
        avLog("parser CKC for child \(childId), \(response.count) bytes")
        // The content id is the correlation key, and it was being
        // dropped here: one session serves the whole child, so without
        // it the licence lands on whichever request happened to be
        // armed - and with two exchanges in flight that is provably the
        // wrong one, with the second CKC discarded outright.
        let applied = FairPlayStreamParser.shared
            .provideResponse("child-\(childId)", contentId: contentId,
                             ckc: response)
        if !applied {
            // Said out loud rather than dropped. A licence that cannot be
            // applied leaves the page believing playback is about to
            // start, and silence here is what made the last one
            // untraceable.
            avLog("parser CKC for child \(childId) was NOT applied")
        }
    }

    @objc public func parserDestroySession(_ childId: UInt) {
        let sessionId = "child-\(childId)"
        guard withState({ parserSessions.remove(sessionId) != nil }) else {
            return
        }
        FairPlayStreamParser.shared.destroySession(sessionId)
    }

    /// DIAGNOSTIC + likely fix for "play() ignored": the AVPlayer runs
    /// in a content-process extension, and iOS media services refuse to
    /// start a playback timebase for a process with no active playback
    /// audio session - play() then lands straight back in .paused with
    /// no error surfaced anywhere. Decode still works (frames vend), so
    /// the only symptom is rate=0/timeControl=0 right after play().
    /// Attempted once per process, both outcomes logged. If activation
    /// FAILS here, playback cannot run in this process at all, and the
    /// player has to move to (or be brokered by) the app process.
    private static var audioSessionConfigured = false
    private static func ensurePlaybackAudioSession() {
        guard !audioSessionConfigured else { return }
        audioSessionConfigured = true
        let session = AVAudioSession.sharedInstance()

        // A ladder, not a single attempt. iOS returned '!pla'
        // (AVAudioSessionErrorCodeCannotStartPlaying) for the exclusive
        // playback session below, which is the usual answer for a
        // process not permitted to take the audio focus - a content
        // extension. A MIXABLE or ambient session asks for no focus and
        // is frequently granted to the very same process. If one of
        // these activates, playback may sustain in-process and no
        // app-process brokering is needed.
        let candidates: [(String, AVAudioSession.Category, AVAudioSession.Mode,
                          AVAudioSession.CategoryOptions)] = [
            ("playback/moviePlayback", .playback, .moviePlayback, []),
            ("playback/moviePlayback+mix", .playback, .moviePlayback, [.mixWithOthers]),
            ("ambient/default+mix", .ambient, .default, [.mixWithOthers]),
            ("soloAmbient/default", .soloAmbient, .default, []),
        ]
        var activated = false
        for (name, category, mode, options) in candidates {
            do {
                try session.setCategory(category, mode: mode, options: options)
                try session.setActive(true)
                avLog("audio session ACTIVATED: \(name)")
                activated = true
                break
            } catch {
                avLog("audio session \(name) refused: \(error)")
            }
        }
        if !activated {
            avLog("audio session: NO category could be activated - playback "
                  + "must move to the app process")
        }
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: session,
            queue: .main
        ) { note in
            avLog("audio session INTERRUPTION: \(note.userInfo ?? [:])")
        }
    }

    /// PROBE - see fix_avplayer_silent_playback_probe.py. Set false to
    /// restore audio once the question is answered.
    // OFF. The probe answered its question - with audio tracks disabled
    // the player still reached only .waitingToPlayAtSpecifiedRate, one
    // frame, then .paused - and every audio-session category was refused
    // to this process, so the restriction was never about audio. Leaving
    // it on now only hides the win condition: with the player brokered
    // into the app process, SOUND is the fastest proof that playback
    // sustains somewhere iOS permits, and it needs no log at all.
    private static let kSilentPlaybackProbe = false

    /// Disables every audio track on a ready item, then re-issues play.
    ///
    /// iOS refused playback to this process with '!pla'
    /// (AVAudioSessionErrorCodeCannotStartPlaying): a content-process
    /// extension cannot activate a playback audio session, and an item
    /// that wants to render audio therefore never starts - play() lands
    /// straight back in .paused. Muting does not help, because the item
    /// still has an audio track to render. Removing the track from the
    /// equation entirely is the test: if the player then runs, video is
    /// available in-process today and only sound needs brokering to the
    /// app process.
    private func probeSilentPlayback(_ entry: Player, _ id: UInt) {
        guard Self.kSilentPlaybackProbe else { return }
        let alreadyDone = withState { () -> Bool in
            if entry.silentProbeDone { return true }
            entry.silentProbeDone = true
            return false
        }
        guard !alreadyDone else { return }

        var audioTracks = 0
        for track in entry.item.tracks where track.assetTrack?.mediaType == .audio {
            track.isEnabled = false
            audioTracks += 1
        }
        avLog("silentProbe[\(id)] disabled \(audioTracks) audio of "
              + "\(entry.item.tracks.count) track(s)"
              + " timeControl=\(entry.player.timeControlStatus.rawValue)")

        // play() was already issued (and ignored) before the tracks
        // existed, so it has to be re-issued now that they are gone.
        guard withState({ entry.wantsPlayback }) else {
            avLog("silentProbe[\(id)] element does not want playback - not retrying")
            return
        }
        resumeFrameDelivery(for: entry)
        entry.player.play()
        avLog("silentProbe[\(id)] play() re-issued without audio tracks")
    }

    private final class Player {
        let player: AVPlayer
        let item: AVPlayerItem
        let asset: AVURLAsset
        // var, not let: the EME publish paths re-bind the asset onto the
        // session the licence actually arrives on, and destroy() must
        // clean whichever session the asset is CURRENTLY registered to.
        var keySession: AVContentKeySession
        let delegate: ContentKeyDelegate?
        var observers: [NSKeyValueObservation] = []
        // Last values handed to the decoder, so an unchanged repeat is
        // dropped. Three observations fire for one resolution, and each
        // republish allocates and fills a fresh IOSurface - a device
        // capture showed four identical 400x300 publishes for a single
        // load.
        var reportedDuration: Double?
        var reportedSize: CGSize?
        /// Whether the element wants to be playing, as opposed to whether
        /// AVPlayer currently is. The two diverge because play() arrives
        /// before the item is ready; see resumeIfWanted in observeItem.
        /// Guarded by stateLock - written from Gecko's main thread and
        /// read from the GCD main queue.
        var wantsPlayback = false

        // Pulls decoded frames back out of AVFoundation so Gecko can
        // composite them itself. Without this the decoder had nothing to
        // show but the synthetic placeholder: AVPlayer decodes into its
        // own layer, and a layer Gecko does not own cannot take part in
        // its scene graph.
        //
        // IOSurface-backed deliberately. MacIOSurfaceImage wraps an
        // IOSurface, so the very surface AVFoundation decoded into
        // reaches the compositor with no copy. NV12 video-range is what
        // MacIOSurfaceTextureHostOGL expects for a two-plane surface -
        // the same format the placeholder builds, and it hard-requires
        // exactly two planes.
        let videoOutput = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String:
                Int(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
            // IOSurfaceIsGlobal, so the surface AVFoundation decodes
            // into can be found by IOSurfaceLookup in ANOTHER process.
            // The player runs here in the app process while the decoder
            // that publishes frames runs in a content process, and
            // Gecko's only cross-process handle for a surface is its
            // global id - it sets exactly this key on every surface it
            // creates itself, see MacIOSurface::CreateBiPlanarSurface.
            //
            // Deprecated by Apple and honoured anyway. If a future iOS
            // stops honouring it the decoder notices the lookup it
            // cannot satisfy and asks this process to copy into a
            // surface Gecko made instead, so this is an optimisation
            // rather than a requirement.
            kCVPixelBufferIOSurfacePropertiesKey as String: [
                "IOSurfaceIsGlobal": true,
            ] as [String: Any] as CFDictionary,
        ])
        var displayLink: CADisplayLink?
        /// Diagnostics for the pull loop - see pullFrames.
        var pullTicks: UInt64 = 0
        var reportedFirstPull = false
        /// Consecutive ticks that delivered nothing while the player was
        /// PAUSED - drives the auto-repause in pullFrames. Deliberately
        /// not counted while rebuffering (.waitingToPlayAtSpecifiedRate):
        /// nothing would unpark the link when the stall clears.
        /// Guarded by stateLock, like wantsPlayback.
        var idlePullTicks: Int = 0
        /// Item time when the output last handed over a pixel buffer, and
        /// whether we have already told Gecko this stream is protected.
        /// See noteProtectedStall.
        var lastBufferItemTime: Double = -1
        var reportedProtected = false
        /// The last reason noteProtectedStall declined to report, so
        /// the log can be edge-triggered rather than per-tick.
        ///
        /// ADDED - see fix_stall_detector_says_why.py's docstring.
        /// The detector runs at display-link rate; a line per call
        /// would bury the answer it exists to surface. A line per
        /// CHANGE is one per state transition.
        var lastStallReason: String = ""
        /// Desired park state for the pull link. Guarded by stateLock -
        /// written from Gecko's main thread (pause, suspend) and from
        /// the GCD main queue (the idle backstop, the readiness replay).
        /// CADisplayLink.isPaused itself is only ever touched on the
        /// GCD main queue; see setPullParked.
        var pullParked = false

        /// Token from addPeriodicTimeObserver; AVFoundation requires it
        /// handed back to removeTimeObserver before the player is
        /// released. See installClockReporting / destroy.
        var timeObserverToken: Any?
        /// Block-based AVPlayerItemDidPlayToEndTime observation; removed
        /// explicitly in destroy - a block observer outlives the item
        /// unless removed.
        var endObserver: NSObjectProtocol?
        /// Last position handed to Gecko, for pushTime's delta filter.
        /// Guarded by stateLock - written from the display link, the
        /// periodic observer and seek completions.
        var lastPushedTime: Double?
        /// One-shot guard for the silent-playback probe. Guarded by
        /// stateLock.
        var silentProbeDone = false
        /// One-shot diagnostic - see the muted retry in pullFrames.
        /// Guarded by stateLock.
        var mutedRetryDone = false

        /// Mirror of AVPlayer.isExternalPlaybackActive, written on the
        /// GCD main queue by the KVO installed in observeExternalPlayback.
        /// Guarded by stateLock so the policy setters, the ownership rule
        /// and destroy can read it off any thread. The stall detector
        /// deliberately does NOT rely on this mirror - see
        /// noteProtectedStall, which reads the player directly.
        var externalActive = false
        /// Whether play(id) made this the one player allowed to go
        /// external - see applyExternalPlaybackOwner for why
        /// AVFoundation's default (every player allowed) is the wrong
        /// answer for a browser. Guarded by stateLock.
        var isExternalOwner = false
        /// The page said x-webkit-airplay="deny" or one of its siblings.
        /// Pushed by setExternalPlayback(_:allowed:) once the engine
        /// carries opcode 7. Guarded by stateLock.
        var deniedByElement = false
        /// Item time at which the stall detector first saw this player
        /// ELIGIBLE to go external (allowsExternalPlayback on an AirPlay
        /// route), or -1 for "start counting at the next observed tick".
        /// Reset to -1 on every edge that (re)asserts eligibility - the
        /// route observer, the policy flip, the paused -> playing edge
        /// in play(id) - on the external->local edge, and by seek(_:to:)
        /// in either direction. Guarded by stateLock.
        var externalEligibleSinceItemTime: Double = -1
        /// The detach fallback removed videoOutput from the item, so the
        /// external->local edge has something to put back. Main queue
        /// only, like the output itself.
        var videoOutputDetached = false
        /// suspend() paused this player, so the timeControlStatus
        /// observer must not read that pause as the Siri Remote's.
        /// Guarded by stateLock.
        var suspended = false
        /// Last SETTLED timeControlStatus - .waitingToPlayAtSpecifiedRate
        /// is never recorded - so the observer can tell a .playing ->
        /// .paused edge (the receiver, or an interruption, even one that
        /// lands mid-rebuffer) from the readiness replay, which reads as
        /// .paused -> .paused. Guarded by stateLock.
        var lastTimeControl: AVPlayer.TimeControlStatus = .paused
        /// Set at an audio-session interruption's .began for a player
        /// that was playing externally, so .ended + .shouldResume can
        /// put it back - wantsPlayback alone cannot say, because the
        /// pause AVFoundation applies for the interruption reaches
        /// timeControlStatusDidChange looking exactly like the receiver's
        /// and clears it. Guarded by stateLock.
        var resumeAfterInterruption = false
        /// Host time of the last pause timeControlStatusDidChange
        /// attributed to the receiver, or -1. Lets an interruption's
        /// .began recognise a pause that landed on the main queue a
        /// moment BEFORE the notification did - the two arrive from
        /// different queues and nothing orders them. Guarded by
        /// stateLock.
        var lastReceiverPauseHostTime: CFTimeInterval = -1

        init(player: AVPlayer, item: AVPlayerItem, asset: AVURLAsset,
             keySession: AVContentKeySession, delegate: ContentKeyDelegate?) {
            self.player = player
            self.item = item
            self.asset = asset
            self.keySession = keySession
            self.delegate = delegate
        }

        deinit {
            // Invalidate releases the display link's strong reference to
            // its target. Without it the link keeps this Player alive and
            // keeps firing against a destroyed item.
            displayLink?.invalidate()
        }
    }

    // MARK: - Called from AVPlayerDecoder

    /// Returns 0 on failure, which the decoder treats as a load error.
    @objc public func createPlayer(url: String) -> UInt {
        guard let parsed = URL(string: url) else {
            avLog("could not parse \(url)")
            return 0
        }

        let asset = AVURLAsset(url: parsed)

        // The whole reason this pipeline exists. addContentKeyRecipient
        // accepts AVURLAsset and nothing else, which is why Gecko's own
        // decoders can never be given FairPlay keys.
        //
        // Prefer the session the EME exchange is bound to, published by
        // FairPlayCDMProxy through useContentKeySession(_:). Its keys
        // only decrypt assets registered on THAT session - a session we
        // made here holds none of them, however correctly configured.
        //
        // The locally-created fallback is for plain HLS reaching this
        // decoder with no EME involved: it never receives a licence, so
        // its delegate just reports the request and fails it, which is
        // the same behaviour as before this pipeline knew about EME.
        // The id is allocated FIRST: the key session's delegate is
        // per player and carries the id in every message it sends
        // Gecko, so it cannot be built after the entry is.
        let id = withState { () -> UInt in
            let allocated = nextID
            nextID += 1
            return allocated
        }

        // The key session is PER PLAYER and lives HERE, in the app
        // process, because addContentKeyRecipient takes an AVURLAsset
        // and this is where the asset is.
        //
        // useContentKeySession(_:) below only ever worked when
        // FairPlayCDMProxy ran in the same process, which it does not:
        // the proxy lives wherever the media element does - a content
        // process - so its publish set emeContentKeySession on the
        // CONTENT process's host instance while every asset was
        // created on this one. Every player therefore fell through to
        // the licence-less local session, which is why FairPlay
        // reached "key status: usable" and the item still failed with
        // Code=-1. Gecko's EME objects now reach this session over
        // PContent instead; see ContentKeyDelegate.
        //
        // The publish is still honoured when it does arrive - a
        // single-process build has the proxy right here - so nothing
        // that used to work stops.
        let keySession: AVContentKeySession
        let delegate: ContentKeyDelegate?
        if let published = emeContentKeySession {
            keySession = published
            delegate = nil
            avLog("using the EME-published content key session")
        } else {
            let owned = AVContentKeySession(keySystem: .fairPlayStreaming)
            let ownedDelegate = ContentKeyDelegate(playerId: id)
            owned.setDelegate(ownedDelegate, queue: .main)
            keySession = owned
            delegate = ownedDelegate
            avLog("content key session created for player \(id)")
        }
        keySession.addContentKeyRecipient(asset)

        Self.ensurePlaybackAudioSession()

        let item = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: item)
        player.automaticallyWaitsToMinimizeStalling = true
        // AVFoundation defaults allowsExternalPlayback to YES. In a
        // browser every preloading tab would then compete for the
        // receiver the moment the route is AirPlay; play(id) hands the
        // flag to exactly one player instead (applyExternalPlaybackOwner).
        // Off until then, so a player that never plays never goes
        // external.
        player.allowsExternalPlayback = false
        // WebKit's updateDisableExternalPlayback: under screen mirroring
        // an AVPlayer keeps rendering locally (and is mirrored at
        // mirroring quality) unless this is set, and WebKit sets it only
        // in fullscreen. The app pushes the fullscreen state through
        // setFullscreenExternalPlaybackPolicy; this is the value for a
        // player created mid-fullscreen.
        player.usesExternalPlaybackWhileExternalScreenIsActive =
            withState { fullscreenExternalPlayback }
        player.externalPlaybackVideoGravity = .resizeAspect

        let entry = Player(player: player, item: item, asset: asset,
                           keySession: keySession, delegate: delegate)
        withState { players[id] = entry }

        observeMetadata(of: item, playerId: id, storingInto: entry)
        observeExternalPlayback(of: player, playerId: id, storingInto: entry)
        startFrameDelivery(for: id)
        installClockReporting(for: id, entry: entry)

        avLog("created \(id) for \(parsed.absoluteString)")
        return id
    }

    /// Reports a playback position to Gecko, from whichever thread the
    /// caller is on - ReynardAVPlayerNotifyTime is documented
    /// any-thread, and lands the value in a lock-protected registry.
    /// The delta filter below is what keeps a 120 Hz display link from
    /// becoming 120 Hz of registry traffic for a clock that moved less
    /// than perceptibly.
    private func pushTime(_ id: UInt, _ entry: Player, _ seconds: Double) {
        guard seconds.isFinite else {
            return
        }
        let clamped = max(seconds, 0)
        let shouldPush = withState { () -> Bool in
            if let last = entry.lastPushedTime, abs(clamped - last) < 0.010 {
                return false
            }
            entry.lastPushedTime = clamped
            return true
        }
        guard shouldPush else {
            return
        }
        ReynardAVPlayerNotifyTime(id, clamped)
    }

    /// The Gecko side's media clock follows the positions pushed from
    /// here - AVPlayerDemuxer paces its synthetic samples against them.
    /// Two sources cover each other: the display-link pull loop reports
    /// on every tick while frames flow, and the periodic observer keeps
    /// reporting when the link is parked (idle backstop, audio-only
    /// renditions). Both funnel through pushTime's delta filter. The
    /// end-of-stream notification is what lets the element fire "ended"
    /// at the stream's real end.
    private func installClockReporting(for id: UInt, entry: Player) {
        entry.timeObserverToken = entry.player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 4),
            queue: .main
        ) { [weak self] time in
            // The entry is re-fetched rather than captured: the player
            // retains this closure, and a captured entry would retain
            // the player right back - the same cycle discipline as
            // frameLinkIDs.
            guard let self,
                  let entry = self.withState({ self.players[id] }),
                  time.isValid, time.isNumeric else {
                return
            }
            self.pushTime(id, entry, time.seconds)
        }

        entry.endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: entry.item,
            queue: .main
        ) { _ in
            // The id is a value; nothing is retained. Gecko's registry
            // drops the flag if the player is already gone.
            avLog("played to end \(id)")
            ReynardAVPlayerNotifyEnded(id)
        }
        avLog("clock reporting installed for \(id)")
    }

    /// Feeds decoded frames to Gecko for compositing.
    ///
    /// A CADisplayLink rather than a timer, so pulls land on the display
    /// refresh AVFoundation is itself targeting: asking for a frame at an
    /// arbitrary phase either repeats one or misses one, and the seam is
    /// visible as judder.
    ///
    /// copyPixelBuffer hands over a +1 reference. Gecko's callback takes
    /// its own reference on the underlying IOSurface for the hop to its
    /// main thread, so releasing here as soon as the call returns is
    /// correct - and required, because holding these would exhaust the
    /// output's buffer pool within seconds and stall decoding.
    private func startFrameDelivery(for id: UInt) {
        guard let entry = withState({ players[id] }) else {
            return
        }
        entry.item.add(entry.videoOutput)

        let link = CADisplayLink(target: self,
                                 selector: #selector(pullFrames(_:)))
        // The id travels through the display link rather than a captured
        // closure so the link never holds a Player.
        link.preferredFramesPerSecond = 0  // match the display
        withState { frameLinkIDs[ObjectIdentifier(link)] = id }
        link.add(to: .main, forMode: .common)
        entry.displayLink = link
        // Proves the link was installed and the output attached,
        // separating "never started" from "started but blocked".
        avLog("frameDelivery[\(id)] display link installed, "
              + "outputs=\(entry.item.outputs.count)")
    }

    /// Display-link target. Non-private because CADisplayLink resolves it
    /// by selector.
    @objc private func pullFrames(_ link: CADisplayLink) {
        let state = withState { () -> (id: UInt, entry: Player)? in
            guard let id = frameLinkIDs[ObjectIdentifier(link)],
                  let entry = players[id] else {
                return nil
            }
            return (id, entry)
        }
        guard let (id, entry) = state else {
            link.invalidate()
            return
        }

        // Every gate below used to be a bare `return`. At 60fps a stuck
        // one looks exactly like the link never firing, which is why
        // "still magenta" came with nothing in the log to explain it.
        // Reported at powers of two - the same scheme the JIT code uses,
        // because unconditional logging here would be its own outage.
        entry.pullTicks += 1
        let tick = entry.pullTicks
        let shouldReport = (tick & (tick &- 1)) == 0

        func report(_ reason: String) {
            guard shouldReport else { return }
            let player = entry.player
            avLog("framePull[\(id)] tick=\(tick) BLOCKED: \(reason)"
                  + " rate=\(player.rate)"
                  + " timeControl=\(player.timeControlStatus.rawValue)"
                  + " itemStatus=\(entry.item.status.rawValue)"
                  + " outputs=\(entry.item.outputs.count)"
                  + " waiting=\(player.reasonForWaitingToPlay?.rawValue ?? "nil")"
                  + " err=\(entry.item.error.map { String(describing: $0) } ?? "nil")")
        }

        // The link was installed at createPlayer and only invalidated at
        // destroy, so it ran at full display refresh - 120Hz here, with
        // CADisableMinimumFrameDurationOnPhone set in Info.plist - for
        // the entire life of every player, paused and backgrounded
        // included, computing an item time and querying the output every
        // tick. A player that is PAUSED and has delivered nothing for
        // ~2s at 120Hz cannot need that. play, resume, seek and the
        // readiness replay all restart delivery.
        //
        // == .paused exactly, NOT "anything but .playing". A rebuffer
        // sits in .waitingToPlayAtSpecifiedRate with the timebase
        // frozen, so every tick reports "no new pixel buffer" - and
        // when AVPlayer recovers on its own, no play/resume/seek
        // arrives to unpark a parked link, and item.status never
        // leaves .readyToPlay so the readiness replay does not fire
        // either (nor could it: rate stays 1.0 while waiting, and the
        // replay bails on rate != 0). Parking on a stall therefore
        // froze the video permanently on the last decoded frame while
        // audio played on. Every case the backstop exists for still
        // parks: created-but-never-played, pause() and suspend() all
        // sit in .paused.
        // A protected stream is the only thing that plays with the clock
        // running and the output permanently empty. AVPlayerItemVideoOutput
        // will not vend pixel buffers for content it is decrypting, so
        // "playing, ready, and nothing coming out" is the signature.
        //
        // Gecko cannot see any of this. Apple TV+ hands the whole key
        // exchange to AVFoundation through the AVContentKeySession and
        // never touches EME, so the content process has no CDM proxy and
        // no reason to think the stream is protected - it keeps waiting
        // for frames that can never arrive, which is a black picture with
        // audio playing over it.
        //
        // The window is measured in ITEM TIME, not wall clock, and that is
        // what makes it safe: a paused player does not advance item time,
        // and neither does a rebuffering one, so neither can be mistaken
        // for this. .playing with no waiting reason excludes them anyway;
        // the item-time test is the belt to that pair of braces.
        /// Logs why the detector turned back, but only when the answer
        /// CHANGES. ADDED - see fix_stall_detector_says_why.py.
        func noteStallReason(_ reason: String) {
            let changed = withState { () -> Bool in
                guard entry.lastStallReason != reason else { return false }
                entry.lastStallReason = reason
                return true
            }
            guard changed else { return }
            avLog("framePull[\(id)] not reporting protected: \(reason)")
        }

        /// Quantises a time to the nearest quarter second before it
        /// is embedded in a stall reason. ADDED - the edge trigger
        /// above compares STRINGS, so a reason carrying a
        /// full-precision Double is a new reason on every
        /// display-link tick: "only 0.00833...s elapsed" flooded one
        /// capture with 2656 lines, which is exactly the burial
        /// noteStallReason exists to prevent. A quarter-second
        /// bucket keeps the value diagnostic - which side of the
        /// 1.0s window the detector is on, and roughly how far
        /// along - while capping a value-carrying reason at four
        /// changes per second of item time. Only the LOG is
        /// bucketed; every comparison the detector makes still uses
        /// the full-precision values. Non-finite values pass
        /// through verbatim: "nan" and "inf" are already stable
        /// strings, and the not-usable reason needs to say which
        /// one it saw.
        func coarse(_ seconds: Double) -> String {
            guard seconds.isFinite else { return "\(seconds)" }
            return String(format: "%.2f", (seconds * 4).rounded() / 4)
        }

        func noteProtectedStall(at itemSeconds: Double) {
            // CHANGED - every early return below now says which one it
            // was. See fix_stall_detector_says_why.py's docstring: this
            // detector is the ONLY producer of "protected" for a stream
            // that never delivers a second buffer, it did not fire for
            // Apple TV+, and its silence could not be told apart from
            // its not being called.
            guard itemSeconds.isFinite, itemSeconds >= 0 else {
                noteStallReason("item time \(coarse(itemSeconds)) is not usable")
                return
            }
            let player = entry.player
            // External playback: the output starves BY DESIGN while the
            // receiver renders - AVPlayerItemVideoOutput vends nothing
            // for a player that is drawing on an Apple TV - and the
            // clock keeps running, which is precisely the signature this
            // detector treats as DRM. Keep the window pinned to "now" so
            // nothing accumulates, and never latch: the latch is
            // one-shot and turns a clear stream into a black
            // AVPlayerLayer for the rest of the title.
            //
            // The player is asked DIRECTLY rather than through the
            // externalActive mirror. The mirror is written by a KVO that
            // hops to the main queue, and this tick can run before that
            // hop lands; the property itself is the truth at this
            // instant.
            if player.isExternalPlaybackActive {
                withState { entry.lastBufferItemTime = itemSeconds }
                noteStallReason("external playback active")
                return
            }
            // Grace for the join. Between the route moving to AirPlay
            // and isExternalPlaybackActive admitting it the output has
            // already gone quiet, and how long that gap lasts is the
            // receiver's business - nothing here can measure it in
            // advance, so it is bounded in ITEM time instead of guessed
            // in wall time: a paused or rebuffering player does not
            // advance item time and cannot burn the grace while nothing
            // is happening. Eligible means the player is ALLOWED to go
            // external (the owner, under the global switch, not denied
            // by the page) on a route that HAS an AirPlay output; the
            // route bit is cached by the route observer because
            // AVAudioSession is not something to query at display-link
            // rate. Counting starts at the first tick after the edge
            // that made the player eligible - every such edge resets
            // externalEligibleSinceItemTime to -1.
            //
            // Accepted cost: on an audio-only receiver (a HomePod) the
            // player never goes external, so a genuinely protected
            // stream latches after the grace plus today's window - about
            // three seconds of item time later than it does today.
            let eligible = player.allowsExternalPlayback
                && withState { audioRouteIsAirPlay }
            if eligible {
                let grace = withState { () -> String? in
                    if entry.externalEligibleSinceItemTime < 0
                        || itemSeconds < entry.externalEligibleSinceItemTime {
                        // Seeks in either direction restart this clock
                        // through seek(_:to:); a backwards move that
                        // got past that reset rebases here rather than
                        // stretching the grace by the distance seeked.
                        entry.externalEligibleSinceItemTime = itemSeconds
                    }
                    let elapsed = itemSeconds - entry.externalEligibleSinceItemTime
                    guard elapsed < Self.airPlayStallGraceSeconds else {
                        return nil
                    }
                    entry.lastBufferItemTime = itemSeconds
                    return "AirPlay grace (\(coarse(elapsed))s of "
                        + "\(Self.airPlayStallGraceSeconds) - route is AirPlay, "
                        + "player allowed, not external yet)"
                }
                if let grace {
                    noteStallReason(grace)
                    return
                }
            }
            if player.timeControlStatus != .playing {
                noteStallReason("player is not playing (timeControl="
                                + "\(player.timeControlStatus.rawValue))")
                return
            }
            if let waiting = player.reasonForWaitingToPlay {
                noteStallReason("waiting - \(waiting.rawValue)")
                return
            }
            if entry.item.status != .readyToPlay {
                noteStallReason("item not ready (status="
                                + "\(entry.item.status.rawValue))")
                return
            }
            // Built inside the lock with the values it names, and
            // carried out as a value: two of these branches WRITE
            // lastBufferItemTime, so a reason composed afterwards
            // would describe state the next tick may have moved.
            var reason: String?
            let shouldReport = withState { () -> Bool in
                guard !entry.reportedProtected else {
                    reason = "already reported"
                    return false
                }
                // First observation with no buffer yet: start the window
                // here rather than at zero, so a player that began mid
                // stream is measured from where it actually is.
                if entry.lastBufferItemTime < 0 {
                    entry.lastBufferItemTime = itemSeconds
                    reason = "window opened at \(coarse(itemSeconds))"
                    return false
                }
                // A backwards seek rebases instead of accumulating.
                if itemSeconds < entry.lastBufferItemTime {
                    entry.lastBufferItemTime = itemSeconds
                    reason = "rebased to \(coarse(itemSeconds))"
                    return false
                }
                guard itemSeconds - entry.lastBufferItemTime >= 1.0 else {
                    reason = "only "
                        + "\(coarse(itemSeconds - entry.lastBufferItemTime))s of "
                        + "item time elapsed, need 1.0"
                    return false
                }
                entry.reportedProtected = true
                // ADDED - see fix_stall_protected_player_id.py's
                // docstring. The stall detector is the ONLY producer
                // of "this is protected" for a native-HLS FairPlay
                // stream, which never reaches provideKeyResponse, so
                // without this the compositor asks protectedPlayerId()
                // the moment it builds the layer, gets 0, and drops
                // the layer on the floor. Set under the same lock that
                // claims the report: the report is one-shot, so the id
                // must never be published later than the flag.
                lastProtectedPlayerId = id
                return true
            }
            guard shouldReport else {
                if let reason {
                    noteStallReason(reason)
                }
                return
            }
            avLog("framePull[\(id)] output stalled "
                  + "\(coarse(itemSeconds - entry.lastBufferItemTime))s of item time "
                  + "with no buffer - reporting protected")
            ReynardAVPlayerNotifyProtected(id)
        }

        func noteIdleTick() {
            let shouldPark = withState { () -> Bool in
                guard entry.player.timeControlStatus == .paused else {
                    entry.idlePullTicks = 0
                    return false
                }
                entry.idlePullTicks += 1
                guard entry.idlePullTicks >= 240 else {
                    return false
                }
                entry.idlePullTicks = 0
                return true
            }
            if shouldPark {
                setPullParked(true, for: entry)
                avLog("framePull[\(id)] idle while paused - pausing pull link")
            }
        }

        // DIAGNOSTIC one-shot: play() was requested, the item is ready,
        // and the player still sits in .paused - the signature of media
        // services refusing playback for this process (the instrumented
        // capture shows decoder Play with no pause anywhere). Retry once
        // MUTED: if muted playback starts, the audio path is the gate
        // and the fix is session activation / host brokering, not the
        // pipeline. Tick 200 is after the readiness replay had its
        // chance and before the idle backstop can park the link.
        if tick == 200 {
            let wantsRetry = withState { () -> Bool in
                guard entry.wantsPlayback, !entry.mutedRetryDone else {
                    return false
                }
                entry.mutedRetryDone = true
                return true
            }
            if wantsRetry, entry.item.status == .readyToPlay,
               entry.player.timeControlStatus == .paused {
                avLog("framePull[\(id)] DIAGNOSTIC muted retry - play() was ignored while ready")
                entry.player.isMuted = true
                entry.player.play()
            }
        }

        let output = entry.videoOutput
        let itemTime = output.itemTime(forHostTime: CACurrentMediaTime())
        guard itemTime.isValid, itemTime.isNumeric else {
            // An item with no timebase is what an AVPlayer that was never
            // told to play looks like.
            report("itemTime invalid (no timebase)")
            noteIdleTick()
            return
        }

        // The clock is pushed before the new-buffer gate: a repeated
        // frame still means time moved, and Gecko's demuxer paces its
        // synthetic samples on this position whether or not pixels
        // cross on this particular tick. This value used to be computed
        // and thrown away.
        pushTime(id, entry, CMTimeGetSeconds(itemTime))

        guard output.hasNewPixelBuffer(forItemTime: itemTime) else {
            report("no new pixel buffer at t=\(CMTimeGetSeconds(itemTime))")
            noteProtectedStall(at: CMTimeGetSeconds(itemTime))
            noteIdleTick()
            return
        }
        guard let buffer = output.copyPixelBuffer(forItemTime: itemTime,
                                                  itemTimeForDisplay: nil)
        else {
            // ADDED the detector call - see
            // fix_stall_detector_on_refused_copy.py's docstring.
            //
            // This is a protected shape too, and it was the branch
            // without the detector on it. The output knows a frame
            // exists at this item time - that is what got us past
            // hasNewPixelBuffer above - and then declines to hand the
            // pixels over, because they live in memory the CPU may not
            // read. Until now that fell straight through to the idle
            // tick and returned.
            //
            // The stall window needs no adjustment: lastBufferItemTime
            // is updated only after a SUCCESSFUL copy, so a refused
            // copy accumulates item time exactly as an absent buffer
            // does.
            report("copyPixelBuffer returned nil")
            noteProtectedStall(at: CMTimeGetSeconds(itemTime))
            noteIdleTick()
            return
        }

        withState {
            entry.idlePullTicks = 0
            entry.lastBufferItemTime = CMTimeGetSeconds(itemTime)
        }
        if !entry.reportedFirstPull {
            entry.reportedFirstPull = true
            avLog("framePull[\(id)] FIRST BUFFER after \(tick) ticks - handing to Gecko")
        }
        ReynardAVPlayerNotifyFrame(id, buffer)
    }

    /// Reports duration and dimensions back to AVPlayerDecoder once the
    /// item resolves them.
    ///
    /// Nothing did this before, so AVPlayerDecoder::NotifyMetadata had no
    /// caller at all: the demuxer never got a duration, MediaFormatReader
    /// never produced metadata, and the element stayed at HAVE_NOTHING -
    /// which paints nothing no matter how correct the frame in its
    /// VideoFrameContainer is. Device captures showed exactly that,
    /// "placeholder PUBLISHED 1920x1080 planes=2" over a blank screen.
    ///
    /// .initial matters: an item that is already ready when this runs
    /// would otherwise never send a change, and the metadata would never
    /// arrive at all.
    private func observeMetadata(of item: AVPlayerItem, playerId: UInt,
                                 storingInto entry: Player) {
        // [weak entry] is load-bearing. The three observations below
        // live in entry.observers, so the Player retains them; each of
        // their handlers calls this closure. A strong capture here
        // closes a cycle (Player -> observers -> handler -> report ->
        // Player) that invalidate() does NOT break - an invalidated
        // NSKeyValueObservation keeps its handler until it deallocates,
        // and deallocating is exactly what the cycle prevents. Every
        // destroy(_:) leaked the whole Player graph: AVPlayer, item,
        // asset, video output and key-session reference, per protected
        // video ever played.
        let report: (AVPlayerItem) -> Void = { [weak entry] item in
            guard let entry else {
                return
            }
            guard item.status == .readyToPlay else {
                return
            }
            // Both can be indefinite or NaN before the asset resolves;
            // the C side treats a non-finite duration as unknown.
            let duration = item.duration.isValid && !item.duration.isIndefinite
                ? item.duration.seconds
                : Double.nan
            let size = item.presentationSize

            // A rendition switch genuinely changes the size mid-stream
            // and must go through; an identical repeat must not.
            // NaN != NaN, so an unknown duration is compared as a
            // string rather than silently republishing forever.
            let unchanged = entry.reportedSize == size
                && String(describing: entry.reportedDuration) == String(describing: Optional(duration))
            guard !unchanged else {
                return
            }
            entry.reportedDuration = duration
            entry.reportedSize = size

            avLog("metadata ready for \(playerId): duration=\(duration) size=\(size)")
            ReynardAVPlayerNotifyMetadata(
                UInt(playerId), duration,
                Int32(size.width.rounded()), Int32(size.height.rounded())
            )
        }

        // Playback intent has to be RE-APPLIED here, not merely recorded.
        // The element calls play() as soon as it wants playback, which is
        // routinely before the item has finished loading; AVPlayer takes
        // the rate, finds the item not ready, and settles back to 0.
        //
        // Device evidence, from the pull loop's own diagnostics:
        //   framePull[12] tick=1  rate=1.0 timeControl=1 itemStatus=0
        //   framePull[12] tick=16 rate=0.0 timeControl=0 itemStatus=1
        // - ready, and paused, with nothing left to start it. Playback
        // then never advances, so hasNewPixelBuffer keeps answering false
        // against a frozen clock and only the frame decoded at t=0 ever
        // reaches Gecko. That is the single still frame with a dead
        // scrubber, and it happens on completely unencrypted streams -
        // Apple's own bipbop test asset reproduces it.
        let resumeIfWanted: () -> Void = { [weak self, weak entry] in
            guard let self, let entry else {
                return
            }
            // rate == 0 keeps this from fighting playback that is already
            // running: several observations fire per load.
            guard self.withState({ entry.wantsPlayback }),
                  entry.item.status == .readyToPlay,
                  entry.player.rate == 0 else {
                return
            }
            avLog("play re-applied for \(playerId) - item reached readyToPlay while paused")
            // Delivery too, not just playback. The item can take long
            // enough to become ready that the idle backstop below has
            // already parked the pull link, and starting the player
            // against a paused link would resume a video that still
            // never showed a second frame - the very symptom this
            // replay exists to fix.
            self.resumeFrameDelivery(for: entry)
            entry.player.play()
        }

        // The main QUEUE is not Gecko's main THREAD in a content
        // process - Gecko runs "MainThread" on a spawned thread there,
        // and this queue drains on the extension's principal thread.
        // ReynardAVPlayerNotifyMetadata hops to Gecko's main thread
        // itself now (capture 16), so this dispatch is only for
        // ordering and to get off AVFoundation's KVO queue.
        for observation in [
            item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
                DispatchQueue.main.async {
                    // .failed is terminal - AVFoundation never moves an
                    // item out of it - and everything below is for a
                    // live one: report only speaks at .readyToPlay and
                    // resumeIfWanted requires it too, which is how a
                    // failed item used to vanish without a word while
                    // Gecko's demuxer parked forever waiting on a
                    // position. Tell Gecko instead; it routes this to
                    // the decoder's error path so the element fires
                    // 'error' and the page can react.
                    if item.status == .failed {
                        avLog("item FAILED for \(playerId): "
                              + "\(item.error.map { String(describing: $0) } ?? "no error object")")
                        ReynardAVPlayerNotifyError(playerId)
                        return
                    }
                    // Before report, which returns early whenever the
                    // metadata is unchanged - playback must not depend on
                    // whether the duration happened to move.
                    resumeIfWanted()
                    report(item)
                    // Seed the clock once the item can answer for a
                    // position. A paused element never advances the
                    // periodic observer and never pulls frames, so
                    // without this one-shot Gecko's demuxer would have
                    // no position at all and park forever - the element
                    // would stall at HAVE_METADATA while paused.
                    if item.status == .readyToPlay,
                       let self,
                       let entry = self.withState({ self.players[playerId] }) {
                        self.probeSilentPlayback(entry, playerId)
                        let now = entry.player.currentTime()
                        if now.isValid, now.isNumeric {
                            self.pushTime(playerId, entry, now.seconds)
                        }
                    }
                }
            },
            item.observe(\.duration, options: [.new]) { item, _ in
                DispatchQueue.main.async { report(item) }
            },
            item.observe(\.presentationSize, options: [.new]) { item, _ in
                DispatchQueue.main.async { report(item) }
            },
        ] {
            entry.observers.append(observation)
        }
    }

    /// Records the intent as well as issuing it, because the issue can be
    /// lost: an item that is not ready yet drops the rate back to 0, and
    /// resumeIfWanted replays this once it becomes ready.
    @objc public func play(_ id: UInt) {
        avLog("HOST play(\(id))")
        guard let picked = withState({ () -> (Player, Bool)? in
            guard let entry = players[id] else {
                return nil
            }
            let wasWanted = entry.wantsPlayback
            entry.wantsPlayback = true
            return (entry, wasWanted)
        }) else {
            return
        }
        let (entry, wasWanted) = picked
        // Ownership and the grace move on the paused -> playing EDGE
        // only. Gecko forwards every element.play() as a decoder Play()
        // (HTMLMediaElement::PlayInternal issues it before it reads
        // oldPaused), and pages re-issue play() while already playing -
        // stall watchdogs, visibilitychange handlers, ad SDKs - so a
        // redundant one from a background tab would otherwise take the
        // receiver from the film the user is watching, and on an
        // audio-only receiver would re-arm the grace often enough that
        // a protected stream never latches. WebKit's playInternal
        // short-circuits an already-playing session for the same
        // reason. The receiver's own resume and the interruption replay
        // set wantsPlayback in timeControlStatusDidChange before the
        // element's Play() lands here, so they are not edges either -
        // and that player is already the owner. A player refused the
        // flag for being muted needs a real pause/play after unmuting;
        // if unmute-while-playing should count, that belongs in
        // setVolume, not here.
        if !wasWanted {
            // Before play(): the flag has to be on the player by the
            // time AVFoundation decides where this playback goes.
            applyExternalPlaybackOwner(id)
            // A play on an eligible player restarts the stall grace
            // even if the flag did not move - a receiver that was
            // released by a pause has to be joined again, and that
            // join is the gap the grace exists for. The other
            // eligibility edges (route observer, policy flip,
            // external->local) re-arm it themselves.
            if entry.player.allowsExternalPlayback {
                withState {
                    if audioRouteIsAirPlay {
                        entry.externalEligibleSinceItemTime = -1
                    }
                }
            }
        }
        resumeFrameDelivery(for: entry)
        entry.player.play()
    }

    @objc public func pause(_ id: UInt) {
        // DIAGNOSTIC - names the pauser. The libxul frames in this
        // backtrace identify the Gecko path that decided to pause;
        // symbolicate the addresses offline if the build is stripped.
        avLog("HOST pause(\(id)) thread="
            + (Thread.isMainThread ? "gcd-main" : Thread.current.description))
        for frame in Thread.callStackSymbols.dropFirst().prefix(8) {
            avLog("HOST pause[\(id)] frame: \(frame)")
        }
        guard let entry = withState({ () -> Player? in
            players[id]?.wantsPlayback = false
            return players[id]
        }) else {
            return
        }
        entry.player.pause()
        // A paused player produces no frames.
        setPullParked(true, for: entry)
    }

    /// Backgrounding. Playback stops but the item is kept, so resuming
    /// does not re-fetch or re-negotiate keys.
    @objc public func suspend(_ id: UInt) {
        // DIAGNOSTIC - names the pauser. The libxul frames in this
        // backtrace identify the Gecko path that decided to pause;
        // symbolicate the addresses offline if the build is stripped.
        avLog("HOST suspend(\(id)) thread="
            + (Thread.isMainThread ? "gcd-main" : Thread.current.description))
        for frame in Thread.callStackSymbols.dropFirst().prefix(8) {
            avLog("HOST suspend[\(id)] frame: \(frame)")
        }
        // wantsPlayback deliberately left alone: this is not the user
        // pausing, and resume has to be able to tell the two apart.
        //
        // suspended is set BEFORE the pause reaches the player, so the
        // timeControlStatus observer - which runs later, on the main
        // queue - already knows this .paused is ours and not the Siri
        // Remote's. Otherwise backgrounding while on the TV would be
        // reported to the page as the receiver pausing.
        guard let entry = withState({ () -> Player? in
            players[id]?.suspended = true
            return players[id]
        }) else {
            return
        }
        entry.player.pause()
        setPullParked(true, for: entry)
    }

    @objc public func resume(_ id: UInt) {
        avLog("HOST resume(\(id))")
        // Only resume what was actually playing. Unconditionally calling
        // play() here would start a video the user had paused before
        // backgrounding.
        guard let entry = withState({ () -> Player? in
            players[id]?.suspended = false
            return players[id]
        }), withState({ entry.wantsPlayback }) else {
            return
        }
        resumeFrameDelivery(for: entry)
        entry.player.play()
    }

    /// Un-pauses the pull link and resets the idle counter. Every path
    /// that can make frames flow again routes through here: play,
    /// resume, seek, and the readiness replay in observeMetadata.
    private func resumeFrameDelivery(for entry: Player) {
        // Not while the receiver renders. The output vends nothing for
        // an externally-playing player, so an unparked link would run
        // at display rate for the length of the film doing nothing -
        // the Siri Remote's resume reaches play(id) and would do
        // exactly that. The external->local edge unparks on its own
        // (externalPlaybackDidChange), paused or not, so the frame the
        // TV had is repainted.
        guard !withState({ entry.externalActive }) else {
            return
        }
        setPullParked(false, for: entry)
    }

    /// The one owner of the park state. The DECISION lives under
    /// stateLock with the rest of the Player's shared state; the
    /// APPLICATION to CADisplayLink.isPaused happens only on the GCD
    /// main queue, the queue the link is scheduled on - pause and
    /// suspend arrive on Gecko's main thread, which is a different
    /// thread in a content process (see the stateLock comment above),
    /// and CADisplayLink is not documented thread-safe. The block
    /// re-reads the desired state under the lock, so a decision that
    /// lands while the hop is in flight wins over the stale one; the
    /// link is also only read under the lock, so the hop cannot race
    /// destroy() nilling it.
    private func setPullParked(_ parked: Bool, for entry: Player) {
        let hasLink = withState { () -> Bool in
            entry.pullParked = parked
            if !parked {
                entry.idlePullTicks = 0
            }
            return entry.displayLink != nil
        }
        guard hasLink else {
            return
        }
        DispatchQueue.main.async { [weak self, weak entry] in
            guard let self, let entry else {
                return
            }
            let apply = self.withState { () -> (CADisplayLink, Bool)? in
                guard let link = entry.displayLink else {
                    return nil
                }
                return (link, entry.pullParked)
            }
            guard let apply else {
                return
            }
            apply.0.isPaused = apply.1
        }
    }

    // MARK: - External playback (AirPlay)

    /// The observers behind the AirPlay behaviour. Installed once, from
    /// init, on the shared audio session; both deliver on the GCD main
    /// queue, where every piece of per-player state they touch is
    /// already written. Nothing here activates or configures the
    /// session - that stays with ensurePlaybackAudioSession and cubeb.
    private func installAudioRouteObservers() {
        let session = AVAudioSession.sharedInstance()
        let seeded = Self.routeHasAirPlay(session.currentRoute)
        withState { audioRouteIsAirPlay = seeded }
        if seeded {
            avLog("audio route is AirPlay at install")
        }
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: session,
            queue: .main
        ) { [weak self] note in
            self?.audioRouteDidChange(note)
        }
        // Beside, not instead of, the logging observer that
        // ensurePlaybackAudioSession installs: that one records every
        // interruption for the capture and stays exactly as it is.
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: session,
            queue: .main
        ) { [weak self] note in
            self?.audioSessionInterruptionDidChange(note)
        }
    }

    // nonisolated: reads only the route description handed in, and the
    // class-level main-actor isolation would otherwise make passing this
    // as a function value (previous.map) a warning.
    private nonisolated static func routeHasAirPlay(_ route: AVAudioSessionRouteDescription) -> Bool {
        return route.outputs.contains { $0.portType == .airPlay }
    }

    private static func describe(_ reason: AVAudioSession.RouteChangeReason) -> String {
        switch reason {
        case .newDeviceAvailable: return "newDeviceAvailable"
        case .oldDeviceUnavailable: return "oldDeviceUnavailable"
        case .categoryChange: return "categoryChange"
        case .override: return "override"
        case .wakeFromSleep: return "wakeFromSleep"
        case .noSuitableRouteForCategory: return "noSuitableRouteForCategory"
        case .routeConfigurationChange: return "routeConfigurationChange"
        case .unknown: return "unknown"
        @unknown default: return "reason \(reason.rawValue)"
        }
    }

    /// Main queue. Two jobs. Keep the cached route bit the stall
    /// detector reads, re-arming the grace on every player whenever the
    /// route lands on AirPlay - on every such change, not only the edge
    /// onto it, because a category change while already on the receiver
    /// can make AVFoundation renegotiate the session, and the join is
    /// the gap the grace covers. And pause what was playing on a
    /// receiver that went away.
    private func audioRouteDidChange(_ note: Notification) {
        let info = note.userInfo ?? [:]
        let reasonRaw = (info[AVAudioSessionRouteChangeReasonKey] as? NSNumber)?.uintValue ?? 0
        let reason = AVAudioSession.RouteChangeReason(rawValue: reasonRaw) ?? .unknown
        let previous = info[AVAudioSessionRouteChangePreviousRouteKey]
            as? AVAudioSessionRouteDescription
        let previousWasAirPlay = previous.map(Self.routeHasAirPlay) ?? false
        let current = AVAudioSession.sharedInstance().currentRoute
        let isAirPlay = Self.routeHasAirPlay(current)
        let (wasAirPlay, armed) = withState { () -> (Bool, Int) in
            let was = audioRouteIsAirPlay
            audioRouteIsAirPlay = isAirPlay
            guard isAirPlay else {
                return (was, 0)
            }
            for entry in players.values {
                entry.externalEligibleSinceItemTime = -1
            }
            return (was, players.count)
        }
        // One line per notification, which is event rate, not tick rate.
        // The port list is what says which of the two screens a capture
        // was on when the picture went black.
        let outputs = current.outputs
            .map { "\($0.portType.rawValue):\($0.portName)" }
            .joined(separator: ",")
        avLog("audio route -> [\(outputs)] reason=\(Self.describe(reason))"
              + (isAirPlay ? " - AirPlay, stall grace armed for \(armed) player(s)" : "")
              + (wasAirPlay != isAirPlay ? " (was \(wasAirPlay ? "AirPlay" : "local"))" : ""))
        // WebKit's OldDeviceUnavailable rule
        // (MediaSessionManagerIOS.mm activeAudioRouteDidChange), scoped
        // to AirPlay loss: only a previous route that HAD an AirPlay
        // output pauses anything, so headphones and CarPlay keep
        // today's behaviour for users who never touch AirPlay. A user
        // who picks "iPhone" in the picker arrives under a different
        // reason and pauses nothing - they asked for the move.
        if reason == .oldDeviceUnavailable, previousWasAirPlay {
            // A .began that reached the main queue before this
            // notification must not outlive the route it was about:
            // nothing comes back on a receiver that is gone, so there
            // is nothing to resume and no interruption left to
            // attribute later pauses to. The .began that arrives AFTER
            // this is handled where it lands.
            withState {
                audioInterruptionActive = false
                for entry in players.values {
                    entry.resumeAfterInterruption = false
                }
            }
            avLog("AirPlay route lost - pausing external players")
            pauseExternalPlayersForRouteLoss()
        }
    }

    /// Main queue. WebKit keeps the audio session for wireless playback
    /// through an interruption and resumes when it ends with
    /// .shouldResume (MediaSessionManagerIOS.mm). Only external players
    /// are handled here: local playback's interruption handling is
    /// unchanged - a pre-existing gap, out of this change's scope.
    ///
    /// The pause AVFoundation applies for the interruption reaches
    /// timeControlStatusDidChange looking exactly like the receiver's
    /// and clears wantsPlayback, so wantsPlayback alone cannot decide
    /// what to resume. resumeAfterInterruption is set here for what was
    /// playing at .began, and by the observer for a pause that lands
    /// while the interruption is active; the host-time check below
    /// covers the remaining order, a pause delivered to the main queue
    /// a moment BEFORE this notification - the two come from different
    /// queues and nothing sequences them.
    private func audioSessionInterruptionDidChange(_ note: Notification) {
        let info = note.userInfo ?? [:]
        guard let typeRaw = (info[AVAudioSessionInterruptionTypeKey] as? NSNumber)?.uintValue,
              let type = AVAudioSession.InterruptionType(rawValue: typeRaw) else {
            return
        }
        switch type {
        case .began:
            // iOS 17 interrupts the Now Playing session when its route
            // is disconnected (AVAudioSession's
            // prefersInterruptionOnRouteDisconnect defaults on), and no
            // .ended ever follows - there is no route to come back to.
            // That is route loss, which audioRouteDidChange pauses and
            // reports; read as an interruption it would leave
            // audioInterruptionActive set for the life of the host,
            // and every later Siri Remote pause would be attributed to
            // an interruption and resumed at the next .ended. The key
            // (iOS 14.5) and the reason (iOS 17) both stay inside the
            // availability check for the iOS 13 deployment target.
            if #available(iOS 17, *),
               let reasonRaw = (info[AVAudioSessionInterruptionReasonKey] as? NSNumber)?.uintValue,
               let reason = AVAudioSession.InterruptionReason(rawValue: reasonRaw),
               reason == .routeDisconnected {
                avLog("interruption began (route disconnected) - route loss, not an interruption")
                return
            }
            let now = CACurrentMediaTime()
            let marked = withState { () -> [UInt] in
                audioInterruptionActive = true
                // Every mark is re-derived from scratch: Apple does not
                // guarantee a .began its matching .ended, and a mark
                // left by an unpaired one would resume, at the next
                // .ended, a video the user has since paused.
                for entry in players.values {
                    entry.resumeAfterInterruption = false
                }
                var ids: [UInt] = []
                for (id, entry) in players where entry.externalActive {
                    let recentPause = entry.lastReceiverPauseHostTime >= 0
                        && now - entry.lastReceiverPauseHostTime
                            < Self.interruptionPauseAttributionSeconds
                    guard entry.wantsPlayback || recentPause else {
                        continue
                    }
                    entry.resumeAfterInterruption = true
                    ids.append(id)
                }
                return ids
            }
            if !marked.isEmpty {
                avLog("interruption began while external - will resume \(marked)")
            }
        case .ended:
            let optionsRaw = (info[AVAudioSessionInterruptionOptionKey] as? NSNumber)?.uintValue ?? 0
            let shouldResume = AVAudioSession.InterruptionOptions(rawValue: optionsRaw)
                .contains(.shouldResume)
            let resuming = withState { () -> [(key: UInt, value: Player)] in
                audioInterruptionActive = false
                var out: [(key: UInt, value: Player)] = []
                for (id, entry) in players where entry.resumeAfterInterruption {
                    entry.resumeAfterInterruption = false
                    guard shouldResume, entry.externalActive else {
                        continue
                    }
                    out.append((key: id, value: entry))
                }
                return out
            }
            // wantsPlayback is deliberately NOT set here. The play()
            // lands in timeControlStatusDidChange as .playing with
            // wantsPlayback false - the "resumed behind the element's
            // back" branch - which sets it and tells the element, so
            // the page sees the same pause/play pair WebKit's
            // suspendPlayback/resumePlayback produce.
            for (id, entry) in resuming {
                entry.player.play()
                avLog("externalPlayback[\(id)] interruption ended - play() re-issued")
            }
        @unknown default:
            break
        }
    }

    /// Two observations, appended to entry.observers so destroy
    /// invalidates them. [weak self] only and the entry re-fetched by
    /// id - the retain-cycle discipline observeMetadata documents.
    /// .initial on the external one: a player built while the route is
    /// already external is the ordinary "second episode" case.
    private func observeExternalPlayback(of player: AVPlayer, playerId: UInt,
                                         storingInto entry: Player) {
        for observation in [
            player.observe(\.isExternalPlaybackActive, options: [.initial, .new]) { [weak self] _, _ in
                DispatchQueue.main.async {
                    self?.externalPlaybackDidChange(playerId)
                }
            },
            player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
                DispatchQueue.main.async {
                    self?.timeControlStatusDidChange(playerId)
                }
            },
        ] {
            entry.observers.append(observation)
        }
    }

    /// Main queue. The one writer of the externalActive mirror.
    private func externalPlaybackDidChange(_ id: UInt) {
        guard let entry = withState({ players[id] }) else {
            return
        }
        let active = entry.player.isExternalPlaybackActive
        let changed = withState { () -> Bool in
            guard entry.externalActive != active else {
                return false
            }
            entry.externalActive = active
            if !active {
                // Reopen the stall window at the next observed tick -
                // the "window opened at" branch - rather than measuring
                // from the last LOCAL buffer, which was however long the
                // TV had the picture ago. And forget the eligibility
                // clock: whichever edge matters next re-arms it.
                entry.lastBufferItemTime = -1
                entry.externalEligibleSinceItemTime = -1
            }
            return true
        }
        guard changed else {
            return
        }
        if active {
            // Nothing will vend while the receiver renders. The 4 Hz
            // periodic observer in installClockReporting keeps the clock
            // moving for Gecko, so the element's currentTime and
            // timeupdate carry on without the link.
            setPullParked(true, for: entry)
            if withState({ detachesVideoOutputWhileExternal }), !entry.videoOutputDetached {
                entry.item.remove(entry.videoOutput)
                entry.videoOutputDetached = true
                avLog("externalPlayback[\(id)] video output detached (fallback)")
            }
        } else {
            if entry.videoOutputDetached {
                entry.item.add(entry.videoOutput)
                entry.videoOutputDetached = false
                avLog("externalPlayback[\(id)] video output re-attached")
            }
            // Paused or not. The local picture is the forced black
            // placeholder from the kind 0 true edge, and only a pulled
            // frame repaints it - AVPlayerLayer would show the paused
            // frame here, and the pull has to run once for the same
            // result. The idle backstop in noteIdleTick parks the link
            // again for a paused player, the contract seek(_:to:)
            // already relies on.
            resumeFrameDelivery(for: entry)
        }
        let anyActive = recomputeAnyExternalPlaybackActive()
        avLog("externalPlayback[\(id)] -> \(active) (any=\(anyActive))")
        postExternalPlaybackDidChange(playerId: id, active: active)
        // Build 2 call site: ReynardAVPlayerNotifyHostState
        ReynardAVPlayerNotifyHostState(id, 0, active)
    }

    /// Main queue. Mirrors WebKit's timeControlStatusDidChange
    /// (MediaPlayerPrivateAVFoundationObjC.mm), which returns early
    /// unless the target is wireless: an Apple TV's Siri Remote pauses
    /// and resumes the AVPlayer behind the element's back, and the
    /// element's paused flag has to follow or the page's own controls
    /// lie. Locally the element is the only thing that pauses the
    /// player, so nothing is owed - and reporting there would fight
    /// AVFoundation's background auto-pause of a layer-bound player.
    private func timeControlStatusDidChange(_ id: UInt) {
        guard let entry = withState({ players[id] }) else {
            return
        }
        let status = entry.player.timeControlStatus
        let (previous, external, suspended, wants) = withState {
            () -> (AVPlayer.TimeControlStatus, Bool, Bool, Bool) in
            let previous = entry.lastTimeControl
            // Only SETTLED statuses are remembered. A Siri Remote pause
            // that lands while the receiver rebuffers goes .playing ->
            // .waiting -> .paused; recording the .waiting would make it
            // read as .waiting -> .paused and go unreported, leaving
            // wantsPlayback true for the next interruption's .ended to
            // resume a video the user paused. Skipping it, the readiness
            // replay still reads as .paused -> .paused and stays
            // excluded, while WebKit's rule - any non-paused -> paused
            // edge is the receiver's - holds for a real pause.
            if status != .waitingToPlayAtSpecifiedRate {
                entry.lastTimeControl = status
            }
            return (previous, entry.externalActive, entry.suspended,
                    entry.wantsPlayback)
        }
        // The guards: pause(id) clears wantsPlayback BEFORE it pauses,
        // so its .paused arrives with wants false and says nothing;
        // suspend(id) marks suspended first; previous == .playing
        // excludes the readiness replay in observeMetadata (its
        // previous is .paused, since .waiting is never recorded); and
        // an item that is not ready is not something a receiver is
        // acting on.
        guard external, !suspended, entry.item.status == .readyToPlay else {
            return
        }
        if status == .paused, previous == .playing, wants {
            // Not at the end of the item. AVPlayer pauses itself there
            // (actionAtItemEnd), and reporting that as a host pause
            // would reach Gecko's state machine before - or instead of
            // - the end-of-stream it is about to be told about; an
            // element paused short of EOS never fires 'ended', which is
            // what a site's autoplay-next waits on. The element's own
            // pause at the end still arrives through pause(id), as it
            // does locally.
            let duration = entry.item.duration
            let now = entry.player.currentTime()
            if duration.isValid, duration.isNumeric, now.isValid, now.isNumeric,
               now.seconds >= duration.seconds - 0.5 {
                avLog("externalPlayback[\(id)] paused at the end of the item - not the receiver")
                return
            }
            let interruption = withState { () -> Bool in
                entry.wantsPlayback = false
                entry.lastReceiverPauseHostTime = CACurrentMediaTime()
                if audioInterruptionActive {
                    entry.resumeAfterInterruption = true
                }
                return audioInterruptionActive
            }
            setPullParked(true, for: entry)
            avLog("externalPlayback[\(id)] paused behind the element's back "
                  + (interruption ? "(interruption)" : "(receiver)"))
            // Build 2 call site: ReynardAVPlayerNotifyHostState
            ReynardAVPlayerNotifyHostState(id, 1, false)
        } else if status == .playing, !wants {
            withState { entry.wantsPlayback = true }
            avLog("externalPlayback[\(id)] resumed behind the element's back")
            // Build 2 call site: ReynardAVPlayerNotifyHostState
            ReynardAVPlayerNotifyHostState(id, 1, true)
        }
    }

    /// Last-played-wins. The public stand-in for WebKit's rule that only
    /// the Now-Playing-eligible session gets the target
    /// (MediaSessionManagerIOS.mm activeVideoRouteDidChange): the tab
    /// the user pressed play in is the one on the TV, deterministically,
    /// rather than whichever of several allowed players AVFoundation
    /// happens to pick. A MUTED player never steals an active session,
    /// nor the flag from an audible owner that still wants to play -
    /// Gecko allows muted autoplay (Allowed_muted), so a background tab
    /// preloading a trailer would otherwise silently take the receiver
    /// from the film the user is watching, or be the one that joins it
    /// when the user casts after the trailer started.
    private func applyExternalPlaybackOwner(_ id: UInt) {
        let outcome = withState { () -> (previous: UInt?, changed: Bool, refusedBy: UInt?) in
            guard let entry = players[id] else {
                return (nil, false, nil)
            }
            let previous = players.first { $0.value.isExternalOwner }?.key
            if previous == id {
                return (previous, false, nil)
            }
            let muted = entry.player.isMuted || entry.player.volume <= 0.001
            if muted {
                // Never take an ACTIVE receiver from anyone...
                if let active = players.first(where: {
                    $0.value !== entry && $0.value.externalActive
                }) {
                    return (previous, false, active.key)
                }
                // ...nor the flag from an audible owner that still
                // wants to play on a local route. That owner is the
                // session AVFoundation must join when the user picks a
                // receiver LATER - film first, cast second is the
                // common order - and a muted trailer holding the flag
                // in between would be what appears on the TV. WebKit:
                // a muted element is never Now-Playing eligible
                // (MediaElementSession::canShowControlsManager). A
                // paused or muted previous owner still yields.
                if let previous, let owner = players[previous], owner.wantsPlayback,
                   !(owner.player.isMuted || owner.player.volume <= 0.001) {
                    return (previous, false, previous)
                }
            }
            for (pid, other) in players {
                other.isExternalOwner = (pid == id)
            }
            return (previous, true, nil)
        }
        if let refusedBy = outcome.refusedBy {
            avLog("externalPlayback[\(id)] muted - not taking the receiver from \(refusedBy)")
            return
        }
        guard outcome.changed else {
            return
        }
        avLog("externalPlayback owner -> \(id)"
              + (outcome.previous.map { " (was \($0))" } ?? ""))
        reapplyExternalPlaybackPolicy()
    }

    /// Pushes the three-way decision - global switch, ownership, the
    /// page's own deny - onto the player. Also the one place the grace
    /// is re-armed for a flag that just came on under an AirPlay route:
    /// that is the edge AVFoundation joins the receiver on.
    private func applyExternalPlaybackPolicy(to entry: Player, id: UInt) {
        let (allowed, routeIsAirPlay) = withState { () -> (Bool, Bool) in
            (externalPlaybackAllowedGlobally && entry.isExternalOwner
                && !entry.deniedByElement,
             audioRouteIsAirPlay)
        }
        guard entry.player.allowsExternalPlayback != allowed else {
            return
        }
        entry.player.allowsExternalPlayback = allowed
        if allowed, routeIsAirPlay {
            withState { entry.externalEligibleSinceItemTime = -1 }
        }
        avLog("externalPlayback[\(id)] allowsExternalPlayback -> \(allowed)")
    }

    private func reapplyExternalPlaybackPolicy() {
        for (id, entry) in withState({ Array(players) }) {
            applyExternalPlaybackPolicy(to: entry, id: id)
        }
    }

    /// Under the lock; returns the new value.
    private func recomputeAnyExternalPlaybackActive() -> Bool {
        return withState {
            isAnyExternalPlaybackActive = players.values.contains { $0.externalActive }
            return isAnyExternalPlaybackActive
        }
    }

    /// Main-queue delivery from wherever the edge was seen: the KVO
    /// handlers are already there; destroy arrives on Gecko's main
    /// thread, which in the app process is the same thread and in a
    /// content process is not.
    private func postExternalPlaybackDidChange(playerId: UInt, active: Bool) {
        let post = {
            NotificationCenter.default.post(
                name: Self.externalPlaybackDidChange,
                object: nil,
                userInfo: ["playerId": playerId, "active": active])
        }
        if Thread.isMainThread {
            post()
        } else {
            DispatchQueue.main.async(execute: post)
        }
    }

    // MARK: - AirPlay policy, pushed by the app

    /// The global kill switch (Prefs.AirPlaySettings.allowsVideo, in the
    /// app). Off: every player's allowsExternalPlayback is false, so an
    /// AirPlay route carries audio only - never worse than the cubeb
    /// route is today.
    public func setExternalPlaybackAllowed(_ allowed: Bool) {
        let changed = withState { () -> Bool in
            guard externalPlaybackAllowedGlobally != allowed else {
                return false
            }
            externalPlaybackAllowedGlobally = allowed
            return true
        }
        guard changed else {
            return
        }
        avLog("externalPlayback allowed globally -> \(allowed)")
        reapplyExternalPlaybackPolicy()
    }

    /// usesExternalPlaybackWhileExternalScreenIsActive for every live
    /// player and for the ones created from now on. WebKit ties it to
    /// fullscreen (updateDisableExternalPlayback); the app owns the
    /// tab -> fullscreen map this host has no view of, so it pushes the
    /// answer.
    public func setFullscreenExternalPlaybackPolicy(_ fullscreen: Bool) {
        let (changed, live) = withState { () -> (Bool, [(key: UInt, value: Player)]) in
            let changed = fullscreenExternalPlayback != fullscreen
            fullscreenExternalPlayback = fullscreen
            return (changed, Array(players))
        }
        guard changed else {
            return
        }
        avLog("externalPlayback fullscreen policy -> \(fullscreen)")
        for (id, entry) in live
        where entry.player.usesExternalPlaybackWhileExternalScreenIsActive != fullscreen {
            entry.player.usesExternalPlaybackWhileExternalScreenIsActive = fullscreen
            avLog("externalPlayback[\(id)] usesExternalPlaybackWhileExternalScreenIsActive"
                  + " -> \(fullscreen)")
        }
    }

    /// The A1 fallback: if an attached AVPlayerItemVideoOutput turns out
    /// to starve AND block, the app flips this and the output is
    /// detached on the external edge and put back on the way home. Off
    /// by default; takes effect at the next edge, not on players
    /// already external.
    public func setDetachesVideoOutputWhileExternal(_ on: Bool) {
        let changed = withState { () -> Bool in
            guard detachesVideoOutputWhileExternal != on else {
                return false
            }
            detachesVideoOutputWhileExternal = on
            return true
        }
        guard changed else {
            return
        }
        avLog("externalPlayback detaches video output while external -> \(on)")
    }

    /// The page's own answer - x-webkit-airplay="deny" and its siblings -
    /// relayed by the decoder through opcode 7. Inert until the engine's
    /// protocol declares the selector; nothing here waits on it.
    @objc(setExternalPlayback:allowed:)
    public func setExternalPlayback(_ id: UInt, allowed: Bool) {
        guard let entry = withState({ () -> Player? in
            players[id]?.deniedByElement = !allowed
            return players[id]
        }) else {
            avLog("externalPlayback[\(id)] element policy for a player that does not exist")
            return
        }
        avLog("externalPlayback[\(id)] element policy -> \(allowed ? "allowed" : "denied")")
        applyExternalPlaybackPolicy(to: entry, id: id)
    }

    /// Pause every player that wanted playback when a receiver went
    /// away - WebKit's OldDeviceUnavailable rule (every session that
    /// canProduceAudio), scoped to AirPlay loss by the caller, see
    /// audioRouteDidChange. Deliberately NOT filtered on the
    /// externalActive mirror: that mirror is written by a KVO hop with
    /// no ordering against the route-change notification, and when
    /// AVFoundation's false edge lands first the mirror is already
    /// clear while the player rolls on through the phone's speaker -
    /// the outcome this exists to prevent. The previous route had the
    /// receiver, so every player that wanted to play had its audio
    /// there. Public so the app can drive it from its own route
    /// observer as well; a second call finds nothing left to pause.
    public func pauseExternalPlayersForRouteLoss() {
        let playing = withState {
            Array(players.filter { $0.value.wantsPlayback && !$0.value.suspended })
        }
        for (id, entry) in playing {
            // wantsPlayback first, so the timeControlStatus observer
            // reads the .paused that follows as ours, not the receiver's.
            withState { entry.wantsPlayback = false }
            entry.player.pause()
            setPullParked(true, for: entry)
            avLog("externalPlayback[\(id)] route lost - paused")
            // Build 2 call site: ReynardAVPlayerNotifyHostState
            ReynardAVPlayerNotifyHostState(id, 1, false)
        }
    }

    @objc public func destroy(_ id: UInt) {
        avLog("HOST destroy(\(id))")
        // Unbind first. layer.player holding a torn-down player is what
        // leaves the compositor showing a dead layer, and nothing else
        // clears it - the layer belongs to NativeLayerCA, which has no
        // idea the player went away.
        let staleLayer = withState { () -> AVPlayerLayer? in
            if lastProtectedPlayerId == id {
                lastProtectedPlayerId = 0
            }
            return attachedLayers.removeValue(forKey: id)
        }
        if let staleLayer {
            staleLayer.player = nil
            avLog("detached layer from \(id)")
        }
        guard let entry = withState({ players.removeValue(forKey: id) }) else {
            return
        }
        // Before anything else, and taken from the entry rather than by
        // id - the removeValue above already means a lookup would find
        // nothing. A link left running fires against a torn-down item and
        // keeps the Player alive through its target reference.
        if let link = entry.displayLink {
            _ = withState { frameLinkIDs.removeValue(forKey: ObjectIdentifier(link)) }
            link.invalidate()
            entry.displayLink = nil
        }
        // Clock observers next, before the player is released:
        // AVFoundation requires removeTimeObserver before the player
        // deallocates, and a block-based notification observer outlives
        // the item unless removed explicitly.
        if let token = entry.timeObserverToken {
            entry.player.removeTimeObserver(token)
            entry.timeObserverToken = nil
        }
        if let endObserver = entry.endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            entry.endObserver = nil
        }
        entry.item.remove(entry.videoOutput)
        entry.observers.forEach { $0.invalidate() }
        // The KVO that would have reported the external->local edge was
        // just invalidated, and the entry is already out of players, so
        // the app-facing truth is recomputed here by hand. External
        // playback itself ends with replaceCurrentItem(nil) below; the
        // system route stays on the receiver, as it does in Safari when
        // a casting tab is closed.
        let wasExternal = withState { () -> Bool in
            guard entry.externalActive else { return false }
            entry.externalActive = false
            return true
        }
        entry.player.pause()
        entry.player.replaceCurrentItem(with: nil)
        entry.keySession.removeContentKeyRecipient(entry.asset)
        if wasExternal {
            let anyActive = recomputeAnyExternalPlaybackActive()
            avLog("externalPlayback[\(id)] -> false (destroyed; any=\(anyActive))")
            postExternalPlaybackDidChange(playerId: id, active: false)
        }
        avLog("destroyed \(id)")
    }

    /// The layer the compositor will hand us once NativeLayerCA builds an
    /// AVPlayerLayer for the DRM-marked surface. Until that lands the
    /// player renders nowhere, which is expected.
    @objc public func attachLayer(_ layer: AVPlayerLayer, to id: UInt) {
        guard let entry = withState({ players[id] }) else {
            // CHANGED - see fix_layer_attach_retries_on_licence.py's
            // docstring. This used to return, and the layer was never
            // seen again: the compositor offers it once, and "no
            // protected player yet" is the normal answer for as long as
            // the CKC is in flight. Hold it instead, and bind it in
            // drainPendingProtectedLayer() once a licence names a player.
            //
            // id 0 is how the bridge says "nobody is protected yet" -
            // ids start at 1, so it can never name a live player. An id
            // whose player was torn down between protectedPlayerId() and
            // the main-thread hop arrives here too, and wants the same
            // treatment.
            withState { pendingProtectedLayer = layer }
            avLog("no player \(id) for this layer - stashed until a "
                  + "licence names one")
            return
        }
        // Unbind whatever was bound before. A rotation or any other
        // rebuild constructs a fresh AVPlayerLayer for the same player,
        // and two layers holding one player is not a state AVFoundation
        // renders sensibly - the picture disappears. Nothing else clears
        // the old one: the compositor discarded its pointer, and destroy()
        // only runs when the PLAYER goes away, which it has not.
        let previous = withState { () -> AVPlayerLayer? in
            let old = attachedLayers[id]
            attachedLayers[id] = layer
            return old
        }
        if let previous, previous !== layer {
            previous.player = nil
            avLog("unbound the previous layer for \(id)")
        }
        layer.player = entry.player
        avLog("attached layer to \(id) \(layerOrigin(of: layer))")
    }

    /// Bind the stashed layer now that a licence has named a player.
    ///
    /// ADDED - see fix_layer_attach_retries_on_licence.py's docstring.
    /// Called from provideKeyResponse, the one writer of
    /// lastProtectedPlayerId that can run after the compositor has
    /// already built and offered its layer.
    ///
    /// Re-enters attachLayer rather than binding here, so the unbind of
    /// whatever was bound before, the attachedLayers bookkeeping
    /// destroy() depends on, and the log all stay in one place.
    ///
    /// Hops to the GCD main queue: the caller is on GECKO's main thread,
    /// a spawned thread in a content process (see withState above),
    /// while layer.player and the layer's tree belong on the real main
    /// thread - which is why ReynardAVPlayerAttachLayer hops before
    /// calling in here at all.
    private func drainPendingProtectedLayer() {
        let pending = withState { () -> (layer: AVPlayerLayer, id: UInt)? in
            guard let layer = pendingProtectedLayer,
                  lastProtectedPlayerId != 0,
                  // ADDED - see
                  // fix_stashed_layer_fills_empty_slot_only.py's
                  // docstring. A player that already has a layer is
                  // painting into it, and attachLayer unbinds the
                  // previous layer for an id. The stash carries no
                  // element identity and lastProtectedPlayerId names
                  // whichever player's licence landed LAST, so
                  // binding here would black out whichever element
                  // owns that live layer - a second tab, or the
                  // other display. Fill empty slots only.
                  //
                  // Refusing KEEPS the stash: an occupied slot means
                  // this layer belongs to an element that still has
                  // no player, and a later licence can bind it.
                  attachedLayers[lastProtectedPlayerId] == nil else {
                return nil
            }
            pendingProtectedLayer = nil
            return (layer, lastProtectedPlayerId)
        }
        guard let pending else {
            return
        }
        DispatchQueue.main.async { [weak self] in
            // A layer in no tree cannot paint - the compositor discarded
            // or rebuilt it while the licence was in flight. Binding it
            // would take the player away from the layer that IS on
            // screen, so drop it and leave that binding alone.
            guard pending.layer.superlayer != nil else {
                avLog("stashed layer for \(pending.id) is in no tree "
                      + "- dropped")
                return
            }
            self?.attachLayer(pending.layer, to: pending.id)
        }
    }

    /// Which layer tree this AVPlayerLayer sits in, for the log only.
    ///
    /// Nothing in the attach path carries a window: the compositor calls
    /// ReynardAVPlayerAttachLayer with a bare layer, and the host answers
    /// with whichever player last asked for a key. With one window that
    /// ambiguity never showed. With two - a tab on the phone and a tab on
    /// the CarPlay display, each its own content process - "the picture is
    /// black but the subtitles are there" has two explanations that need
    /// different fixes, and no line in the log separates them.
    ///
    /// The root layer's size does: a car display and a phone are not the
    /// same shape, and an orphaned layer has no root at all. Reported
    /// rather than interpreted here, because the sizes are whatever the
    /// hardware says they are.
    ///
    /// Root size alone turned out not to be enough. A capture showed the
    /// final attach landing in the car's tree (root=425x255) with the
    /// picture still black, which rules out "the phone stole the
    /// binding" and leaves the harder question: the layer is in the
    /// right tree, so why does it paint nothing? Three things can do
    /// that to a correctly-bound layer, and none of them were reported -
    /// it sits outside the root's bounds, something above it is hidden,
    /// or the accumulated opacity is zero. Note own= was already larger
    /// than root= on every car attach, which is the first of those.
    ///
    /// No UIKit here on purpose. This file is in the GeckoView
    /// framework and its header documents what does and does not link;
    /// root size already separates the two screens, so the window and
    /// its UIScreen are not worth a new dependency to reach.
    private func layerOrigin(of layer: AVPlayerLayer) -> String {
        var root: CALayer = layer
        var depth = 0
        var hiddenAncestorDepth = -1
        var effectiveOpacity = layer.opacity
        while let parent = root.superlayer {
            depth += 1
            if parent.isHidden, hiddenAncestorDepth < 0 {
                hiddenAncestorDepth = depth
            }
            effectiveOpacity *= parent.opacity
            root = parent
            // A cycle is impossible in a well-formed tree, but this runs
            // on the main thread during composition and must not hang.
            if depth > 64 { break }
        }
        let rootSize = root.bounds.size
        let ownSize = layer.bounds.size
        // Where the layer actually lands in the root's coordinate space.
        // Bound, unhidden and in the right tree still paints nothing if
        // this rect is empty or falls outside what the root covers.
        let inRoot = layer.convert(layer.bounds, to: root)
        let clipped = inRoot.isEmpty || !root.bounds.intersects(inRoot)

        func n(_ value: CGFloat) -> String { String(format: "%.0f", value) }

        var out = "[depth=\(depth)"
        out += " own=\(n(ownSize.width))x\(n(ownSize.height))"
        out += " root=\(n(rootSize.width))x\(n(rootSize.height))"
        out += " scale=\(String(format: "%.1f", layer.contentsScale))"
        out += " at=\(n(inRoot.origin.x)),\(n(inRoot.origin.y))"
        out += " \(n(inRoot.size.width))x\(n(inRoot.size.height))"
        out += clipped ? " OUTSIDE-ROOT-BOUNDS" : " within-root"
        if layer.isHidden { out += " SELF-HIDDEN" }
        if hiddenAncestorDepth >= 0 {
            out += " HIDDEN-ANCESTOR-at-\(hiddenAncestorDepth)"
        }
        out += " alpha=\(String(format: "%.2f", effectiveOpacity))"
        out += root.delegate == nil ? " root-has-NO-delegate" : " root-delegate=yes"
        if depth == 0 { out += " ORPHAN-not-in-any-tree" }
        out += "]"
        return out
    }

    /// Seconds, or -1 when not yet known.
    @objc public func currentTime(_ id: UInt) -> Double {
        guard let entry = withState({ players[id] }) else {
            return -1
        }
        let time = entry.player.currentTime()
        return time.isValid && !time.isIndefinite ? time.seconds : -1
    }

    @objc public func duration(_ id: UInt) -> Double {
        guard let entry = withState({ players[id] }) else {
            return -1
        }
        let duration = entry.item.duration
        return duration.isValid && !duration.isIndefinite ? duration.seconds : -1
    }

    /// The element's volume, applied to the player that is actually
    /// producing the sound.
    ///
    /// Nothing carried this before, and two faults came out of it: the
    /// page's mute button changed the element and nothing else, and the
    /// "Block Audio Only" autoplay setting was defeated, because Gecko
    /// permits that play only on the belief that the element is
    /// inaudible - a belief AVFoundation never heard about.
    ///
    /// isMuted as well as volume: AVPlayer treats them independently,
    /// and a player left muted by the diagnostic retry in pullFrames
    /// would otherwise stay silent no matter what the page asked for.
    @objc public func setVolume(_ id: UInt, to volume: Double) {
        guard let entry = withState({ players[id] }) else {
            return
        }
        let clamped = max(0.0, min(1.0, volume))
        entry.player.volume = Float(clamped)
        entry.player.isMuted = clamped <= 0.0
        avLog("setVolume(\(id)) -> \(clamped)")
    }

    @objc public func seek(_ id: UInt, to seconds: Double) {
        guard let entry = withState({ players[id] }) else {
            return
        }
        // A seek while PAUSED still has to repaint at the new position,
        // and the link may be parked. The idle backstop parks it again
        // once the frame has been shown and nothing further arrives, so
        // this does not leave it running.
        resumeFrameDelivery(for: entry)
        // ADDED - see fix_seek_rebases_stall_window.py's docstring.
        // Restart the protected-output-stall window at the requested
        // target. noteProtectedStall measures item time elapsed since
        // the last vended buffer, and nothing here used to move that
        // base, so a forward skip of more than a second left a stale
        // one and the first post-seek tick with no buffer met the
        // window on the spot - latching a clear stream as protected,
        // which nothing can undo.
        withState {
            entry.lastBufferItemTime =
                (seconds.isFinite && seconds >= 0) ? seconds : -1
            // A seek in EITHER direction restarts the AirPlay join
            // grace at the landing tick, as it restarts the window
            // above. The grace only rebases itself on a backwards
            // move; a forward one would count the distance seeked as
            // elapsed, collapse the grace, and hand a receiver that is
            // still joining to the one-second window - the same
            // one-shot latch this rebase exists to keep from firing.
            entry.externalEligibleSinceItemTime = -1
        }
        entry.player.seek(
            to: CMTime(seconds: seconds, preferredTimescale: 600)
        ) { [weak self] finished in
            // Report where playback actually landed - keyframe snapping
            // can put it off the requested time, and Gecko's demuxer
            // optimistically assumed the exact target. pushTime is safe
            // on whatever queue AVFoundation completes on.
            guard finished,
                  let self,
                  let entry = self.withState({ self.players[id] }) else {
                return
            }
            let landed = entry.player.currentTime()
            if landed.isValid, landed.isNumeric {
                self.pushTime(id, entry, landed.seconds)
                // ADDED - see fix_seek_rebases_stall_window.py's
                // docstring. The rebase issued at seek start is not
                // enough on its own: a default seek has infinite
                // tolerance, so keyframe snapping can land AHEAD of the
                // requested target by more than the one-second window.
                // Only ever moved FORWARD - a buffer vended between the
                // landing and this callback has already set a later
                // base, and lowering it would bring the window closer
                // to firing rather than push it away.
                let landedSeconds = landed.seconds
                if landedSeconds.isFinite {
                    self.withState {
                        if landedSeconds > entry.lastBufferItemTime {
                            entry.lastBufferItemTime = landedSeconds
                        }
                        // Same forward-only rule for the grace clock: a
                        // tick between the seek and this landing can
                        // have re-armed it at the OLD position, which
                        // the reset at seek start could not foresee.
                        // The next eligible tick reopens it at the
                        // landed position.
                        if entry.externalEligibleSinceItemTime >= 0,
                           landedSeconds > entry.externalEligibleSinceItemTime {
                            entry.externalEligibleSinceItemTime = -1
                        }
                    }
                }
            }
        }
    }
}

/// Handles the key request AVFoundation raises for a protected asset.
///
/// No longer incomplete. The licence server's URL and certificate are
/// per-deployment and are the PAGE's business, which is exactly the
/// point: this delegate never talks to a licence server. It moves four
/// pieces of data across the process boundary and lets Gecko's EME
/// implementation - MediaKeys, MediaKeySession, the page's own fetch -
/// do the negotiating, in the process where the page is.
///
///   identifier out  ->  the element's 'encrypted' event
///   certificate in  <-  setServerCertificate
///   SPC out         ->  the session's 'message' event
///   CKC in          <-  update()
///
/// Everything here runs on the main queue, which in the APP process is
/// also Gecko's main thread, so the C entry points need no hop. (In a
/// content process the two differ - see ReynardAVPlayerNotifyMetadata
/// in AVPlayerDecoder.mm - but a key session is never in one any more,
/// which is the whole reason this file changed.)
final class ContentKeyDelegate: NSObject, AVContentKeySessionDelegate {
    private let playerId: UInt
    /// Nil until the page hands one over, which is the NORMAL state for
    /// the first key request: AVFoundation reaches EXT-X-KEY well
    /// before the page has built its MediaKeys.
    private var appCertificate: Data?
    /// Live requests by content id - the skd:// URI for HLS, base64 of
    /// the raw key id for fragmented MP4. The same encoding
    /// FairPlayCDMProxy keys by, which is what lets the two sides agree
    /// without inventing a request id to echo.
    private var requests: [String: AVContentKeyRequest] = [:]
    /// Content ids whose request is waiting for a certificate.
    private var awaitingCertificate: [String] = []

    /// Content ids whose current AVContentKeyRequest has already attempted
    /// SPC generation. A request gets exactly ONE attempt - a second
    /// makeStreamingContentKeyRequestData on a request already awaiting
    /// or holding its response fails with AVFoundationErrorDomain -11879.
    ///
    /// Reset only when AVFoundation supplies a different request object
    /// for the same content id. Applying a CKC completes the exchange but
    /// does not make that answered request eligible for another SPC.
    private var spcIssued = Set<String>()

    init(playerId: UInt) {
        self.playerId = playerId
    }

    /// The one encoding both processes key by.
    static func contentIdKey(for request: AVContentKeyRequest) -> String? {
        if let string = request.identifier as? String { return string }
        if let data = request.identifier as? Data {
            // Raw key-id bytes are rarely valid UTF-8, so base64 rather
            // than a string decode that would usually yield nil.
            return data.base64EncodedString()
        }
        return nil
    }

    func setAppCertificate(_ certificate: Data) {
        appCertificate = certificate
        avLog("app certificate set for player \(playerId), "
              + "\(certificate.count) bytes")
        let pending = awaitingCertificate
        awaitingCertificate = []
        for contentId in pending {
            guard let request = requests[contentId] else { continue }
            makeSPC(for: request, contentId: contentId)
        }
    }

    /// generateRequest() from the page. If the asset already raised a
    /// request for this identifier - the usual case, since the page is
    /// replying to the 'encrypted' event that came out of it - the held
    /// request is used rather than asking AVFoundation for a duplicate.
    func generateRequest(contentId: String, initDataType: String,
                         initData: Data, session: AVContentKeySession) {
        if let existing = requests[contentId] {
            avLog("generateRequest adopting the held request for \(contentId)")
            makeSPC(for: existing, contentId: contentId)
            return
        }
        let identifier: Any = initDataType == "skd"
            ? (String(data: initData, encoding: .utf8) ?? contentId)
            : initData
        avLog("generateRequest asking AVFoundation for \(contentId)")
        session.processContentKeyRequest(withIdentifier: identifier,
                                         initializationData: initData,
                                         options: nil)
    }

    func provideResponse(_ ckc: Data, contentId: String) {
        guard let request = requests[contentId] else {
            avLog("CKC for \(contentId) with no pending request")
            return
        }
        request.processContentKeyResponse(
            AVContentKeyResponse(fairPlayStreamingKeyResponseData: ckc))
        avLog("CKC applied for \(contentId), \(ckc.count) bytes")
    }

    private func makeSPC(for request: AVContentKeyRequest,
                         contentId: String) {
        guard let certificate = appCertificate else {
            // HELD, not failed. Failing a key request does not decline
            // one key, it fails the WHOLE ITEM permanently - and the
            // certificate is still on its way, because the page cannot
            // call setServerCertificate until it has handled the
            // 'encrypted' event this same request just raised.
            if !awaitingCertificate.contains(contentId) {
                awaitingCertificate.append(contentId)
            }
            avLog("no app certificate yet - holding \(contentId)")
            return
        }
        // Exactly one SPC per key request. Both the certificate flush
        // and the page's generateRequest reach here for the same held
        // request; whichever arrives second would fail with -11879.
        if spcIssued.contains(contentId) {
            avLog("SPC already issued for \(contentId) - not asking twice")
            return
        }
        spcIssued.insert(contentId)
        // The ASSET ID, not the whole URI. Apple's HLS Catalog With FPS
        // sample (FairPlay Streaming Server SDK,
        // Shared/Managers/ContentKeyDelegate.swift) does exactly this:
        //
        //   let contentKeyIdentifierURL = URL(string: identifierString)
        //   let assetIDString = contentKeyIdentifierURL.host
        //   let assetIDData = assetIDString.data(using: .utf8)
        //   ... contentIdentifier: assetIDData
        //
        // The identifier arrives as skd://<asset-id>, and the asset id
        // is what goes into the SPC's asset-ID TLLV and what the key
        // server matches its key against. Passing the whole skd:// URI
        // produces a well-formed SPC the server answers wrongly or
        // refuses - a failure that looks like a server problem and is
        // not one. The full URI still travels to the page as the
        // 'encrypted' init data, which is what a KSM protocol wants as
        // its "uri" field.
        let contentIdData: Data?
        var contentIdForm = "binary"
        if let identifier = request.identifier as? String {
            if FairPlaySPCVersionProbe.configuredUseFullKeyURI {
                // The whole skd:// URI - the string the playlist
                // carries and the string the page sends alongside the
                // challenge.
                contentIdData = Data(identifier.utf8)
                contentIdForm = "full-uri"
            } else {
                let assetId = URL(string: identifier)?.host ?? identifier
                contentIdData = Data(assetId.utf8)
                contentIdForm = "host"
            }
        } else {
            contentIdData = request.identifier as? Data
        }
        // Read per request, not once per process: the preference behind
        // it is a switch in Compatibility, and waiting for a relaunch to
        // observe a knob whose whole purpose is a single A/B against a
        // key server is a needless build cycle.
        let protocolVersion = FairPlaySPCVersionProbe.configuredVersion
        request.makeStreamingContentKeyRequestData(
            forApp: certificate,
            contentIdentifier: contentIdData,
            options: [
                AVContentKeyRequestProtocolVersionsKey: [protocolVersion],
            ]
        ) { spc, error in
            // AVFoundation calls back on its own queue; the C entry
            // point wants Gecko's main thread, which here is this one.
            DispatchQueue.main.async {
                guard let spc = spc, error == nil else {
                    avLog("SPC FAILED for \(contentId) at protocol version "
                          + "\(protocolVersion): "
                          + "\(error?.localizedDescription ?? "no data")")
                    // ADDED - see fix_spc_gate_clears_on_failure.py's
                    // docstring. This used to log and return, which left
                    // the content id in spcIssued on a request that has
                    // no SPC and was never failed. Nothing else clears
                    // it: the only spcIssued.remove is the isNewRequest
                    // one in didProvide below, and AVFoundation raises
                    // no replacement request for one it was never told
                    // had failed. Every later generateRequest then
                    // adopts the same held request and stops at "SPC
                    // already issued" - the key blocked for the life of
                    // the item, and silently.
                    //
                    // Identity-guarded: this callback comes off
                    // AVFoundation's queue via the hop above, so by the
                    // time it lands didProvide may already have
                    // installed a NEWER request for this content id and
                    // cleared the gate for it. Clearing it again would
                    // let that one issue two SPCs, which is the -11879
                    // the gate exists to prevent.
                    guard self.requests[contentId] === request else {
                        return
                    }
                    self.spcIssued.remove(contentId)
                    // Dropped so the next generateRequest asks
                    // AVFoundation for a fresh request instead of
                    // adopting this one. Re-attempting on a request
                    // whose SPC generation failed is not a retry.
                    self.requests.removeValue(forKey: contentId)
                    // Unlike the "no certificate yet" hold above, this
                    // request cannot be satisfied by anything that
                    // arrives later - its SPC never existed. Left
                    // pending it stalls the item anyway AND blocks a
                    // replacement, so telling AVFoundation is the
                    // cheaper failure. Same call, same reasoning, as the
                    // certificate-missing path in
                    // FairPlayCDMProxy.mm.patch.
                    let failure: Error = error ?? NSError(
                        domain: "ReynardFairPlay",
                        code: -4,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "SPC generation returned no data",
                        ])
                    request.processContentKeyResponseError(failure)
                    return
                }
                // The byte count is the only thing tying this line to the
                // content process's "webkitkeymessage, N bytes", and the
                // content id is the only thing saying which key it is
                // about once rotation is in play. Both have been
                // load-bearing in every capture in this series.
                let encodedDescription =
                    FairPlaySPCVersionProbe.describeEncodedVersion(in: spc)
                avLog("SPC ready for \(contentId), \(spc.count) bytes, "
                      + "requested protocol version \(protocolVersion), "
                      + "encoded protocol version " + encodedDescription
                      + ", content id " + contentIdForm)
                spc.withUnsafeBytes { raw in
                    ReynardFairPlayNotifyKeyMessage(
                        self.playerId, contentId,
                        raw.bindMemory(to: UInt8.self).baseAddress, raw.count)
                }
            }
        }
    }

    func contentKeySession(_ session: AVContentKeySession,
                           didProvide keyRequest: AVContentKeyRequest) {
        guard let contentId = Self.contentIdKey(for: keyRequest) else {
            avLog("content key request with an identifier we cannot key by")
            return
        }
        let isNewRequest = requests[contentId] !== keyRequest
        requests[contentId] = keyRequest
        // Only a genuinely new request object is entitled to another SPC.
        // A duplicate callback for the same object keeps the one-shot gate.
        if isNewRequest {
            spcIssued.remove(contentId)
        }
        avLog("content key requested for \(contentId) on player \(playerId)")

        // The page has to hear about this as an 'encrypted' event.
        // Nothing else can raise one: Gecko's demuxer never sees this
        // stream, so this delegate is the only source there is - and
        // that event is what eventually produces both the certificate
        // and the licence.
        let initDataType: String
        let initData: Data
        if let skd = keyRequest.identifier as? String {
            initDataType = "skd"
            initData = Data(skd.utf8)
        } else {
            initDataType = "sinf"
            initData = (keyRequest.identifier as? Data) ?? Data()
        }
        initData.withUnsafeBytes { raw in
            ReynardFairPlayNotifyEncrypted(
                playerId, initDataType,
                raw.bindMemory(to: UInt8.self).baseAddress, raw.count)
        }

        // Attempted immediately in case the certificate is already
        // here - a second protected element on a page that has already
        // negotiated once arrives in exactly that order.
        //
        // What used to be here was processContentKeyResponseError -
        // "No FairPlay licence server configured" - which failed the
        // request outright. That does not decline one key; it fails the
        // WHOLE ITEM, permanently, which is the Code=-1 itemStatus=2
        // every protected stream ended on.
        makeSPC(for: keyRequest, contentId: contentId)
    }

    /// A key ROTATION - the stream moved to a new key mid-playback,
    /// which every long-form service does. Same handling: the page gets
    /// another 'encrypted', asks for another licence, and the new key
    /// replaces the old one. Without this the picture freezes at the
    /// first key change, which is minutes into a film rather than at
    /// its start, so it is the kind of gap that looks like a different
    /// bug entirely.
    func contentKeySession(
        _ session: AVContentKeySession,
        didProvideRenewingContentKeyRequest keyRequest: AVContentKeyRequest
    ) {
        contentKeySession(session, didProvide: keyRequest)
    }

    /// Worth retrying, unlike a native app's: the licence round trip
    /// here crosses to another process, out to the page's JavaScript,
    /// over the network to a key server, and all the way back. A
    /// timeout on that path says "slow", not "refused".
    func contentKeySession(_ session: AVContentKeySession,
                           shouldRetry keyRequest: AVContentKeyRequest,
                           reason: AVContentKeyRequest.RetryReason) -> Bool {
        switch reason {
        case .timedOut, .receivedResponseWithExpiredLease,
             .receivedObsoleteContentKey:
            avLog("retrying a content key request - \(reason.rawValue)")
            return true
        default:
            return false
        }
    }

    func contentKeySession(_ session: AVContentKeySession,
                           contentKeyRequest keyRequest: AVContentKeyRequest,
                           didFailWithError err: Error) {
        avLog("content key request failed - \(err)")
    }
}
