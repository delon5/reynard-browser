//
//  TranslationLanguagePickerViewController.swift
//  Reynard
//
//  Picks a language to add to the always- or never-translate list.
//
//  Without this the Translation screen was a dead end: it could only
//  remove entries, and the only thing that could create one was the
//  translate bar - which does not appear until a page in a foreign
//  language is loaded, and never appears again once "never translate"
//  is set. So the lists read "No languages" with no way to change that.
//

import UIKit
import GeckoView

final class TranslationLanguagePickerViewController: SettingsTableViewController {
    private let setting: TranslationLanguageSetting
    private let onPicked: () -> Void

    /// Everything the engine can translate from, minus anything already
    /// carrying a non-default setting - adding a language that is
    /// already on the other list would silently move it, which reads as
    /// the picker having done nothing.
    private var languages: [GeckoRuntime.TranslationLanguageEntry] = []
    private var hasLoaded = false

    init(
        setting: TranslationLanguageSetting,
        title: String,
        onPicked: @escaping () -> Void
    ) {
        self.setting = setting
        self.onPicked = onPicked
        super.init(style: .insetGrouped)
        self.title = title
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        reload()
    }

    private func reload() {
        Task { @MainActor [weak self] in
            let supported = await GeckoRuntime.supportedSourceLanguages()
            let alreadySet = await GeckoRuntime.translationLanguageSettings()
            guard let self else {
                return
            }
            let taken = Set(alreadySet.map { $0.langTag.lowercased() })
            self.languages = supported
                .filter { !taken.contains($0.langTag.lowercased()) }
                .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
            self.hasLoaded = true
            self.tableView.reloadData()
        }
    }

    override func numberOfSections(in tableView: UITableView) -> Int {
        return 1
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return max(languages.count, 1)
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        guard !languages.isEmpty else {
            cell.textLabel?.text = hasLoaded
                ? NSLocalizedString("No languages available", comment: "")
                : NSLocalizedString("Loading…", comment: "")
            cell.textLabel?.textColor = .secondaryLabel
            cell.selectionStyle = .none
            return cell
        }
        cell.textLabel?.text = languages[safe: indexPath.row]?.displayName
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let language = languages[safe: indexPath.row] else {
            return
        }
        Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            try? await GeckoRuntime.setTranslationLanguageSetting(
                self.setting, for: language.langTag
            )
            self.onPicked()
            self.navigationController?.popViewController(animated: true)
        }
    }
}
