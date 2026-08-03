//
//  SystemMediaSession.swift
//  Reynard
//
//  Created by Minh Ton on 9/4/26.
//

import Foundation
import GeckoView
import MediaPlayer

protocol SystemMediaSessionObserver: AnyObject {
    func systemMediaSessionStateDidChange(_ mediaSession: SystemMediaSession)
}

final class SystemMediaSession: MediaSessionDelegate {
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
    
    enum PlaybackState {
        case none
        case paused
        case playing
    }
    
    private final class SessionState {
        weak var session: GeckoSession?
        var nowPlayingInfo: [String: Any] = [:]
        var features: MediaSessionFeatures = [.seekForward, .seekBackward, .seekTo]
        var artworkTask: URLSessionDataTask?
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
        }
    }
    
    func onMetadata(session: GeckoSession, metadata: MediaSessionMetadata) {
        let state = state(for: session)
        state.nowPlayingInfo[MPMediaItemPropertyTitle] = metadata.title ?? ""
        state.nowPlayingInfo[MPMediaItemPropertyArtist] = metadata.artist ?? ""
        state.nowPlayingInfo[MPMediaItemPropertyAlbumTitle] = metadata.album ?? ""
        
        if activeSession === session {
            nowPlayingCenter.nowPlayingInfo = state.nowPlayingInfo
        }
        
        state.artworkTask?.cancel()
        state.artworkTask = nil
        
        if let artworkURLString = metadata.artworkUrl,
           let artworkURL = URL(string: artworkURLString) {
            let task = URLSession.shared.dataTask(with: artworkURL) { [weak self, weak state] data, _, _ in
                guard let data, let image = UIImage(data: data) else { return }
                let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                DispatchQueue.main.async {
                    guard let self, let state else { return }
                    state.artworkTask = nil
                    state.nowPlayingInfo[MPMediaItemPropertyArtwork] = artwork
                    if self.activeSession === state.session {
                        self.nowPlayingCenter.nowPlayingInfo = state.nowPlayingInfo
                    }
                }
            }
            task.resume()
            state.artworkTask = task
        }
    }
    
    func onPlaybackPlaying(session: GeckoSession) {
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
        }
        notifyStateChanged(for: session)
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
    }
    
    func select(session: GeckoSession) {
        revalidate()
        selectedSession = session
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
    }
    
    private func activate(_ session: GeckoSession, state: SessionState) {
        activeSession = session
        nowPlayingCenter.nowPlayingInfo = state.nowPlayingInfo
        apply(state.features)
        
        // See fix_log_media_session_activity.py. Every path that
        // populates now playing comes through here, so this is where a
        // handover becomes visible.
        let title = (state.nowPlayingInfo[MPMediaItemPropertyTitle] as? String) ?? "(untitled)"
        logger(String(format: "mediaSession: ACTIVATED %@ (%d in history, %d states)", title, playbackHistory.count, sessionStates.count))
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
    
    private func registerRemoteCommands() {
        var targets: [Any] = []
        targets.append(commandCenter.playCommand.addTarget { [weak self] _ in
            guard let session = self?.activeSession else { return .commandFailed }
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
