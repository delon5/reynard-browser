//
//  SelectionActionMenuHostView.swift
//  Reynard
//
//  Created by Minh Ton on 17/6/26.
//

import GeckoView
import UIKit

@MainActor
final class SelectionActionMenuHostView: UIView {
    private weak var session: GeckoSession?
    private var actionId: String?
    private var availableActions = Set<String>()
    /// The text the callout is showing for, kept so "Find" can seed the
    /// find bar with it.
    private var selectedText = ""
    /// Set by the presenter; routes "Find" up to the browser, which owns
    /// the find bar.
    var onFindSelection: ((String) -> Void)?
    private let onDismissed: (GeckoSession) -> Void
    
    override var canBecomeFirstResponder: Bool {
        true
    }
    
    override func target(forAction action: Selector, withSender sender: Any?) -> Any? {
        guard actionId != nil else {
            return nil
        }
        
        if action == #selector(copy(_:)) {
            return availableActions.contains(SelectionActionCommand.copy) ? self : nil
        }
        
        if action == #selector(selectAll(_:)) {
            return availableActions.contains(SelectionActionCommand.selectAll) ? self : nil
        }

        if action == #selector(findSelection(_:)) {
            return selectedText.isEmpty ? nil : self
        }

        return nil
    }
    
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        guard actionId != nil else {
            return false
        }
        
        if action == #selector(copy(_:)) {
            return availableActions.contains(SelectionActionCommand.copy)
        }
        
        if action == #selector(selectAll(_:)) {
            return availableActions.contains(SelectionActionCommand.selectAll)
        }

        if action == #selector(findSelection(_:)) {
            // Not gated on the engine's action list - this one is the
            // embedder's, and it only needs text to search for.
            return !selectedText.isEmpty
        }

        return false
    }

    @objc private func findSelection(_ sender: Any?) {
        let text = selectedText
        // Dismiss first: the find bar takes first responder, and
        // handing that over while the callout is still up drops the
        // keyboard.
        hideMenu()
        guard !text.isEmpty else {
            return
        }
        onFindSelection?(text)
    }
    
    override func copy(_ sender: Any?) {
        executeAction(SelectionActionCommand.copy)
    }
    
    override func selectAll(_ sender: Any?) {
        executeAction(SelectionActionCommand.selectAll)
    }
    
    // MARK: - Lifecycle
    
    init(onDismissed: @escaping (GeckoSession) -> Void) {
        self.onDismissed = onDismissed
        super.init(frame: .zero)
        configureAppearance()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    // MARK: - Setup
    
    private func configureAppearance() {
        backgroundColor = .clear
        isUserInteractionEnabled = false
    }
    
    // MARK: - Presentation
    
    func present(
        on view: UIView,
        session: GeckoSession,
        actionId: String,
        anchorRect: CGRect,
        actions: [String],
        selection: String
    ) {
        self.session = session
        self.actionId = actionId
        self.selectedText = selection
        availableActions = Set(actions)

        // "Find" is ours, not the engine's - Gecko's action list only
        // ever offers COPY and SELECT_ALL here. menuItems is global to
        // UIMenuController, so it is set on every present rather than
        // once: another responder may have replaced it in between.
        UIMenuController.shared.menuItems = [
            UIMenuItem(
                // "Find", matching what iOS itself puts in this callout.
                // It searches the highlighted text immediately; the page
                // menu's "Find in Page" is the type-your-own entry
                // point.
                title: NSLocalizedString("Find", comment: ""),
                action: #selector(findSelection(_:))
            )
        ]
        
        if superview !== view {
            removeFromSuperview()
            view.addSubview(self)
        }
        
        if frame != anchorRect {
            frame = anchorRect
        }
        
        if !isFirstResponder {
            becomeFirstResponder()
        }
        
        let menuController = UIMenuController.shared
        menuController.hideMenu(from: self)
        menuController.showMenu(from: self, rect: bounds)
    }
    
    func hideMenu() {
        let dismissedSession = actionId == nil ? nil : session
        if superview != nil {
            UIMenuController.shared.hideMenu(from: self)
        } else {
            UIMenuController.shared.hideMenu()
        }
        
        if isFirstResponder {
            resignFirstResponder()
        }
        
        actionId = nil
        selectedText = ""
        availableActions.removeAll()
        if let dismissedSession {
            onDismissed(dismissedSession)
        }
    }
    
    func dismissAndRemove() {
        hideMenu()
        removeFromSuperview()
        session = nil
    }
    
    // MARK: - Actions
    
    private func executeAction(_ commandId: String) {
        guard let session, let actionId else {
            return
        }
        
        session.executeSelectionAction(actionId: actionId, commandId: commandId)
        hideMenu()
    }
}
