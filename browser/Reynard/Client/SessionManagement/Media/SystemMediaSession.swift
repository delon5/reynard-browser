//
//  SystemMediaSession.swift
//  Reynard
//
//  Created by Minh Ton on 9/4/26.
//

import AVFoundation
import Foundation
import GeckoView
import MediaPlayer
import UIKit

protocol SystemMediaSessionObserver: AnyObject {
    func systemMediaSessionStateDidChange(_ mediaSession: SystemMediaSession)
}

final class SystemMediaSession: MediaSessionDelegate {
    private static let maxArtworkBytes = 8 * 1024 * 1024
    private static let maxArtworkPixelCount = 4 * 1024 * 1024
    private static let maxArtworkDimension = 2_048
    private static let artworkNetworkConfiguration: URLSessionConfiguration = {
        let configuration = URLSessionConfiguration.default
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 20
        return configuration
    }()

    /// The one instance. See fix_carplay_media_session.py.
    ///
    /// Shared rather than owned by TabManagerImpl because the CarPlay
    /// session needs it too, and cannot rely on the phone's scene
    /// existing - CarPlay can connect first.
    ///
    /// A second instance would be actively harmful:
    /// MPNowPlayingInfoCenter.default() and
    /// MPRemoteCommandCenter.shared() are process-wide, so two owners
    /// would fight over the same command targets.
    static let shared = SystemMediaSession()
    
    /// Posted on the main queue when the SELECTED tab's playback state
    /// changes - including from "no media at all" to .none, which is
    /// the first callback a page's media makes. The AirPlay chrome
    /// (page-menu row, pill) keys on the selected tab having played
    /// and on it playing now, and nothing else it can observe fires
    /// when media starts on a page that has finished loading.
    ///
    /// Deliberately NOT posted from every observer call:
    /// onPositionState reaches notifyStateChanged several times a
    /// second, and the observer protocol is PiP's, which wants those.
    static let selectedPlaybackStateDidChange =
        Notification.Name("Reynard.SystemMediaSessionSelectedPlaybackStateDidChange")
    
    enum PlaybackState {
        case none
        case paused
        case playing
    }
    
    private final class SessionState {
        weak var session: GeckoSession?
        var nowPlayingInfo: [String: Any] = [:]
        var features: MediaSessionFeatures = [.seekForward, .seekBackward, .seekTo]
        var artworkTask: BoundedURLDataLoader?
        var artworkGeneration: UInt64 = 0
        var playbackState = PlaybackState.none
        var positionState: MediaSessionPositionState?
        
        init(session: GeckoSession) {
            self.session = session
        }
    }
    
    private weak var activeSession: GeckoSession?
    private weak var selectedSession: GeckoSession?
    
    /// A session that outranks the selected tab for the transport
    /// controls. The CarPlay session claims this. See
    /// fix_carplay_media_priority.py.
    ///
    /// Weak, so a disconnected car display does not keep a Gecko
    /// session and its content process alive - and the exemption stops
    /// applying by itself once it is gone.
    weak var prioritySession: GeckoSession?
    private let nowPlayingCenter = MPNowPlayingInfoCenter.default()
    private let commandCenter = MPRemoteCommandCenter.shared()
    private var sessionStates: [ObjectIdentifier: SessionState] = [:]
    private var playbackHistory: [ObjectIdentifier] = []
    private var commandTargets: [Any] = []
    weak var observer: SystemMediaSessionObserver?
    /// What selectedPlaybackStateDidChange last reported; nil means
    /// "no snapshot", which is distinct from a snapshot in .none.
    private var lastPostedSelectedPlaybackState: PlaybackState?
    
    struct Snapshot {
        let session: GeckoSession
        let playbackState: PlaybackState
        let positionState: MediaSessionPositionState?
        let features: MediaSessionFeatures
        
        var supportsSeeking: Bool {
            return features.contains(.seekTo) ||
            (features.contains(.seekForward) && features.contains(.seekBackward))
        }
    }
    
    var selectedSnapshot: Snapshot? {
        guard let selectedSession,
              let state = sessionStates[ObjectIdentifier(selectedSession)] else {
            return nil
        }
        return Snapshot(
            session: selectedSession,
            playbackState: state.playbackState,
            positionState: state.positionState,
            features: state.features
        )
    }
    
    /// Whether the now playing entry currently belongs to a live
    /// session - the card the lock screen and CarPlay drive their
    /// transport controls from.
    ///
    /// ADDED - see fix_background_audio_keeps_jit.py's docstring.
    /// A narrow accessor rather than widening the activeSession
    /// stored property above: the callers that need this are the
    /// identity-independent ones, and handing them the session
    /// object re-opens the `=== tab.session` trap that sleeping a
    /// tab springs. A Bool cannot be compared for identity.
    ///
    /// activeSession is weak, revalidate() drops sessions that died
    /// without reporting, and applicationDidEnterBackground clears it
    /// when nothing is playing or paused - so this goes false on its
    /// own and needs no separate teardown.
    var hasNowPlayingSession: Bool {
        return activeSession != nil
    }
    
    init() {
        registerRemoteCommands()
        apply(MediaSessionFeatures())
    }
    
    deinit {
        if activeSession != nil {
            nowPlayingCenter.nowPlayingInfo = nil
        }
        sessionStates.values.forEach { $0.artworkTask?.cancel() }
        unregisterRemoteCommands()
    }
    
    func onActivated(session: GeckoSession) {
        _ = state(for: session)
        notifyStateChanged(for: session)
    }
    
    func onDeactivated(session: GeckoSession) {
        let identifier = ObjectIdentifier(session)
        let wasActive = activeSession === session
        
        // Whether this fires at all is the first thing worth knowing: a
        // slept tab should reach here, and a deallocated one never does.
        // See fix_log_media_session_activity.py.
        let deactivatingTitle = (sessionStates[identifier]?.nowPlayingInfo[MPMediaItemPropertyTitle] as? String) ?? "(untitled)"
        logger(String(format: "mediaSession: onDeactivated %@ (wasActive=%@)", deactivatingTitle, wasActive ? "YES" : "NO"))
        sessionStates.removeValue(forKey: identifier)?.artworkTask?.cancel()
        playbackHistory.removeAll { $0 == identifier }
        
        if wasActive {
            activateMostRecentPlayingSession()
        }
        if selectedSession === session {
            observer?.systemMediaSessionStateDidChange(self)
            postSelectedPlaybackStateIfChanged()
        }
        releaseAudioSessionIfIdleInBackground()
    }
    
    func onMetadata(session: GeckoSession, metadata: MediaSessionMetadata) {
        let state = state(for: session)

        state.artworkTask?.cancel()
        state.artworkTask = nil
        state.artworkGeneration &+= 1
        let artworkGeneration = state.artworkGeneration
        state.nowPlayingInfo.removeValue(forKey: MPMediaItemPropertyArtwork)

        state.nowPlayingInfo[MPMediaItemPropertyTitle] = metadata.title ?? ""
        state.nowPlayingInfo[MPMediaItemPropertyArtist] = metadata.artist ?? ""
        state.nowPlayingInfo[MPMediaItemPropertyAlbumTitle] = metadata.album ?? ""

        if activeSession === session {
            nowPlayingCenter.nowPlayingInfo = state.nowPlayingInfo
        } else if state.playbackState == .playing {
            // Playing already, and a title has only now arrived - so this
            // is the activation that activate() declined earlier for want
            // of metadata. See fix_no_lockscreen_without_metadata.py.
            activate(session, state: state)
        }

        guard let artworkURLString = metadata.artworkUrl,
              let artworkURL = URL(string: artworkURLString) else {
            return
        }

        var request = URLRequest(url: artworkURL)
        request.httpMethod = "GET"
        request.setValue("image/*,*/*;q=0.8", forHTTPHeaderField: "Accept")
        let loader = BoundedURLDataLoader(
            request: request,
            configuration: Self.artworkNetworkConfiguration,
            maximumBytes: Self.maxArtworkBytes
        )
        state.artworkTask = loader

        loader.start { [weak self, weak state, weak loader] output in
            let image = output.flatMap {
                BoundedImageDecoder.image(
                    from: $0.data,
                    maximumPixelCount: Self.maxArtworkPixelCount,
                    maximumDimension: Self.maxArtworkDimension
                )
            }

            DispatchQueue.main.async {
                guard let state,
                      let loader,
                      state.artworkGeneration == artworkGeneration,
                      state.artworkTask === loader else {
                    return
                }
                state.artworkTask = nil
                guard let self, let image else {
                    return
                }

                let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                state.nowPlayingInfo[MPMediaItemPropertyArtwork] = artwork
                if self.activeSession === state.session {
                    self.nowPlayingCenter.nowPlayingInfo = state.nowPlayingInfo
                }
            }
        }
    }
    
    func onPlaybackPlaying(session: GeckoSession) {
        // In-page resumes arrive here with no remote command involved.
        // If the session was released while backgrounded, this is the
        // first moment it is known to be needed again.
        activateAudioSessionForPlayback()
        revalidate()
        let identifier = ObjectIdentifier(session)
        let state = state(for: session)
        state.playbackState = .playing
        state.nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = 1.0
        playbackHistory.removeAll { $0 == identifier }
        playbackHistory.append(identifier)
        
        // The priority session is exempt - it is not a tab, so it can
        // never be the selected one and could otherwise never take the
        // controls while anything played on the phone. See
        // fix_carplay_media_priority.py.
        if session !== prioritySession,
           let selectedSession,
           selectedSession !== session,
           let selectedState = sessionStates[ObjectIdentifier(selectedSession)],
           selectedState.playbackState != .none {
            return
        }
        activate(session, state: state)
        notifyStateChanged(for: session)
    }
    
    func onPlaybackPaused(session: GeckoSession) {
        revalidate()
        let identifier = ObjectIdentifier(session)
        let state = state(for: session)
        state.playbackState = .paused
        state.nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = 0.0
        playbackHistory.removeAll { $0 == identifier }
        
        if activeSession === session {
            nowPlayingCenter.nowPlayingInfo = state.nowPlayingInfo
            apply(state.features)
            nowPlayingCenter.playbackState = .paused
        }
        notifyStateChanged(for: session)
        releaseAudioSessionIfIdleInBackground()
    }
    
    func onPlaybackNone(session: GeckoSession) {
        revalidate()
        let identifier = ObjectIdentifier(session)
        let state = state(for: session)
        state.playbackState = .none
        playbackHistory.removeAll { $0 == identifier }
        
        if activeSession === session {
            activateMostRecentPlayingSession()
        }
        notifyStateChanged(for: session)
        releaseAudioSessionIfIdleInBackground()
    }
    
    func select(session: GeckoSession) {
        revalidate()
        selectedSession = session
        postSelectedPlaybackStateIfChanged()
        guard let state = sessionStates[ObjectIdentifier(session)],
              state.playbackState != .none else {
            return
        }
        
        // Choosing a tab does not take the controls back from a
        // priority session that is playing - the car display would
        // otherwise lose them the moment the phone was touched, and it
        // has no other way to be controlled. See
        // fix_carplay_media_priority.py.
        if let prioritySession,
           prioritySession !== session,
           let priorityState = sessionStates[ObjectIdentifier(prioritySession)],
           priorityState.playbackState == .playing {
            return
        }
        
        activate(session, state: state)
    }
    
    func navigationStarted(in session: GeckoSession) {
        let identifier = ObjectIdentifier(session)
        guard selectedSession === session,
              let state = sessionStates[identifier] else {
            return
        }
        state.playbackState = .none
        state.positionState = nil
        playbackHistory.removeAll { $0 == identifier }
        
        if activeSession === session {
            activateMostRecentPlayingSession()
        }
        observer?.systemMediaSessionStateDidChange(self)
        postSelectedPlaybackStateIfChanged()
    }
    
    /// Pauses every session that reports itself playing, through the
    /// same GeckoView:MediaSession:Pause the lock screen's pause
    /// command takes.
    ///
    /// For AirPlay route loss: when the receiver goes away the phone's
    /// speaker would otherwise take over mid-sentence, and WebKit's
    /// OldDeviceUnavailable rule (MediaSessionManagerIOS) pauses
    /// instead. AVPlayers pause themselves in the host; this covers the
    /// Gecko-decoded media the host never sees.
    func pausePlayingSessions() {
        var paused = 0
        for state in sessionStates.values {
            guard let session = state.session,
                  state.playbackState == .playing else {
                continue
            }
            session.mediaSession.pause()
            paused += 1
        }
        logger(String(format: "mediaSession: pausePlayingSessions - paused %d of %d", paused, sessionStates.count))
    }
    
    func onPositionState(session: GeckoSession, state: MediaSessionPositionState) {
        let sessionState = self.state(for: session)
        sessionState.positionState = state
        sessionState.nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = state.duration
        sessionState.nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = state.position
        sessionState.nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = state.playbackRate
        
        if activeSession === session {
            nowPlayingCenter.nowPlayingInfo = sessionState.nowPlayingInfo
        }
        notifyStateChanged(for: session)
    }
    
    func onFeatures(session: GeckoSession, features: MediaSessionFeatures) {
        let state = state(for: session)
        state.features = features
        
        if activeSession === session {
            apply(features)
        }
        notifyStateChanged(for: session)
    }
    
    private func state(for session: GeckoSession) -> SessionState {
        let identifier = ObjectIdentifier(session)
        if let state = sessionStates[identifier] {
            return state
        }
        
        let state = SessionState(session: session)
        sessionStates[identifier] = state
        return state
    }
    
    private func notifyStateChanged(for session: GeckoSession) {
        guard selectedSession === session else {
            return
        }
        observer?.systemMediaSessionStateDidChange(self)
        postSelectedPlaybackStateIfChanged()
    }
    
    private func postSelectedPlaybackStateIfChanged() {
        let playbackState = selectedSnapshot?.playbackState
        guard playbackState != lastPostedSelectedPlaybackState else {
            return
        }
        lastPostedSelectedPlaybackState = playbackState
        NotificationCenter.default.post(name: Self.selectedPlaybackStateDidChange, object: self)
    }
    
    private func activate(_ session: GeckoSession, state: SessionState) {
        // Nothing to show means nothing worth showing. A restored tab
        // reports playback before any metadata arrives, and activating on
        // that put empty controls on the lock screen that never went
        // away - see fix_no_lockscreen_without_metadata.py.
        //
        // onMetadata activates instead once a title turns up, so a real
        // video is unaffected whichever order the two arrive in.
        let pendingTitle = (state.nowPlayingInfo[MPMediaItemPropertyTitle] as? String) ?? ""
        guard !pendingTitle.isEmpty else {
            logger("mediaSession: not activating - no metadata yet")
            return
        }
        
        activeSession = session
        nowPlayingCenter.nowPlayingInfo = state.nowPlayingInfo
        apply(state.features)
        // Report the state alongside the info - the info dict's
        // PlaybackRate alone does not tell iOS the app stopped.
        nowPlayingCenter.playbackState =
            state.playbackState == .playing ? .playing : .paused
        
        // See fix_log_media_session_activity.py. Every path that
        // populates now playing comes through here, so this is where a
        // handover becomes visible.
        let title = (state.nowPlayingInfo[MPMediaItemPropertyTitle] as? String) ?? "(untitled)"
        logger(String(format: "mediaSession: ACTIVATED %@ (%d in history, %d states)", title, playbackHistory.count, sessionStates.count))
    }
    
    /// Called when the app moves to the background. revalidate() runs
    /// on the way to the FOREGROUND (SceneDelegate.sceneDidBecomeActive),
    /// which left the entire backgrounded stretch - exactly when the
    /// lock screen is visible - reconciling nothing. See
    /// fix_release_audio_session_when_idle.py.
    ///
    /// The audio session is released whenever nothing is actually
    /// PLAYING - see fix_release_audio_session_with_only_paused_media.py.
    /// Only rendering audio justifies holding the session, and with
    /// the "audio" background mode an active session is what keeps the
    /// entire app running in the background. A paused session keeps
    /// its lock-screen card (deliberate, unchanged) but no longer
    /// keeps the audio session active with it; the now playing entry
    /// itself is cleared only when nothing has any playback at all
    /// (playing or paused).
    ///
    /// activeSession is cleared BEFORE apply(): apply() computes
    /// hasActivePlayback from it, and only a nil activeSession makes
    /// every command disable. It never removes handlers, so disabling
    /// is what actually retires the card.
    ///
    /// Deactivation is best-effort: if the engine still holds a live
    /// audio unit the call fails ("session is busy"), which is
    /// precisely the case where the session should stay active.
    func applicationDidEnterBackground() {
        revalidate()
        let anyPlaying = sessionStates.values.contains {
            $0.session != nil && $0.playbackState == .playing
        }
        guard !anyPlaying else {
            return
        }
        let anyPaused = sessionStates.values.contains {
            $0.session != nil && $0.playbackState == .paused
        }
        if !anyPaused {
            activeSession = nil
            nowPlayingCenter.nowPlayingInfo = nil
            nowPlayingCenter.playbackState = .stopped
            apply(MediaSessionFeatures())
        }
        // An AVPlayer on an AirPlay receiver is playing without any
        // Media Session state to say so - the states above are Gecko's
        // view, and the host's players report nothing here. Releasing
        // the session would end the playback on the TV. WebKit keeps
        // the session while any element is playing to a wireless
        // target (MediaSessionManagerIOS::sessionWillEndPlayback).
        guard !AVPlayerHost.shared.isAnyExternalPlaybackActive else {
            logger("mediaSession: backgrounded with an AVPlayer in external playback - audio session kept")
            return
        }
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: .notifyOthersOnDeactivation
        )
        logger(anyPaused
            ? "mediaSession: backgrounded with only paused media - audio session released, card kept"
            : "mediaSession: backgrounded with no playback - cleared")
    }

    /// Releases the shared audio session when the app is backgrounded
    /// and playback has just stopped. applicationDidEnterBackground
    /// only runs at the moment of the transition; media that stops
    /// WHILE the app is already backgrounded - a PiP window closed, a
    /// video that ends or pauses itself, a tab that dies - otherwise
    /// leaves the session active with no remaining hook to release it.
    /// With the "audio" background mode an active session keeps the
    /// whole app running, so this is the difference between suspending
    /// when media ends and running all day. See
    /// fix_release_audio_session_when_media_stops_in_background.py.
    ///
    /// Deactivation is best-effort, same as the backgrounding path: if
    /// an engine audio unit is still live the call fails, which is
    /// precisely the case where the session should stay active.
    private func releaseAudioSessionIfIdleInBackground() {
        guard UIApplication.shared.applicationState == .background else {
            return
        }
        let anyPlaying = sessionStates.values.contains {
            $0.session != nil && $0.playbackState == .playing
        }
        guard !anyPlaying else {
            return
        }
        // Same fence as applicationDidEnterBackground: a player on an
        // AirPlay receiver is not in these states.
        guard !AVPlayerHost.shared.isAnyExternalPlaybackActive else {
            logger("mediaSession: playback stopped while backgrounded but an AVPlayer is in external playback - audio session kept")
            return
        }
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: .notifyOthersOnDeactivation
        )
        logger("mediaSession: playback stopped while backgrounded - audio session released")
    }

    /// Drops sessions that died without reporting, and clears the now
    /// playing entry if the active one was among them. See
    /// fix_media_session_leak.py.
    ///
    /// onDeactivated handles an orderly close, but a session that is
    /// simply deallocated never calls it. activeSession is weak so it
    /// silently becomes nil, while its state stays marked .playing and
    /// nowPlayingInfo stays populated - describing something that no
    /// longer exists, with nothing left to notice.
    func revalidate() {
        let dead = sessionStates.filter { $0.value.session == nil }
        
        for (identifier, state) in dead {
            state.artworkTask?.cancel()
            sessionStates.removeValue(forKey: identifier)
            playbackHistory.removeAll { $0 == identifier }
        }
        
        // The active session going while now playing is still populated
        // is the case the user actually sees. Reactivating either
        // promotes whatever else was playing or clears the entry.
        if activeSession == nil, !(nowPlayingCenter.nowPlayingInfo?.isEmpty ?? true) {
            activateMostRecentPlayingSession()
        }
    }
    
    private func activateMostRecentPlayingSession() {
        // Logged on entry as well as at the ends, because a promotion is
        // the likeliest way a now playing entry outlives the tab that
        // created it. See fix_log_media_session_activity.py.
        logger(String(format: "mediaSession: looking for a session to promote (%d in history)", playbackHistory.count))
        
        while let identifier = playbackHistory.last {
            guard let state = sessionStates[identifier],
                  state.playbackState == .playing,
                  let session = state.session else {
                playbackHistory.removeLast()
                continue
            }
            
            activate(session, state: state)
            return
        }
        
        activeSession = nil
        nowPlayingCenter.nowPlayingInfo = nil
        apply(MediaSessionFeatures())
        nowPlayingCenter.playbackState = .stopped
        
        logger(String(format: "mediaSession: CLEARED - nothing left playing (%d states remain)", sessionStates.count))
    }
    
    private func apply(_ features: MediaSessionFeatures) {
        let hasActivePlayback = activeSession.flatMap { session in
            sessionStates[ObjectIdentifier(session)]?.playbackState
        }.map { $0 != .none } ?? false
        
        commandCenter.playCommand.isEnabled = hasActivePlayback || features.contains(.play)
        commandCenter.pauseCommand.isEnabled = hasActivePlayback || features.contains(.pause)
        commandCenter.stopCommand.isEnabled = features.contains(.stop)
        commandCenter.togglePlayPauseCommand.isEnabled = hasActivePlayback || features.contains(.play) || features.contains(.pause)
        commandCenter.nextTrackCommand.isEnabled = features.contains(.nextTrack)
        commandCenter.previousTrackCommand.isEnabled = features.contains(.prevTrack)
        commandCenter.skipForwardCommand.isEnabled = features.contains(.seekForward)
        commandCenter.skipBackwardCommand.isEnabled = features.contains(.seekBackward)
        commandCenter.seekForwardCommand.isEnabled = features.contains(.seekForward)
        commandCenter.seekBackwardCommand.isEnabled = features.contains(.seekBackward)
        commandCenter.changePlaybackPositionCommand.isEnabled = features.contains(.seekTo)
    }
    
    /// The app releases the shared audio session whenever nothing is
    /// PLAYING (applicationDidEnterBackground,
    /// releaseAudioSessionIfIdleInBackground) - but nothing app-side
    /// ever re-activated it, and the engine only activates on stream
    /// INIT, not on resuming a stream it already holds. So the
    /// lock-screen Play offered for a paused tab could restart
    /// playback into a deactivated session. Re-activation is cheap
    /// and idempotent when the session is already active; failure is
    /// left to iOS, the same best-effort stance the releases take.
    private func activateAudioSessionForPlayback() {
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    private func registerRemoteCommands() {
        var targets: [Any] = []
        targets.append(commandCenter.playCommand.addTarget { [weak self] _ in
            guard let session = self?.activeSession else { return .commandFailed }
            // Before the play reaches Gecko, so the session is live
            // before cubeb restarts the audio unit.
            self?.activateAudioSessionForPlayback()
            session.mediaSession.play()
            return .success
        })
        targets.append(commandCenter.pauseCommand.addTarget { [weak self] _ in
            guard let session = self?.activeSession else { return .commandFailed }
            session.mediaSession.pause()
            return .success
        })
        targets.append(commandCenter.stopCommand.addTarget { [weak self] _ in
            guard let session = self?.activeSession else { return .commandFailed }
            session.mediaSession.stop()
            return .success
        })
        targets.append(commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self,
                  let session = activeSession,
                  let state = sessionStates[ObjectIdentifier(session)] else {
                return .commandFailed
            }
            
            switch state.playbackState {
            case .playing:
                session.mediaSession.pause()
            case .paused:
                activateAudioSessionForPlayback()
                session.mediaSession.play()
            case .none:
                return .commandFailed
            }
            return .success
        })
        targets.append(commandCenter.nextTrackCommand.addTarget { [weak self] _ in
            guard let session = self?.activeSession else { return .commandFailed }
            session.mediaSession.nextTrack()
            return .success
        })
        targets.append(commandCenter.previousTrackCommand.addTarget { [weak self] _ in
            guard let session = self?.activeSession else { return .commandFailed }
            session.mediaSession.previousTrack()
            return .success
        })
        targets.append(commandCenter.skipForwardCommand.addTarget { [weak self] _ in
            guard let session = self?.activeSession else { return .commandFailed }
            session.mediaSession.seekForward()
            return .success
        })
        targets.append(commandCenter.skipBackwardCommand.addTarget { [weak self] _ in
            guard let session = self?.activeSession else { return .commandFailed }
            session.mediaSession.seekBackward()
            return .success
        })
        targets.append(commandCenter.seekForwardCommand.addTarget { [weak self] event in
            guard let seekEvent = event as? MPSeekCommandEvent else {
                return .commandFailed
            }
            guard seekEvent.type == .beginSeeking else {
                return .success
            }
            guard let session = self?.activeSession else { return .commandFailed }
            session.mediaSession.seekForward()
            return .success
        })
        targets.append(commandCenter.seekBackwardCommand.addTarget { [weak self] event in
            guard let seekEvent = event as? MPSeekCommandEvent else {
                return .commandFailed
            }
            guard seekEvent.type == .beginSeeking else {
                return .success
            }
            guard let session = self?.activeSession else { return .commandFailed }
            session.mediaSession.seekBackward()
            return .success
        })
        targets.append(commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let positionEvent = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            guard let session = self?.activeSession else { return .commandFailed }
            session.mediaSession.seekTo(time: positionEvent.positionTime)
            return .success
        })
        commandTargets = targets
    }
    
    private func unregisterRemoteCommands() {
        let commands: [MPRemoteCommand] = [
            commandCenter.playCommand,
            commandCenter.pauseCommand,
            commandCenter.stopCommand,
            commandCenter.togglePlayPauseCommand,
            commandCenter.nextTrackCommand,
            commandCenter.previousTrackCommand,
            commandCenter.skipForwardCommand,
            commandCenter.skipBackwardCommand,
            commandCenter.seekForwardCommand,
            commandCenter.seekBackwardCommand,
            commandCenter.changePlaybackPositionCommand,
        ]
        zip(commands, commandTargets).forEach { command, target in
            command.isEnabled = false
            command.removeTarget(target)
        }
        commandTargets.removeAll()
    }
}
