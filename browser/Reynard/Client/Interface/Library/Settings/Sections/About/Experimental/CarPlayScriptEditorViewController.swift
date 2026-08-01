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

        // Done rather than Save - the script is committed in
        // viewWillDisappear, so this just pops. See
        // fix_carplay_script_editor_save.py.
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .done,
            target: self,
            action: #selector(done)
        )

        // A UITextView has no return-key dismissal - Return inserts a
        // newline - and this one fills the screen to the bottom, so
        // without this the keyboard cannot be put away.
        let keyboardToolbar = UIToolbar()
        keyboardToolbar.sizeToFit()
        keyboardToolbar.items = [
            UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil),
            UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(dismissKeyboard))
        ]
        bodyView.inputAccessoryView = keyboardToolbar

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

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)

        // Saving on the way back rather than behind a button, so there
        // is no save action to miss. See
        // fix_carplay_script_editor_save.py.
        save()
    }

    @objc private func done() {
        navigationController?.popViewController(animated: true)
    }

    @objc private func dismissKeyboard() {
        view.endEditing(true)
    }

    private func save() {
        let name = (nameField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let body = bodyView.text ?? ""

        // Only BOTH empty is an abandoned new script. An existing one
        // with its body cleared is saved as cleared, which is what the
        // action implies - discarding silently would keep the old text
        // and look like the edit was ignored.
        guard !name.isEmpty || !body.isEmpty else {
            return
        }

        let resolvedName = name.isEmpty
            ? NSLocalizedString("Untitled Script", comment: "")
            : name

        var scripts = Prefs.ExperimentalSettings.carPlayScripts
        let script = CarPlayScript(name: resolvedName, body: body, isEnabled: enabledSwitch.isOn)

        if let existingIndex, scripts.indices.contains(existingIndex) {
            scripts[existingIndex] = script
        } else {
            scripts.append(script)
        }

        Prefs.ExperimentalSettings.carPlayScripts = scripts
    }
}
