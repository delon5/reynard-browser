//
//  ToolbarController.swift
//  Reynard
//
//  Created by Minh Ton on 4/8/26.
//

import UIKit

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
        // The condensed pill floats OVER the page rather than reserving
        // layout space, so it is not a toolbar-limits question at all -
        // the limits describe the real toolbar, unchanged from upstream.
        let condensed = browserChrome.isScrollCondensed
        // The 20pt margin inside condensedPillOccupiedHeight is measured
        // from the SAFE AREA GUIDE, so the pill also occupies the home
        // indicator band beneath it - about 94pt here, not 60.
        let pill = BrowserChrome.condensedPillOccupiedHeight + rootView.safeAreaInsets.bottom

        // FLOATING PILL. The two mechanisms split by state so they can
        // never both charge for the same chrome - that double count is
        // what "RECEIVED offset=180 max=426 height=606" was, 202pt of
        // clearance and a black bar.
        //
        // Condensed: reserve NOTHING in the viewport, so the page keeps
        // the full window and a scrolling feed passes under the pill,
        // which is the floating look. The pill's clearance is a
        // compositor fixed-layer margin instead, and that lifts exactly
        // what should be lifted - position:fixed and sticky-bottom bars,
        // the site's own navigation - without relaying the document out.
        //
        // Expanded: the toolbar is opaque and occupies real space, so it
        // is a viewport reservation and the margin is nothing.
        let maxHeight = condensed ? 0 : maxToolbarOffset

        // Both knobs on one line, because they only mean anything
        // together: maxHeight shortens the LAYOUT VIEWPORT, so it moves
        // ordinary document flow, while the inset is a compositor
        // fixed-layer margin that moves only position:fixed and
        // sticky-bottom layers. A bottom bar that is neither will not
        // move for either of them, which is the case this log is here to
        // tell apart.
        NSLog("dynToolbar: condensed=\(condensed) max=\(maxHeight) pill=\(pill) toolbar=\(maxToolbarOffset) top=\(maxTopToolbarOffset)")

        // Both, and they do different jobs. The margin lifts fixed and
        // sticky layers at composite time - immediate, no relayout, but
        // it only reaches layers. env(safe-area-inset-bottom) asks the
        // PAGE to lay itself out around the pill, which is what moved
        // YouTube's controls before the merge and is the only thing that
        // reaches a bottom bar that is neither fixed nor sticky.
        //
        // Neither reserves layout viewport, so the page still runs full
        // height and paints behind the pill - the element below it, the
        // controls above it.
        // ONE of them, not both. A bar that is position:fixed AND on a
        // page that reads env gets moved twice - Facebook is both, and
        // its "Open app" banner ended up 188pt off the bottom against a
        // pill top at 94, which is the black gap between the two.
        //
        // env wins because it reaches the larger set: any page that
        // reads the variable, whether or not its bar is a fixed layer.
        // The compositor margin only ever moved fixed and sticky ones.
        contentView.setFloatingChromeInset(0)
        contentView.setSafeAreaInsetBottom(condensed ? pill : 0)
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
