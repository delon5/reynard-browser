//
//  CarPlayScriptEditorViewController.swift
//  Reynard
//
//  Added by fix_carplay_scripts_ui.py.
//

import UIKit

/// Edits a single CarPlay script.
///
/// A pushed screen rather than an alert, because a UIAlertController
/// text field cannot hold multi-line JavaScript - no line breaks, no
/// scrolling, and a few visible characters at a time.
///
/// Writes straight to prefs on save, and the list re-reads in
/// viewWillAppear rather than using a delegate.
final class CarPlayScriptEditorViewController: UIViewController {
    private let existingIndex: Int?

    private let nameField = UITextField()
    private let enabledSwitch = UISwitch()
    private let bodyView = UITextView()

    init(existingIndex: Int?) {
        self.existingIndex = existingIndex
        super.init(nibName: nil, bundle: nil)
        title = existingIndex == nil
            ? NSLocalizedString("New Script", comment: "")
            : NSLocalizedString("Edit Script", comment: "")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        view.backgroundColor = .settingsBackground

        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .save,
            target: self,
            action: #selector(save)
        )

        nameField.placeholder = NSLocalizedString("Script name", comment: "")
        nameField.borderStyle = .roundedRect
        nameField.autocapitalizationType = .words
        nameField.translatesAutoresizingMaskIntoConstraints = false

        let enabledLabel = UILabel()
        enabledLabel.text = NSLocalizedString("Enabled", comment: "")
        enabledLabel.translatesAutoresizingMaskIntoConstraints = false
        enabledSwitch.translatesAutoresizingMaskIntoConstraints = false

        // Monospaced, and every autocorrection feature off - iOS would
        // otherwise capitalise keywords and replace quotes with smart
        // quotes, which silently breaks JavaScript.
        bodyView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        bodyView.autocapitalizationType = .none
        bodyView.autocorrectionType = .no
        bodyView.spellCheckingType = .no
        bodyView.smartQuotesType = .no
        bodyView.smartDashesType = .no
        bodyView.smartInsertDeleteType = .no
        bodyView.layer.cornerRadius = 8
        bodyView.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(nameField)
        view.addSubview(enabledLabel)
        view.addSubview(enabledSwitch)
        view.addSubview(bodyView)

        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            nameField.topAnchor.constraint(equalTo: guide.topAnchor, constant: 16),
            nameField.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 16),
            nameField.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -16),

            enabledLabel.topAnchor.constraint(equalTo: nameField.bottomAnchor, constant: 16),
            enabledLabel.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 16),
            enabledSwitch.centerYAnchor.constraint(equalTo: enabledLabel.centerYAnchor),
            enabledSwitch.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -16),

            bodyView.topAnchor.constraint(equalTo: enabledLabel.bottomAnchor, constant: 16),
            bodyView.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 16),
            bodyView.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -16),
            bodyView.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -16)
        ])

        if let existingIndex {
            let scripts = Prefs.ExperimentalSettings.carPlayScripts
            if scripts.indices.contains(existingIndex) {
                let script = scripts[existingIndex]
                nameField.text = script.name
                bodyView.text = script.body
                enabledSwitch.isOn = script.isEnabled
            }
        } else {
            enabledSwitch.isOn = true
        }
    }

    @objc private func save() {
        let name = (nameField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let body = bodyView.text ?? ""

        guard !name.isEmpty, !body.isEmpty else {
            navigationController?.popViewController(animated: true)
            return
        }

        var scripts = Prefs.ExperimentalSettings.carPlayScripts
        let script = CarPlayScript(name: name, body: body, isEnabled: enabledSwitch.isOn)

        if let existingIndex, scripts.indices.contains(existingIndex) {
            scripts[existingIndex] = script
        } else {
            scripts.append(script)
        }

        Prefs.ExperimentalSettings.carPlayScripts = scripts
        navigationController?.popViewController(animated: true)
    }
}
