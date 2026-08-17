//
//  ToolbarController.swift
//  Reynard
//
//  Created by Minh Ton on 4/8/26.
//

import UIKit
import GeckoView

final class ToolbarController {
    enum LockReason: Hashable {
        case actionBar
        case addressBarTransition
        case addressBarEditing
        case historyNavigation
        case homepageOverlay
        case searchOverlay
        case tabOverview
        case viewPresentation
    }
    
    private enum UX {
        static let toolbarScrollFactor: CGFloat = 0.5
        static let snapDelay: TimeInterval = 0.1
        static let snapDuration: TimeInterval = 0.15
    }
    
    private unowned let browserChrome: BrowserChrome
    private unowned let tabBar: TabBar
    private unowned let contentView: ContentView
    private unowned let rootView: UIView
    
    private var chromeMode: BrowserChromeMode = .phone
    private var toolbarOffset: CGFloat = 0
    private var maxToolbarOffset: CGFloat = 0
    private var maxTopToolbarOffset: CGFloat = 0
    private var snapOrigin: CGFloat = 0
    private var targetOffset: CGFloat = 0
    private var snapStartTime: CFTimeInterval = 0
    private var pendingSnap: DispatchWorkItem?
    private var snapDisplayLink: CADisplayLink?
    private var lockReasons = Set<LockReason>()
    
    /// The selected tab's bottom-reservation verdict, injected by
    /// BrowserViewController so this controller does not grow a
    /// TabManager dependency. nil (no provider, or no verdict yet)
    /// must be treated as "not an env-reader": the compositor
    /// margin needs no cooperation from the page, so it is the safe
    /// default; env with a wrong page does nothing at all.
    var bottomReservation: (() -> GeckoSession.BottomReservation?)?
    
    // MARK: - Lifecycle
    
    init(
        browserChrome: BrowserChrome,
        tabBar: TabBar,
        contentView: ContentView,
        rootView: UIView
    ) {
        self.browserChrome = browserChrome
        self.tabBar = tabBar
        self.contentView = contentView
        self.rootView = rootView
        
        let historySwipeHandler = contentView.onHistorySwipeBegan
        contentView.onHistorySwipeBegan = { [weak self] in
            self?.lock(for: .historyNavigation)
            historySwipeHandler?()
        }
        
        contentView.onHistorySwipeEnded = { [weak self] in
            self?.unlock(for: .historyNavigation)
        }
        
        browserChrome.onActionBarVisibilityChanged = { [weak self] visible in
            if visible {
                self?.lock(for: .actionBar)
            } else {
                self?.unlock(for: .actionBar)
            }
        }
        
        contentView.onVerticalScroll = { [weak self] scrollDelta in
            self?.handleScroll(delta: scrollDelta)
        }
    }
    
    deinit {
        cancelSnap()
    }
    
    // MARK: - Layout
    
    func updateLayout(chromeMode: BrowserChromeMode, isToolbarEnabled: Bool) {
        let offsetLimits = toolbarOffsetLimits(for: chromeMode)
        let maxToolbarOffset = isToolbarEnabled ? offsetLimits.total : 0
        let maxTopToolbarOffset = isToolbarEnabled ? offsetLimits.top : 0
        if self.chromeMode != chromeMode
            || abs(maxToolbarOffset - self.maxToolbarOffset) > 0.5
            || abs(maxTopToolbarOffset - self.maxTopToolbarOffset) > 0.5 {
            reset(animated: false)
            self.chromeMode = chromeMode
            self.maxToolbarOffset = maxToolbarOffset
            self.maxTopToolbarOffset = maxTopToolbarOffset
        }
        // Float mode sends exactly ONE engine lift per PAGE, chosen by
        // the detector's verdict:
        //
        //   needsViewportShrink - the layout viewport shrinks by the
        //     pill's clearance (setDynamicToolbarMaxHeight, the same
        //     trusted path the expanded toolbar uses at ~142pt). The
        //     ICB lift reaches EVERYTHING - the measured last resort
        //     for absolute app-shell sheets (m.twitch.tv resolved
        //     env = 60px on device and its sheet did not move) and
        //     full-viewport player overlays (tv.apple.com). The strip
        //     behind the pill composites the canvas background, dark
        //     on the sites in this class.
        //
        //   readsSafeAreaInset - env(safe-area-inset-bottom) carries
        //     the clearance; the page positions its own controls
        //     (YouTube) and its background bleeds behind the pill.
        //
        //   everything else - the compositor fixed-layer margin lifts
        //     root-document fixed/sticky bars with no page
        //     cooperation (Facebook). Requires the animation ids
        //     granted by patches/layout/painting/nsDisplayList.cpp.patch.
        //
        // Never more than one on one page: a bar that is fixed AND on
        // an env-reading page moves twice - the 188pt overshoot this
        // hit before. Stopping mode keeps its single mechanism (the
        // content view ends at the pill's top edge, engine told
        // nothing), and the expanded toolbar keeps the full-height
        // viewport reservation.
        let condensed = browserChrome.isScrollCondensed
        let floats = Prefs.AppearanceSettings.pillFloatsOverPage
        let maxHeight: CGFloat
        let env: CGFloat
        let margin: CGFloat
        if condensed && floats {
            switch bottomReservation?() {
            case .needsViewportShrink:
                maxHeight = Prefs.AppearanceSettings.pillSafeAreaInset
                env = 0
                margin = 0
            case .readsSafeAreaInset:
                maxHeight = 0
                env = Prefs.AppearanceSettings.pillSafeAreaInset
                margin = 0
            default:
                maxHeight = 0
                env = 0
                margin = Prefs.AppearanceSettings.pillSafeAreaInset
            }
        } else {
            maxHeight = condensed ? 0 : maxToolbarOffset
            env = 0
            margin = 0
        }

        // The pill's real top edge in window coordinates, next to what
        // the page is being told, so a capture shows the gap and its
        // cause on one line instead of needing another build to guess.
        let pillTop = browserChrome.condensedPillFrame(in: rootView).minY
        // contentBottom is the measurement that has never been taken.
        // Everything else here describes what we SEND; this is what the
        // layout actually produced. In stop mode it must equal pillTop -
        // if it equals viewH instead, the bottom anchor did not take and
        // the page is free to paint under the pill no matter what the
        // engine was told.
        let contentBottom = contentView.convert(contentView.bounds, to: rootView).maxY
        NSLog("dynToolbar: condensed=\(condensed) floats=\(floats) max=\(maxHeight) env=\(env) pillTop=\(pillTop) contentBottom=\(contentBottom) viewH=\(rootView.bounds.height)")
        // Every layout pass, not just the condense animation. This runs on
        // rotation and setScrollCondensed does not, and rotation is where
        // the black band was actually being entered - three captures read
        // as healthy because the only chromeState lines in them came from
        // condense transitions, which are fine. Deduplicated inside, so
        // this costs one line per genuine change.
        browserChrome.logChromeState("layout")
        // And the content layer, which chromeState does not cover.
        // historyTransitionOverlayView is explicitly black and sits above
        // the page during a history swipe; only resetHistoryNavigation()
        // clears it, so an interrupted swipe leaves black over the page
        // that no chrome log would mention.
        contentView.logContentState("layout")

        // Both together - see setCondensedChrome. Setting them in two
        // calls meant whichever ran first sent with the other's stale
        // value, which is how the pill's margin ended up on the
        // dynamic-toolbar path as offset=180.
        contentView.setCondensedChrome(condensed: condensed, pillMargin: margin)
        contentView.setSafeAreaInsetBottom(env)
        contentView.setToolbarLimits(
            maxHeight: maxHeight,
            topOffset: maxTopToolbarOffset
        )
    }
    
    private func toolbarOffsetLimits(
        for chromeMode: BrowserChromeMode
    ) -> (total: CGFloat, top: CGFloat) {
        let topToolbarHeight = browserChrome.topToolbarTransitionFrame(in: rootView).height
        let bottomToolbarHeight = browserChrome.bottomToolbarTransitionFrame(in: rootView).height
        switch chromeMode {
        case .phone:
            return (bottomToolbarHeight, 0)
        case .compact:
            let topContentHeight = max(0, topToolbarHeight - rootView.safeAreaInsets.top)
            return (topContentHeight + bottomToolbarHeight, topContentHeight)
        case .pad:
            let maxOffset = topToolbarHeight + (tabBar.visibility == .visible ? tabBar.bounds.height : 0)
            return (maxOffset, maxOffset)
        }
    }
    
    private func setToolbarOffset(_ requestedOffset: CGFloat, refresh: Bool = false) {
        let clampedToolbarOffset = min(max(0, requestedOffset), maxToolbarOffset)
        guard refresh || clampedToolbarOffset != toolbarOffset else {
            return
        }
        toolbarOffset = clampedToolbarOffset
        let topToolbarHeight = browserChrome.topToolbarTransitionFrame(in: rootView).height
        let bottomToolbarHeight = browserChrome.bottomToolbarTransitionFrame(in: rootView).height
        let topToolbarOffset: CGFloat
        let topContentOffset: CGFloat
        let topToolbarContentAlpha: CGFloat
        let bottomToolbarOffset: CGFloat
        let bottomToolbarContentAlpha: CGFloat
        let tabBarOffset: CGFloat
        switch chromeMode {
        case .phone:
            topToolbarOffset = 0
            topContentOffset = 0
            topToolbarContentAlpha = 1
            bottomToolbarOffset = toolbarOffset
            bottomToolbarContentAlpha = 1 - (bottomToolbarOffset / max(bottomToolbarHeight, 1))
            tabBarOffset = 0
        case .compact:
            let progress = toolbarOffset / max(maxToolbarOffset, 1)
            topToolbarOffset = min(topToolbarHeight * progress, maxTopToolbarOffset)
            topContentOffset = topToolbarOffset
            topToolbarContentAlpha = 1 - (topToolbarOffset / max(maxTopToolbarOffset, 1))
            bottomToolbarOffset = bottomToolbarHeight * progress
            bottomToolbarContentAlpha = 1 - (bottomToolbarOffset / max(bottomToolbarHeight, 1))
            tabBarOffset = 0
        case .pad:
            topToolbarOffset = toolbarOffset
            topContentOffset = toolbarOffset
            topToolbarContentAlpha = 1
            bottomToolbarOffset = 0
            bottomToolbarContentAlpha = 1
            tabBarOffset = toolbarOffset
        }
        browserChrome.setToolbarTransition(
            topOffset: -topToolbarOffset,
            bottomOffset: bottomToolbarOffset,
            topContentAlpha: topToolbarContentAlpha,
            bottomContentAlpha: bottomToolbarContentAlpha
        )
        tabBar.transform = CGAffineTransform(translationX: 0, y: -tabBarOffset)
        contentView.applyToolbarOffsets(
            top: topContentOffset,
            bottom: topToolbarOffset + bottomToolbarOffset
        )
    }
    
    // MARK: - Locking
    
    func lock(for reason: LockReason) {
        guard lockReasons.insert(reason).inserted else { return }
        reset()
    }
    
    func unlock(for reason: LockReason) {
        lockReasons.remove(reason)
    }
    
    // MARK: - Scroll Handling
    
    private func handleScroll(delta: CGFloat) {
        guard maxToolbarOffset > 0,
              lockReasons.isEmpty else {
            return
        }
        cancelSnap()
        setToolbarOffset(toolbarOffset + delta * UX.toolbarScrollFactor)
        scheduleSnap()
    }
    
    // MARK: - Snapping
    
    private func scheduleSnap() {
        let snap = DispatchWorkItem { [weak self] in
            self?.beginSnap()
        }
        pendingSnap = snap
        DispatchQueue.main.asyncAfter(deadline: .now() + UX.snapDelay, execute: snap)
    }
    
    private func beginSnap(to destination: CGFloat? = nil) {
        pendingSnap = nil
        snapOrigin = toolbarOffset
        targetOffset = destination ?? (snapOrigin < maxToolbarOffset / 2 ? 0 : maxToolbarOffset)
        guard snapOrigin != targetOffset else {
            setToolbarOffset(targetOffset, refresh: true)
            return
        }
        snapStartTime = CACurrentMediaTime()
        let snapDisplayLink = CADisplayLink(target: self, selector: #selector(updateSnap))
        snapDisplayLink.add(to: .main, forMode: .common)
        self.snapDisplayLink = snapDisplayLink
    }
    
    @objc private func updateSnap() {
        let elapsed = CACurrentMediaTime() - snapStartTime
        let progress = min(CGFloat(elapsed / UX.snapDuration), 1)
        let easedProgress = 1 - pow(1 - progress, 2)
        let requestedOffset = snapOrigin + (targetOffset - snapOrigin) * easedProgress
        setToolbarOffset(requestedOffset)
        if progress == 1 {
            snapDisplayLink?.invalidate()
            snapDisplayLink = nil
        }
    }
    
    private func cancelSnap() {
        pendingSnap?.cancel()
        pendingSnap = nil
        snapDisplayLink?.invalidate()
        snapDisplayLink = nil
    }
    
    // MARK: - Reset
    
    func reset(animated: Bool = true) {
        cancelSnap()
        guard animated else {
            setToolbarOffset(0, refresh: true)
            return
        }
        beginSnap(to: 0)
    }
}
