//
//  TranslationPreferencesViewController.swift
//  Reynard
//
//  The always/never translate lists, and the sites you have told the
//  browser never to offer on.
//
//  This screen exists because the translate bar's "..." menu is a
//  one-way door without it. Choosing "Never Translate Spanish" makes the
//  engine stop offering for Spanish, which means the bar stops
//  appearing, which means the menu that would undo it can never be
//  reached again. Same for a blacklisted site. Everything set from the
//  bar has to be clearable from somewhere that does not depend on the
//  bar being on screen.
//
//  Lives under Languages because that is already where "what language do
//  I want content in" is answered - the Website Language list above it
//  is the Accept-Language order.
//

import UIKit
import GeckoView

final class TranslationPreferencesViewController: SettingsTableViewController {
    private enum Section: Int, CaseIterable {
        case alwaysTranslate
        case neverTranslate
        case neverTranslateSites

        var text: SettingsSectionText {
            switch self {
            case .alwaysTranslate:
                return SettingsSectionText(
                    headerTitle: NSLocalizedString("Always Translate", comment: ""),
                    footerTitle: NSLocalizedString("Pages in these languages are translated without asking.", comment: "")
                )
            case .neverTranslate:
                return SettingsSectionText(
                    headerTitle: NSLocalizedString("Never Translate", comment: ""),
                    footerTitle: NSLocalizedString("Translation is never offered for pages in these languages.", comment: "")
                )
            case .neverTranslateSites:
                return SettingsSectionText(
                    headerTitle: NSLocalizedString("Never Translate These Sites", comment: ""),
                    footerTitle: NSLocalizedString("Translation is never offered on these sites, whatever language they are in.", comment: "")
                )
            }
        }

        var emptyText: String {
            switch self {
            case .alwaysTranslate:
                return NSLocalizedString("No languages", comment: "")
            case .neverTranslate:
                return NSLocalizedString("No languages", comment: "")
            case .neverTranslateSites:
                return NSLocalizedString("No sites", comment: "")
            }
        }
    }

    private var alwaysLanguages: [GeckoRuntime.TranslationLanguageEntry] = []
    private var neverLanguages: [GeckoRuntime.TranslationLanguageEntry] = []
    private var neverSites: [String] = []
    /// Until the first load lands every section is empty, which would
    /// otherwise render three "No languages" rows and look like an
    /// answer rather than a pending question.
    private var hasLoaded = false

    init() {
        super.init(style: .insetGrouped)
        title = NSLocalizedString("Translation", comment: "")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        reload()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // Re-read on every appearance: these are engine-owned and the
        // translate bar can change them while this screen is pushed.
        reload()
    }

    private func reload() {
        Task { @MainActor [weak self] in
            let languages = await GeckoRuntime.translationLanguageSettings()
            let sites = await GeckoRuntime.neverTranslateSites()
            guard let self else {
                return
            }
            self.alwaysLanguages = languages.filter { $0.setting == .always }
            self.neverLanguages = languages.filter { $0.setting == .never }
            self.neverSites = sites
            self.hasLoaded = true
            self.tableView.reloadData()
        }
    }

    // MARK: - Data

    /// The two language sections gain a trailing "Add Language" row.
    /// The sites section deliberately does not: a site is added by being
    /// on it and choosing "never translate this site" from the bar, so
    /// there is nothing sensible for a picker to list.
    private func hasAddRow(_ section: Section) -> Bool {
        switch section {
        case .alwaysTranslate, .neverTranslate: return true
        case .neverTranslateSites: return false
        }
    }

    private func isAddRow(_ indexPath: IndexPath) -> Bool {
        guard let section = Section(rawValue: indexPath.section), hasAddRow(section) else {
            return false
        }
        return indexPath.row == max(count(in: section), 1)
    }

    private func count(in section: Section) -> Int {
        switch section {
        case .alwaysTranslate: return alwaysLanguages.count
        case .neverTranslate: return neverLanguages.count
        case .neverTranslateSites: return neverSites.count
        }
    }

    private func title(for indexPath: IndexPath) -> String? {
        guard let section = Section(rawValue: indexPath.section) else {
            return nil
        }
        switch section {
        case .alwaysTranslate:
            return alwaysLanguages[safe: indexPath.row]?.displayName
        case .neverTranslate:
            return neverLanguages[safe: indexPath.row]?.displayName
        case .neverTranslateSites:
            return neverSites[safe: indexPath.row]
        }
    }

    // MARK: - Table

    override func numberOfSections(in tableView: UITableView) -> Int {
        return Section.allCases.count
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        guard let section = Section(rawValue: section) else {
            return 0
        }
        // One placeholder row when empty, so the section still explains
        // itself rather than collapsing to a bare header, plus the add
        // row where there is one.
        return max(count(in: section), 1) + (hasAddRow(section) ? 1 : 0)
    }

    override func sectionText(for section: Int) -> SettingsSectionText {
        guard let section = Section(rawValue: section) else {
            return SettingsSectionText()
        }
        return section.text
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.selectionStyle = .none

        guard let section = Section(rawValue: indexPath.section) else {
            return cell
        }

        if isAddRow(indexPath) {
            cell.textLabel?.text = NSLocalizedString("Add Language…", comment: "")
            cell.textLabel?.textColor = cell.tintColor
            cell.selectionStyle = .default
            return cell
        }

        if count(in: section) == 0 {
            cell.textLabel?.text = hasLoaded
                ? section.emptyText
                : NSLocalizedString("Loading…", comment: "")
            cell.textLabel?.textColor = .secondaryLabel
            return cell
        }

        cell.textLabel?.text = title(for: indexPath)
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard isAddRow(indexPath), let section = Section(rawValue: indexPath.section) else {
            return
        }
        let setting: TranslationLanguageSetting =
            section == .alwaysTranslate ? .always : .never
        let picker = TranslationLanguagePickerViewController(
            setting: setting,
            title: section.text.headerTitle ?? NSLocalizedString("Add Language", comment: "")
        ) { [weak self] in
            self?.reload()
        }
        navigationController?.pushViewController(picker, animated: true)
    }

    override func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        guard let section = Section(rawValue: indexPath.section), !isAddRow(indexPath) else {
            return false
        }
        return count(in: section) > 0
    }

    override func tableView(_ tableView: UITableView, editingStyleForRowAt indexPath: IndexPath) -> UITableViewCell.EditingStyle {
        return self.tableView(tableView, canEditRowAt: indexPath) ? .delete : .none
    }

    override func tableView(
        _ tableView: UITableView,
        titleForDeleteConfirmationButtonForRowAt indexPath: IndexPath
    ) -> String? {
        return NSLocalizedString("Remove", comment: "")
    }

    override func tableView(
        _ tableView: UITableView,
        commit editingStyle: UITableViewCell.EditingStyle,
        forRowAt indexPath: IndexPath
    ) {
        guard editingStyle == .delete,
              let section = Section(rawValue: indexPath.section) else {
            return
        }

        // Removing an override means returning to the default, which for
        // a language is "offer" rather than the opposite setting - the
        // engine models three states, not two.
        switch section {
        case .alwaysTranslate:
            guard let entry = alwaysLanguages[safe: indexPath.row] else { return }
            alwaysLanguages.remove(at: indexPath.row)
            clearLanguage(entry.langTag)
        case .neverTranslate:
            guard let entry = neverLanguages[safe: indexPath.row] else { return }
            neverLanguages.remove(at: indexPath.row)
            clearLanguage(entry.langTag)
        case .neverTranslateSites:
            guard let origin = neverSites[safe: indexPath.row] else { return }
            neverSites.remove(at: indexPath.row)
            clearSite(origin)
        }

        // Reload the section rather than deleting the row: when the last
        // entry goes the row is replaced by the placeholder, so the count
        // does not actually drop to zero.
        tableView.reloadSections(IndexSet(integer: indexPath.section), with: .automatic)
    }

    private func clearLanguage(_ langTag: String) {
        Task { @MainActor [weak self] in
            try? await GeckoRuntime.setTranslationLanguageSetting(.offer, for: langTag)
            self?.reload()
        }
    }

    private func clearSite(_ origin: String) {
        Task { @MainActor [weak self] in
            try? await GeckoRuntime.clearNeverTranslateSite(origin)
            self?.reload()
        }
    }
}
