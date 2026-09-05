//
//  PictureInPictureCoordinator.swift
//  Reynard
//
//  Created by Minh Ton on 16/7/26.
//

import AVFoundation

// REYNARD - see fix_pip_log_to_stdout.py's docstring. This file used to
// log its eligibility refusals through
//
//     private let pipLog = OSLog(subsystem: "com.minh-ton.Reynard",
//                                category: "PiPDebug")
//
// which reaches Console.app and `log stream` and NOT reynard_stdout.txt.
// Every capture taken while PiP failed to arm therefore carried no
// reason, and the only remaining signal was the absence of the
// `pipLife:` lines below - which is a weak enough inference that it led
// to a wrong diagnosis on capture 68ad15df.
//
// The refusals now go through logger(), the same call the `pipLife:`
// lines already use and the reason those show up. Prefixed `pipGate:`
// so a grep can take the two together or apart.
import AVKit
import Foundation
import GeckoView
import UIKit

protocol PictureInPictureCoordinating: AnyObject {
    func selectedSessionDidChange()
    func navigationStarted(in session: GeckoSession)
}

@available(iOS 15.0, *)
protocol PictureInPictureCoordinatorDelegate: AnyObject {
    func pictureInPictureCoordinator(
        _ coordinator: PictureInPictureCoordinator,
        restore session: GeckoSession
    ) -> Bool
}

@available(iOS 15.0, *)
final class PictureInPictureCoordinator: NSObject, PictureInPictureCoordinating {
    private struct EligibleSession {
        let session: GeckoSession
        let displayLayer: CALayer
        let positionState: MediaSessionPositionState
        let supportsSeeking: Bool
    }
    
    private final class Presentation {
        let session: GeckoSession
        var displayLayer: CALayer
        let controller: AVPictureInPictureController
        var wasStopRequested = false
        var pauseGeneration = 0
        
        init(
            session: GeckoSession,
            displayLayer: CALayer,
            controller: AVPictureInPictureController
        ) {
            self.session = session
            self.displayLayer = displayLayer
            self.controller = controller
        }
    }
    
    private enum State {
        case idle
        case prepared(Presentation)
        case starting(Presentation)
        case active(Presentation)
        case stopping(Presentation)
        
        var presentation: Presentation? {
            switch self {
            case .idle:
                return nil
            case let .prepared(presentation),
                let .starting(presentation),
                let .active(presentation),
                let .stopping(presentation):
                return presentation
            }
        }
    }
    
    private weak var delegate: PictureInPictureCoordinatorDelegate?
    private let mediaSession: SystemMediaSession
    private let sessionManager: SessionManager
    /// Hold a swapped-out display layer for a moment.
    ///
    /// ADDED - see mse_fix_169's docstring. Three seconds is far longer
    /// than a main-queue drain and far shorter than anything a viewer
    /// would notice; the layer carries no frame memory once the parser
    /// has stopped feeding it.
    private func reynardRetire(_ layer: CALayer) {
        reynardRetiredLayers.append(layer)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self else { return }
            if let index = self.reynardRetiredLayers.firstIndex(
                where: { $0 === layer }) {
                self.reynardRetiredLayers.remove(at: index)
            }
        }
    }

    private var state = State.idle
    private weak var observedSession: GeckoSession?
    private var isAwaitingAutomaticStart = false
    /// Display layers this coordinator has swapped away from, held
    /// briefly so AVKit's in-flight observations do not land on freed
    /// memory.
    ///
    /// ADDED - see mse_fix_169's docstring. Replacing contentSource
    /// drops the only strong reference this app holds to the outgoing
    /// layer, and Gecko has already released its own, so it dies while
    /// AVKit still has a KVO block queued against it - which is the
    /// EXC_BAD_ACCESS in objc_retain under
    /// AVPictureInPicturePlatformAdapter.
    private var reynardRetiredLayers: [CALayer] = []
    private var backgroundObservationToken: NSObjectProtocol?
    
    init?(
        delegate: PictureInPictureCoordinatorDelegate,
        mediaSession: SystemMediaSession,
        sessionManager: SessionManager
    ) {
        guard AVPictureInPictureController.isPictureInPictureSupported() else {
            return nil
        }
        self.delegate = delegate
        self.mediaSession = mediaSession
        self.sessionManager = sessionManager
        super.init()
        mediaSession.observer = self
        sessionManager.applicationStateObserver = self
        sessionManager.pictureInPictureHandler = self
        // Auto-start that never happens must not keep a session fully
        // active for the whole background stay - see
        // disarmAutomaticStartIfItNeverHappened().
        backgroundObservationToken = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.disarmAutomaticStartIfItNeverHappened()
        }
    }

    deinit {
        if let backgroundObservationToken {
            NotificationCenter.default.removeObserver(backgroundObservationToken)
        }
    }
    
    func selectedSessionDidChange() {
        if let presentation = state.presentation,
           mediaSession.selectedSnapshot?.session !== presentation.session {
            stopPresentation()
        }
        observeSelectedSession()
        updatePresentation()
    }
    
    func navigationStarted(in session: GeckoSession) {
        guard mediaSession.selectedSnapshot?.session === session ||
                state.presentation?.session === session else {
            return
        }
        stopPresentation()
    }
    
    private func observeSelectedSession() {
        let selectedSession = mediaSession.selectedSnapshot?.session
        guard observedSession !== selectedSession else {
            return
        }
        observedSession?.pictureInPictureDelegate = nil
        observedSession = selectedSession
        observedSession?.pictureInPictureDelegate = self
    }
    
    private func updatePresentation() {
        let isPresentationActive =
        state.presentation?.controller.isPictureInPictureActive == true
        guard !isAwaitingAutomaticStart,
              sessionManager.isForeground || isPresentationActive else {
            return
        }
        switch state {
        case .idle:
            guard let eligibleSession = eligibleSession() else {
                return
            }
            prepare(eligibleSession)
        case let .prepared(presentation):
            guard let snapshot = mediaSession.selectedSnapshot,
                  snapshot.session === presentation.session,
                  snapshot.playbackState == .playing,
                  let displayLayer =
                    presentation.session.pictureInPictureDisplayLayer else {
                stopPresentation()
                return
            }
            if displayLayer !== presentation.displayLayer {
                guard let positionState = snapshot.positionState,
                      isValid(positionState) else {
                    stopPresentation()
                    return
                }
                if let playerLayer = displayLayer as? AVPlayerLayer {
                    reynardRetire(presentation.displayLayer)
                    presentation.displayLayer = displayLayer
                    presentation.controller.contentSource =
                    AVPictureInPictureController.ContentSource(
                        playerLayer: playerLayer
                    )
                } else if let sampleLayer =
                            displayLayer as? AVSampleBufferDisplayLayer {
                    guard synchronizeTimebase(
                        of: sampleLayer, with: positionState
                    ) else {
                        stopPresentation()
                        return
                    }
                    reynardRetire(presentation.displayLayer)
                    presentation.displayLayer = displayLayer
                    presentation.controller.contentSource =
                    AVPictureInPictureController.ContentSource(
                        sampleBufferDisplayLayer: sampleLayer,
                        playbackDelegate: self
                    )
                } else {
                    stopPresentation()
                    return
                }
            }
            updatePlayback(of: presentation, with: snapshot)
        case let .starting(presentation), let .active(presentation):
            guard let snapshot = mediaSession.selectedSnapshot,
                  snapshot.session === presentation.session,
                  snapshot.playbackState != .none else {
                stopPresentation()
                return
            }
            updatePlayback(of: presentation, with: snapshot)
        case .stopping:
            break
        }
    }
    
    private func eligibleSession() -> EligibleSession? {
        // WebKit's WebAVPlayerController policy: a player on an AirPlay
        // receiver has no picture to put in a window, and the two
        // presentations fight over who owns the video. The existing 3s
        // stand-down (disarmAutomaticStartIfItNeverHappened) handles an
        // auto-start refused here.
        guard !AVPlayerHost.shared.isAnyExternalPlaybackActive else {
            logger("pipGate: an AVPlayer is in external playback - PiP and AirPlay video are mutually exclusive")
            return nil
        }
        guard let snapshot = mediaSession.selectedSnapshot else {
            logger("pipGate: no selectedSnapshot - nothing is registered as playing")
            return nil
        }
        guard snapshot.playbackState == .playing else {
            logger("pipGate: playbackState is \(String(describing: snapshot.playbackState)), not .playing")
            return nil
        }
        guard let displayLayer = snapshot.session.pictureInPictureDisplayLayer else {
            logger("pipGate: pictureInPictureDisplayLayer is nil - the compositor is offering no PiP source")
            return nil
        }
        guard let positionState = snapshot.positionState else {
            logger("pipGate: positionState is nil")
            return nil
        }
        guard isValid(positionState) else {
            logger("pipGate: positionState failed isValid - needs a finite duration > 0, a position within it, and a rate > 0")
            return nil
        }
        logger("pipGate: all checks passed - the session is eligible")
        return EligibleSession(
            session: snapshot.session,
            displayLayer: displayLayer,
            positionState: positionState,
            supportsSeeking: snapshot.supportsSeeking
        )
    }
    
    private func prepare(_ eligibleSession: EligibleSession) {
        guard eligibleSession.session.pictureInPictureDisplayLayer ===
                eligibleSession.displayLayer else {
            return
        }
        guard let controller = makeController(for: eligibleSession) else {
            return
        }
        controller.delegate = self
        controller.requiresLinearPlayback = !eligibleSession.supportsSeeking
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        state = .prepared(Presentation(
            session: eligibleSession.session,
            displayLayer: eligibleSession.displayLayer,
            controller: controller
        ))
    }
    
    /// Protected video reaches us as an AVPlayerLayer, because a FairPlay
    /// frame cannot be read by the CPU and AVFoundation has to draw it
    /// itself. AVKit has a dedicated entry point for that layer class: the
    /// controller talks to the AVPlayer directly, so it needs neither a
    /// playback delegate nor a control timebase to drive - both of which
    /// are AVSampleBufferDisplayLayer concepts. Sending controlTimebase to
    /// an AVPlayerLayer is an unrecognised selector, and it threw right as
    /// the page entered fullscreen.
    private func makeController(
        for eligibleSession: EligibleSession
    ) -> AVPictureInPictureController? {
        if let playerLayer = eligibleSession.displayLayer as? AVPlayerLayer {
            return AVPictureInPictureController(
                contentSource: AVPictureInPictureController.ContentSource(
                    playerLayer: playerLayer
                )
            )
        }
        guard let displayLayer =
                eligibleSession.displayLayer as? AVSampleBufferDisplayLayer,
              synchronizeTimebase(
                of: displayLayer,
                with: eligibleSession.positionState
              ) else {
            return nil
        }
        let contentSource = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: displayLayer,
            playbackDelegate: self
        )
        return AVPictureInPictureController(contentSource: contentSource)
    }

    private func updatePlayback(
        of presentation: Presentation,
        with snapshot: SystemMediaSession.Snapshot
    ) {
        if let positionState = snapshot.positionState, isValid(positionState),
           let sampleLayer =
            presentation.displayLayer as? AVSampleBufferDisplayLayer {
            // An AVPlayerLayer has no control timebase; its player already
            // carries the timing AVKit reads.
            _ = synchronizeTimebase(
                of: sampleLayer,
                with: positionState,
                isPaused: snapshot.playbackState == .paused
            )
        }
        presentation.controller.requiresLinearPlayback =
        !snapshot.supportsSeeking
        presentation.controller.invalidatePlaybackState()
    }
    
    private func isValid(_ positionState: MediaSessionPositionState) -> Bool {
        return positionState.duration.isFinite &&
        positionState.duration > 0 &&
        positionState.position.isFinite &&
        positionState.position >= 0 &&
        positionState.position <= positionState.duration &&
        positionState.playbackRate.isFinite &&
        positionState.playbackRate > 0
    }
    
    private func synchronizeTimebase(
        of displayLayer: AVSampleBufferDisplayLayer,
        with positionState: MediaSessionPositionState,
        isPaused: Bool = false
    ) -> Bool {
        guard let timebase = displayLayer.controlTimebase else {
            return false
        }
        guard CMTimebaseSetTime(
            timebase,
            time: CMTime(seconds: positionState.position, preferredTimescale: 600)
        ) == noErr else {
            return false
        }
        return CMTimebaseSetRate(
            timebase,
            rate: isPaused ? 0 : positionState.playbackRate
        ) == noErr
    }
    
    /// willResignActive arms automatic PiP: it marks the prepared
    /// session as THE Picture in Picture session, which keeps it fully
    /// active - compositing, unthrottled - while the app is
    /// backgrounded, on the assumption iOS is about to start PiP for
    /// it. When iOS declines (auto-PiP has its own eligibility rules
    /// and frequently does), willStart never fires and nothing cleared
    /// the arming until the next foreground: the session spent the
    /// entire background stay fully active, with the audio session
    /// held alongside it. Give auto-start a grace period after the
    /// background transition, then stand down via the same call the
    /// foreground path already uses for this exact stale state. See
    /// fix_disarm_pip_autostart_when_pip_never_starts.py.
    ///
    /// .prepared + the flag still set can only mean "never started":
    /// willStart clears the flag and moves the state to .starting
    /// before anything else happens.
    private func disarmAutomaticStartIfItNeverHappened() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            guard let self,
                  self.isAwaitingAutomaticStart,
                  case let .prepared(presentation) = self.state,
                  !self.sessionManager.isForeground,
                  !presentation.controller.isPictureInPictureActive else {
                return
            }
            logger("pipLife: auto-start never happened - standing down, releasing the session")
            self.isAwaitingAutomaticStart = false
            self.sessionManager.pictureInPicturePresentationDidEnd(presentation.session)
        }
    }

    private func stopPresentation() {
        isAwaitingAutomaticStart = false
        switch state {
        case .idle:
            break
        case let .prepared(presentation):
            finishPresentation(presentation)
        case let .starting(presentation), let .active(presentation):
            presentation.wasStopRequested = true
            state = .stopping(presentation)
            presentation.controller.stopPictureInPicture()
        case let .stopping(presentation):
            presentation.wasStopRequested = true
        }
    }
    
    private func finishPresentation(
        for controller: AVPictureInPictureController
    ) {
        guard let presentation = presentation(for: controller) else {
            return
        }
        if !sessionManager.isForeground {
            presentation.session.mediaSession.pause()
        }
        finishPresentation(presentation)
        DispatchQueue.main.async { [weak self] in
            self?.updatePresentation()
        }
    }
    
    private func finishPresentation(_ presentation: Presentation) {
        presentation.controller.delegate = nil
        state = .idle
        sessionManager.pictureInPicturePresentationDidEnd(
            presentation.session
        )
    }
    
    private func presentation(
        for controller: AVPictureInPictureController
    ) -> Presentation? {
        guard let presentation = state.presentation,
              presentation.controller === controller else {
            return nil
        }
        return presentation
    }
}

@available(iOS 15.0, *)
extension PictureInPictureCoordinator: SystemMediaSessionObserver {
    func systemMediaSessionStateDidChange(_ mediaSession: SystemMediaSession) {
        observeSelectedSession()
        updatePresentation()
    }
}

@available(iOS 15.0, *)
extension PictureInPictureCoordinator: SessionManagerApplicationStateObserver {
    func sessionManagerDidChangeApplicationState(
        _ sessionManager: SessionManager
    ) {
        guard sessionManager.isForeground else {
            return
        }
        if isAwaitingAutomaticStart {
            isAwaitingAutomaticStart = false
            if let presentation = state.presentation {
                sessionManager.pictureInPicturePresentationDidEnd(
                    presentation.session
                )
            }
        }
        updatePresentation()
    }
    
    func sessionManagerWillResignActive(_ sessionManager: SessionManager) {
        updatePresentation()
        guard case let .prepared(presentation) = state,
              presentation.controller.isPictureInPicturePossible else {
            return
        }
        isAwaitingAutomaticStart = true
        sessionManager.setPictureInPictureSession(presentation.session)
    }
}

@available(iOS 15.0, *)
extension PictureInPictureCoordinator: SessionManagerPictureInPictureHandler {
    func stopPresenting(_ session: GeckoSession) -> Bool {
        guard state.presentation?.session === session else {
            return false
        }
        stopPresentation()
        return true
    }
}

@available(iOS 15.0, *)
extension PictureInPictureCoordinator: PictureInPictureDelegate {
    func onSourceChanged(session: GeckoSession) {
        guard observedSession === session else {
            return
        }
        updatePresentation()
    }
}

@available(iOS 15.0, *)
extension PictureInPictureCoordinator:
    AVPictureInPictureSampleBufferPlaybackDelegate {
    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        setPlaying isPlaying: Bool
    ) {
        guard let presentation = presentation(
            for: pictureInPictureController
        ) else {
            return
        }
        presentation.pauseGeneration += 1
        if isPlaying {
            presentation.session.mediaSession.play()
        } else {
            let pauseGeneration = presentation.pauseGeneration
            DispatchQueue.main.async { [weak presentation] in
                guard let presentation,
                      presentation.pauseGeneration == pauseGeneration else {
                    return
                }
                presentation.session.mediaSession.pause()
            }
        }
    }
    
    func pictureInPictureControllerTimeRangeForPlayback(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> CMTimeRange {
        guard let presentation = presentation(
            for: pictureInPictureController
        ),
              let snapshot = mediaSession.selectedSnapshot,
              snapshot.session === presentation.session,
              let positionState = snapshot.positionState,
              positionState.duration.isFinite,
              positionState.duration > 0 else {
            return .invalid
        }
        return CMTimeRange(
            start: .zero,
            duration: CMTime(
                seconds: positionState.duration,
                preferredTimescale: 600
            )
        )
    }
    
    func pictureInPictureControllerIsPlaybackPaused(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> Bool {
        guard let presentation = presentation(
            for: pictureInPictureController
        ),
              let snapshot = mediaSession.selectedSnapshot,
              snapshot.session === presentation.session else {
            return true
        }
        return snapshot.playbackState != .playing
    }
    
    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        didTransitionToRenderSize newRenderSize: CMVideoDimensions
    ) {}
    
    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        skipByInterval skipInterval: CMTime,
        completion completionHandler: @escaping () -> Void
    ) {
        guard let presentation = presentation(
            for: pictureInPictureController
        ),
              let snapshot = mediaSession.selectedSnapshot,
              snapshot.session === presentation.session,
              snapshot.supportsSeeking,
              let positionState = snapshot.positionState,
              positionState.duration.isFinite,
              positionState.duration > 0,
              let sampleLayer =
                presentation.displayLayer as? AVSampleBufferDisplayLayer,
              let timebase = sampleLayer.controlTimebase else {
            completionHandler()
            return
        }
        let skipSeconds = CMTimeGetSeconds(skipInterval)
        let currentSeconds = CMTimeGetSeconds(CMTimebaseGetTime(timebase))
        guard skipSeconds.isFinite, currentSeconds.isFinite else {
            completionHandler()
            return
        }
        presentation.pauseGeneration += 1
        let targetSeconds = min(
            max(currentSeconds + skipSeconds, 0), positionState.duration
        )
        if snapshot.features.contains(.seekTo) {
            presentation.session.mediaSession.seekTo(time: targetSeconds)
        } else if skipSeconds > 0 {
            presentation.session.mediaSession.seekForward(offset: skipSeconds)
        } else if skipSeconds < 0 {
            presentation.session.mediaSession.seekBackward(offset: -skipSeconds)
        }
        let playbackRate = snapshot.playbackState == .playing ?
        positionState.playbackRate : 0
        _ = CMTimebaseSetTime(
            timebase,
            time: CMTime(seconds: targetSeconds, preferredTimescale: 600)
        )
        _ = CMTimebaseSetRate(timebase, rate: playbackRate)
        completionHandler()
        presentation.pauseGeneration += 1
    }
}

@available(iOS 15.0, *)
extension PictureInPictureCoordinator: AVPictureInPictureControllerDelegate {
    func pictureInPictureControllerWillStartPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        guard case let .prepared(presentation) = state,
              presentation.controller === pictureInPictureController else {
            return
        }
        logger("pipLife: willStart - handing the session to PiP")
        isAwaitingAutomaticStart = false
        state = .starting(presentation)
        sessionManager.setPictureInPictureSession(presentation.session)
    }
    
    func pictureInPictureControllerDidStartPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        guard case let .starting(presentation) = state,
              presentation.controller === pictureInPictureController else {
            logger("pipLife: didStart IGNORED - not in .starting for this controller")
            return
        }
        logger("pipLife: didStart - PiP is now active, its content process must stay alive in the background")
        state = .active(presentation)
    }
    
    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error
    ) {
        logger("pipLife: failedToStart - \(error)")
        NSLog("Failed to start Picture in Picture: \(error)")
        finishPresentation(for: pictureInPictureController)
    }
    
    func pictureInPictureControllerWillStopPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        guard let presentation = presentation(
            for: pictureInPictureController
        ) else {
            logger("pipLife: willStop IGNORED - no presentation for this controller")
            return
        }
        logger("pipLife: willStop")
        state = .stopping(presentation)
    }
    
    func pictureInPictureControllerDidStopPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        logger("pipLife: didStop")
        finishPresentation(for: pictureInPictureController)
    }
    
    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        // The reattach. This is the transition the watchdog kills are
        // being attributed to, so it is bracketed: if the delegate call
        // is where the time goes, the two lines will be seconds apart,
        // and if they are adjacent the block is elsewhere.
        guard let presentation = presentation(
            for: pictureInPictureController
        ),
              !presentation.wasStopRequested else {
            logger("pipLife: restore DECLINED - no presentation, or stop was requested")
            completionHandler(false)
            return
        }
        logger("pipLife: restore STARTED - reattaching the session to the page")
        let restored = delegate?.pictureInPictureCoordinator(
            self,
            restore: presentation.session
        ) == true
        logger(String(format: "pipLife: restore FINISHED - restored=%@", restored ? "YES" : "NO"))
        completionHandler(restored)
    }
}
