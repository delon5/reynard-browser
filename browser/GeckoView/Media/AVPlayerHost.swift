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

    /// Players by opaque id. The decoder holds only the id, so a player
    /// outliving its decoder - or the reverse - cannot dereference
    /// anything freed.
    private var players: [UInt: Player] = [:]
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
    /// LIMITATION, deliberately not hidden: this is the most RECENT
    /// session, not one bound per decoder, because
    /// MediaDecoder::SetCDMProxy is not virtual and AVPlayerDecoder has
    /// no hook to reach its own proxy through. With a single protected
    /// element playing - all this pipeline supports today - that is the
    /// same pairing. Two protected elements at once would attach the
    /// second one's asset to the first one's session; fixing that
    /// properly needs SetCDMProxy made virtual.
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
        delegate.provideResponse(response, contentId: contentId)
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

        let entry = Player(player: player, item: item, asset: asset,
                           keySession: keySession, delegate: delegate)
        withState { players[id] = entry }

        observeMetadata(of: item, playerId: id, storingInto: entry)
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
            noteIdleTick()
            return
        }
        guard let buffer = output.copyPixelBuffer(forItemTime: itemTime,
                                                  itemTimeForDisplay: nil)
        else {
            report("copyPixelBuffer returned nil")
            noteIdleTick()
            return
        }

        withState { entry.idlePullTicks = 0 }
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
        guard let entry = withState({ () -> Player? in
            players[id]?.wantsPlayback = true
            return players[id]
        }) else {
            return
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
        guard let entry = withState({ players[id] }) else {
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
        guard let entry = withState({ players[id] }),
              withState({ entry.wantsPlayback }) else {
            return
        }
        resumeFrameDelivery(for: entry)
        entry.player.play()
    }

    /// Un-pauses the pull link and resets the idle counter. Every path
    /// that can make frames flow again routes through here: play,
    /// resume, seek, and the readiness replay in observeMetadata.
    private func resumeFrameDelivery(for entry: Player) {
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

    @objc public func destroy(_ id: UInt) {
        avLog("HOST destroy(\(id))")
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
        entry.player.pause()
        entry.player.replaceCurrentItem(with: nil)
        entry.keySession.removeContentKeyRecipient(entry.asset)
        avLog("destroyed \(id)")
    }

    /// The layer the compositor will hand us once NativeLayerCA builds an
    /// AVPlayerLayer for the DRM-marked surface. Until that lands the
    /// player renders nowhere, which is expected.
    @objc public func attachLayer(_ layer: AVPlayerLayer, to id: UInt) {
        guard let entry = withState({ players[id] }) else {
            return
        }
        layer.player = entry.player
        avLog("attached layer to \(id)")
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

    @objc public func seek(_ id: UInt, to seconds: Double) {
        guard let entry = withState({ players[id] }) else {
            return
        }
        // A seek while PAUSED still has to repaint at the new position,
        // and the link may be parked. The idle backstop parks it again
        // once the frame has been shown and nothing further arrives, so
        // this does not leave it running.
        resumeFrameDelivery(for: entry)
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
        if let identifier = request.identifier as? String {
            let assetId = URL(string: identifier)?.host ?? identifier
            contentIdData = Data(assetId.utf8)
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
                      + "encoded protocol version " + encodedDescription)
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
