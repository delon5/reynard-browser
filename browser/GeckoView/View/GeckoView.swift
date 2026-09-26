//
//  GeckoView.swift
//  Reynard
//
//  Created by Minh Ton on 1/2/26.
//

import UIKit

public class GeckoView: UIView {
    public weak var interactionDelegate: GeckoViewInteractionDelegate? {
        didSet {
            session?.window?.setInteractionDelegate(interactionDelegate)
        }
    }
    
    public var session: GeckoSession? {
        didSet {
            oldValue?.window?.setInteractionDelegate(nil)
            embedSessionView()
            session?.window?.setInteractionDelegate(interactionDelegate)
        }
    }
    
    public override init(frame: CGRect) {
        super.init(frame: frame)
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }
    
    deinit {
        session?.window?.setInteractionDelegate(nil)
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        session?.updateViewportWidth(bounds.width)
    }
    
    /// Embeds the engine view of a session that was assigned before it
    /// was opened. ADDED - see fix_embed_engine_view_after_open.py.
    ///
    /// `session`'s didSet is the only place the engine view is added,
    /// and it gives up ("session window is unavailable during
    /// assignment") when the session has no window yet. A slept tab
    /// selected by a tab close and a recovered on-screen tab are both
    /// bound in that state and opened a few milliseconds later, and
    /// nothing re-ran the embed: the page loaded and painted into a
    /// view that was in no hierarchy, and the tab stayed blank until a
    /// different session was shown. The re-bind that follows every such
    /// open lands here. A session that is still closed, already
    /// embedded, or held by another view is left alone.
    public func embedSessionViewIfNeeded() {
        guard let session,
              let window = session.window,
              let engineView = window.view(),
              engineView.superview == nil else {
            return
        }
        NSLog("GeckoView: embedding the session view after open")
        embedSessionView()
        window.setInteractionDelegate(interactionDelegate)
    }
    
    private func embedSessionView() {
        subviews.forEach { $0.removeFromSuperview() }
        
        guard let session else {
            return
        }
        
        guard let window = session.window else {
            NSLog("GeckoView: session window is unavailable during assignment")
            return
        }
        
        guard let engineView = window.view() else {
            NSLog("GeckoView: session window has no view!")
            return
        }
        
        if engineView.superview != nil {
            fatalError("attempt to assign GeckoSession to multiple GeckoView instances")
        }
        
        engineView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(engineView)
        
        NSLayoutConstraint.activate([
            engineView.topAnchor.constraint(equalTo: topAnchor),
            engineView.leadingAnchor.constraint(equalTo: leadingAnchor),
            engineView.bottomAnchor.constraint(equalTo: bottomAnchor),
            engineView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        
        setNeedsLayout()
        layoutIfNeeded()
        session.updateViewportWidth(bounds.width)
    }
}
