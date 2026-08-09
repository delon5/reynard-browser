//
//  BrowserViewController+FindInPage.swift
//  Reynard
//
//  Self-contained find-in-page UI over GeckoSessionFinder. The bar is
//  created on demand, floats under the top safe area, and drives the
//  selected tab's session. Entry points: presentFindInPage() (public,
//  callable from any future menu/toolbar item) and Cmd+F, installed
//  once from applyGeckoPreferences().
//

import UIKit
import GeckoView

final class FindInPageBar: UIView, UITextFieldDelegate {
    let textField = UITextField()
    private let countLabel = UILabel()
    private let previousButton = UIButton(type: .system)
    private let nextButton = UIButton(type: .system)
    private let doneButton = UIButton(type: .system)

    var onSearch: ((String, _ backwards: Bool) -> Void)?
    var onClose: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)

        backgroundColor = .systemBackground
        layer.cornerRadius = 12
        layer.borderWidth = 1 / UIScreen.main.scale
        layer.borderColor = UIColor.separator.cgColor
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.15
        layer.shadowRadius = 8
        layer.shadowOffset = CGSize(width: 0, height: 2)

        textField.placeholder = "Find in page"
        textField.returnKeyType = .search
        textField.autocorrectionType = .no
        textField.autocapitalizationType = .none
        textField.clearButtonMode = .whileEditing
        textField.delegate = self
        textField.addTarget(self, action: #selector(textChanged), for: .editingChanged)

        countLabel.font = .preferredFont(forTextStyle: .footnote)
        countLabel.textColor = .secondaryLabel
        countLabel.setContentHuggingPriority(.required, for: .horizontal)
        countLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        previousButton.setImage(UIImage(systemName: "chevron.up"), for: .normal)
        previousButton.addTarget(self, action: #selector(findPrevious), for: .touchUpInside)
        nextButton.setImage(UIImage(systemName: "chevron.down"), for: .normal)
        nextButton.addTarget(self, action: #selector(findNext), for: .touchUpInside)
        doneButton.setImage(UIImage(systemName: "xmark"), for: .normal)
        doneButton.addTarget(self, action: #selector(close), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [
            textField, countLabel, previousButton, nextButton, doneButton,
        ])
        stack.axis = .horizontal
        stack.spacing = 12
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
        updateCount(current: 0, total: -1)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func updateCount(current: Int, total: Int) {
        // total is -1 until the engine has counted; show nothing rather
        // than a misleading 0/0 while the count is still pending.
        countLabel.text = total >= 0 ? "\(current)/\(total)" : ""
        let hasMatches = total > 0
        previousButton.isEnabled = hasMatches
        nextButton.isEnabled = hasMatches
    }

    @objc private func textChanged() {
        onSearch?(textField.text ?? "", false)
    }

    @objc private func findNext() {
        onSearch?(textField.text ?? "", false)
    }

    @objc private func findPrevious() {
        onSearch?(textField.text ?? "", true)
    }

    @objc private func close() {
        onClose?()
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        onSearch?(textField.text ?? "", false)
        return true
    }
}

extension BrowserViewController {
    private enum FindInPageAssociation {
        static var barKey: UInt8 = 0
    }

    private var findInPageBar: FindInPageBar? {
        get { objc_getAssociatedObject(self, &FindInPageAssociation.barKey) as? FindInPageBar }
        set {
            objc_setAssociatedObject(
                self, &FindInPageAssociation.barKey, newValue,
                .OBJC_ASSOCIATION_RETAIN_NONATOMIC
            )
        }
    }

    /// Installed once at startup. Guarded by input rather than a stored
    /// flag so re-running the bootstrap can never stack duplicates.
    func setUpFindInPageKeyCommand() {
        let alreadyInstalled = (keyCommands ?? []).contains {
            $0.input == "f" && $0.modifierFlags == .command
        }
        guard !alreadyInstalled else {
            return
        }
        let command = UIKeyCommand(
            title: "Find in Page",
            action: #selector(handleFindInPageKeyCommand),
            input: "f",
            modifierFlags: .command
        )
        // Let the command fire even while web content has first-responder
        // status inside the same responder chain.
        command.wantsPriorityOverSystemBehavior = true
        addKeyCommand(command)
    }

    @objc private func handleFindInPageKeyCommand() {
        presentFindInPage()
    }

    public func presentFindInPage() {
        if let bar = findInPageBar {
            bar.textField.becomeFirstResponder()
            return
        }

        let bar = FindInPageBar()
        bar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(bar)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            bar.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            bar.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
        ])

        bar.onSearch = { [weak self] query, backwards in
            self?.performFindInPage(query, backwards: backwards)
        }
        bar.onClose = { [weak self] in
            self?.dismissFindInPage()
        }

        findInPageBar = bar
        bar.textField.becomeFirstResponder()
    }

    public func dismissFindInPage() {
        guard let bar = findInPageBar else {
            return
        }
        tabManager.selectedTab?.session.clearMatches()
        bar.textField.resignFirstResponder()
        bar.removeFromSuperview()
        findInPageBar = nil
    }

    private func performFindInPage(_ query: String, backwards: Bool) {
        guard let session = tabManager.selectedTab?.session else {
            return
        }
        guard !query.isEmpty else {
            session.clearMatches()
            findInPageBar?.updateCount(current: 0, total: -1)
            return
        }
        Task { @MainActor [weak self] in
            guard let result = try? await session.findInPage(query, backwards: backwards) else {
                return
            }
            // The engine answers per-search; a stale response for text
            // the user already replaced is dropped by comparing against
            // the field's current contents.
            guard self?.findInPageBar?.textField.text == query else {
                return
            }
            self?.findInPageBar?.updateCount(current: result.current, total: result.total)
        }
    }
}
