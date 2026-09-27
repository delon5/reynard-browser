//
//  DDIManager.swift
//  Reynard
//
//  Created by Minh Ton on 23/3/26.
//

import CryptoKit
import Foundation

final class DDIManager: NSObject {
    enum DDIError: LocalizedError {
        case alreadyInProgress
        case cancelled
        case invalidRemoteURL
        case integrityCheckFailed(fileName: String)
        case sharedContainerUnavailable
        
        var errorDescription: String? {
            switch self {
            case .alreadyInProgress:
                return NSLocalizedString("A Developer Disk Image download is already in progress.", comment: "")
            case .cancelled:
                return NSLocalizedString("Developer Disk Image download was cancelled.", comment: "")
            case .invalidRemoteURL:
                return NSLocalizedString("Developer Disk Image source URL is invalid.", comment: "")
            case let .integrityCheckFailed(fileName):
                return String(
                    format: NSLocalizedString(
                        "Developer Disk Image integrity verification failed for %@.",
                        comment: ""
                    ),
                    fileName
                )
            case .sharedContainerUnavailable:
                return NSLocalizedString("The shared App Group container is unavailable.", comment: "")
            }
        }
    }
    
    static let shared = DDIManager()
    
    private struct DownloadItem {
        let remoteURL: URL
        let destinationURL: URL
        let expectedSHA256: String
    }

    private struct DDIValidationReceipt: Codable, Equatable {
        let sourceRevision: String
        let hashes: [String: String]
    }
    
    private struct DownloadPlan {
        let rootDirectoryURL: URL
        let receiptURL: URL
        let items: [DownloadItem]
    }
    
    private struct ActiveDownload {
        var plan: DownloadPlan
        var currentIndex: Int
        var currentTask: URLSessionDownloadTask?
        /// Whether the plan was built with includingCryptex, so the
        /// end-of-plan re-check below builds the same one.
        let includesCryptex: Bool
        let progressHandler: (Double) -> Void
        let completion: (Result<Void, Error>) -> Void
    }
    
    private let fileManager: FileManager
    private let stateQueue = DispatchQueue(label: "com.minh-ton.Reynard.DDIManager.Queue", qos: .userInitiated)
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()
    
    private var activeDownload: ActiveDownload?
    
    override init() {
        self.fileManager = .default
        super.init()
    }
    
    /// `includingCryptex` also requires the Cryptex set on a device the
    /// Personalized manifest lists - the Experimental screen asks before
    /// switching Always Use Cryptex DDI on.
    func hasRequiredDDIFiles(includingCryptex: Bool = false) -> Bool {
        guard let plan = try? makeDownloadPlan(includingCryptex: includingCryptex),
              plan.items.allSatisfy({
                  fileManager.fileExists(atPath: $0.destinationURL.path)
              }),
              let receiptData = try? Data(contentsOf: plan.receiptURL),
              let receipt = try? JSONDecoder().decode(
                  DDIValidationReceipt.self,
                  from: receiptData
              ) else {
            return false
        }

        // Covers the plan, rather than equals it: a receipt written while
        // Always Use Cryptex DDI was on also lists the Cryptex set, and
        // switching it off must not make the Personalized files that same
        // receipt validated read as missing - a launch that finds required
        // files missing turns JIT off.
        let expected = validationReceipt(for: plan)
        return receipt.sourceRevision == expected.sourceRevision &&
            expected.hashes.allSatisfy { receipt.hashes[$0.key] == $0.value }
    }
    
    // REMOVED checkDDIVersionStaleness() - see
    // fix_swift_deadcode_and_stale_comments.py. Exactly one occurrence
    // repo-wide, its own definition; its doc opened "TEMPORARY
    // DIAGNOSTIC" and closed "safe to leave in or remove freely". It
    // compared the downloaded BuildManifest's ProductBuildVersion
    // against a hardcoded "17E5179g" and returned a sentence nobody
    // ever read.
    
    func ensureRequiredDDIFiles(
        includingCryptex: Bool = false,
        progress: @escaping (Double) -> Void,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        if hasRequiredDDIFiles(includingCryptex: includingCryptex) {
            DispatchQueue.main.async {
                progress(1)
                completion(.success(()))
            }
            return
        }
        
        stateQueue.async {
            if self.activeDownload != nil {
                self.dispatchCompletion(.failure(DDIError.alreadyInProgress), completion)
                return
            }
            
            do {
                let plan = try self.makeDownloadPlan(includingCryptex: includingCryptex)
                try self.ensureDDIRootDirectoryExists(at: plan.rootDirectoryURL)
                
                self.activeDownload = ActiveDownload(
                    plan: plan,
                    currentIndex: 0,
                    currentTask: nil,
                    includesCryptex: includingCryptex,
                    progressHandler: progress,
                    completion: completion
                )
                
                self.dispatchProgress(0, handler: progress)
                self.startNextDownloadLocked()
            } catch {
                self.dispatchCompletion(.failure(error), completion)
            }
        }
    }
    
    func cancelActiveDownload() {
        stateQueue.async {
            // CHANGED - a cancel with no download in flight no longer
            // deletes DDI storage. See fix_ddi_cleanup_preserves_valid_image.py.
            guard self.activeDownload != nil else {
                return
            }
            
            // REMOVED an `active.currentTask?.cancel()` that stood here
            // - see fix_swift_deadcode_and_stale_comments.py.
            // finishActiveDownloadLocked below re-reads
            // self.activeDownload and cancels currentTask itself. Both
            // run on this same serial stateQueue with nothing between
            // them, so it was the same task cancelled twice. The guard
            // no longer binds `active` because nothing here used it.
            self.finishActiveDownloadLocked(result: .failure(DDIError.cancelled), shouldCleanup: true)
        }
    }
    
    /// Deletes DDI storage from both possible locations — the shared
    /// App Group container and the private-container fallback — rather
    /// than just whichever ddiRootDirectoryURL() currently resolves to.
    /// Exists specifically so files left over from before the group ID
    /// fix (or from a session where the shared container silently fell
    /// back) can be fully cleared, forcing a genuinely fresh
    /// download+mount rather than reusing something possibly stale or
    /// mismatched. Best-effort per location — a missing directory isn't
    /// an error — but a real removal failure is surfaced rather than
    /// swallowed, since this is a deliberate, user-initiated action
    /// rather than incidental internal cleanup.
    func resetAllDDIStorage(completion: @escaping (Result<Void, Error>) -> Void) {
        stateQueue.async {
            var firstError: Error?
            let candidates: [URL?] = [ReynardDirectories.shared.sharedDDI, ReynardDirectories.shared.ddi]
            for url in candidates.compactMap({ $0 }) {
                guard self.fileManager.fileExists(atPath: url.path) else {
                    continue
                }
                do {
                    try self.fileManager.removeItem(at: url)
                } catch {
                    if firstError == nil {
                        firstError = error
                    }
                }
            }
            
            self.dispatchCompletion(firstError.map { .failure($0) } ?? .success(()), completion)
        }
    }
    
    private func startNextDownloadLocked() {
        guard var active = activeDownload else {
            return
        }
        
        guard active.currentIndex < active.plan.items.count else {
            // The Personalized manifest has just landed on a device that
            // had none: if it does not list this device, the plan now also
            // wants the Cryptex set. Its first items are the ones already
            // fetched, in the same order, so carry on from here rather than
            // writing a receipt for half a plan.
            if let fullPlan = try? makeDownloadPlan(includingCryptex: active.includesCryptex),
               fullPlan.items.count > active.plan.items.count,
               zip(fullPlan.items, active.plan.items).allSatisfy({
                   $0.destinationURL == $1.destinationURL && $0.expectedSHA256 == $1.expectedSHA256
               }) {
                NSLog("[DDI] this device is not in the Personalized manifest - fetching the Cryptex variant too")
                active.plan = fullPlan
                activeDownload = active
                startNextDownloadLocked()
                return
            }
            do {
                let receipt = validationReceipt(for: active.plan)
                let receiptData = try JSONEncoder().encode(receipt)
                try receiptData.write(to: active.plan.receiptURL, options: .atomic)
                finishActiveDownloadLocked(result: .success(()), shouldCleanup: false)
            } catch {
                finishActiveDownloadLocked(result: .failure(error), shouldCleanup: true)
            }
            return
        }
        
        let item = active.plan.items[active.currentIndex]
        
        do {
            try fileManager.createDirectory(
                at: item.destinationURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

        } catch {
            finishActiveDownloadLocked(result: .failure(error), shouldCleanup: true)
            return
        }
        
        let task = session.downloadTask(with: item.remoteURL)
        active.currentTask = task
        activeDownload = active
        task.resume()
    }
    
    private func completeCurrentFileDownload(location: URL, taskIdentifier: Int) {
        guard var active = activeDownload,
              let task = active.currentTask,
              task.taskIdentifier == taskIdentifier else {
            return
        }
        
        let item = active.plan.items[active.currentIndex]
        
        do {
            try fileManager.createDirectory(
                at: item.destinationURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            
            guard try Self.sha256(at: location) == item.expectedSHA256 else {
                throw DDIError.integrityCheckFailed(
                    fileName: item.destinationURL.lastPathComponent
                )
            }

            if fileManager.fileExists(atPath: item.destinationURL.path) {
                _ = try fileManager.replaceItemAt(
                    item.destinationURL,
                    withItemAt: location
                )
            } else {
                try fileManager.moveItem(at: location, to: item.destinationURL)
            }
        } catch {
            finishActiveDownloadLocked(result: .failure(error), shouldCleanup: true)
            return
        }
        
        active.currentTask = nil
        active.currentIndex += 1
        activeDownload = active
        
        let completedRatio = Double(active.currentIndex) / Double(active.plan.items.count)
        dispatchProgress(completedRatio, handler: active.progressHandler)
        startNextDownloadLocked()
    }
    
    private func handleDownloadProgress(
        taskIdentifier: Int,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard let active = activeDownload,
              let task = active.currentTask,
              task.taskIdentifier == taskIdentifier else {
            return
        }
        
        let fileProgress: Double
        if totalBytesExpectedToWrite > 0 {
            fileProgress = min(max(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite), 0), 1)
        } else {
            fileProgress = 0
        }
        
        let overallProgress = (Double(active.currentIndex) + fileProgress) / Double(active.plan.items.count)
        dispatchProgress(min(max(overallProgress, 0), 0.999), handler: active.progressHandler)
    }
    
    private func handleTaskFailure(taskIdentifier: Int, error: Error) {
        guard let active = activeDownload,
              let task = active.currentTask,
              task.taskIdentifier == taskIdentifier else {
            return
        }
        
        if let urlError = error as? URLError, urlError.code == .cancelled {
            finishActiveDownloadLocked(result: .failure(DDIError.cancelled), shouldCleanup: true)
            return
        }
        
        finishActiveDownloadLocked(result: .failure(error), shouldCleanup: false)
    }
    
    private func finishActiveDownloadLocked(result: Result<Void, Error>, shouldCleanup: Bool) {
        guard let active = activeDownload else {
            return
        }
        
        active.currentTask?.cancel()
        activeDownload = nil
        
        // CHANGED - cleanup no longer removes an install the app still
        // reads as valid. See fix_ddi_cleanup_preserves_valid_image.py.
        if shouldCleanup, !hasRequiredDDIFiles() {
            _ = try? removeDDIRootDirectory()
        }
        
        if case .success = result {
            dispatchProgress(1, handler: active.progressHandler)
        }
        
        dispatchCompletion(result, active.completion)
    }
    
    private func dispatchProgress(_ value: Double, handler: @escaping (Double) -> Void) {
        let clamped = min(max(value, 0), 1)
        DispatchQueue.main.async {
            handler(clamped)
        }
    }
    
    private func dispatchCompletion(
        _ result: Result<Void, Error>,
        _ completion: @escaping (Result<Void, Error>) -> Void
    ) {
        DispatchQueue.main.async {
            completion(result)
        }
    }
    
    private func ensureDDIRootDirectoryExists(at rootDirectoryURL: URL) throws {
        guard !fileManager.fileExists(atPath: rootDirectoryURL.path) else {
            return
        }
        
        try fileManager.createDirectory(at: rootDirectoryURL, withIntermediateDirectories: true)
    }
    
    private func removeDDIRootDirectory() throws {
        let rootDirectoryURL = try ddiRootDirectoryURL()
        guard fileManager.fileExists(atPath: rootDirectoryURL.path) else {
            return
        }
        
        try fileManager.removeItem(at: rootDirectoryURL)
    }
    
    private static let ddiSourceRevision = "5423e4e955fbb3a9eef3e1212acfbfc6e7a26236"

    /// JITSupport.m's installCryptexDDI loads the Cryptex assets from this
    /// subdirectory of the DDI root; the two names must stay in step.
    private static let cryptexDirectoryName = "Cryptex"
    private static let cryptexBaseURLString = "https://raw.githubusercontent.com/delon5/DeveloperDiskImage/5423e4e955fbb3a9eef3e1212acfbfc6e7a26236/PersonalizedImages/Xcode_iOS_DDI_Cryptex"
    private static let cryptexArtifacts: [(fileName: String, sha256: String)] = [
        ("BuildManifest.plist", "27385d7582b03b36bb3104e22b520aee0c47d72fecb4e8ecfe12ef5d966c7012"),
        ("Image.dmg", "873097f695a8b9734e2abc54f795a8874d40ff6fd11208ecb01ef29534c7c176"),
        ("Image.dmg.trustcache", "f7f21986074eee03a215aca16ecfc78d6bf183600d8a0d2fb691f9896782e6f0"),
        ("Image.dmg.cryptex_info", "edf49aef55aacc063d4d7be05b713bb545ce2993b3f62bcc15eccd75e610ee6c"),
        ("Image.dmg.root_hash", "3543fad2805b88119695c417e12679380b3b5a2742994bbcc839c8e2de5d7302"),
    ]

    /// Whether the Personalized manifest has a build identity for this
    /// device's model. nil when it cannot tell - no manifest yet, or one it
    /// cannot read - and the caller then keeps the Personalized-only plan.
    /// JITSupport.m's personalizedManifestCoversThisDevice asks the same
    /// question at mount time; the two must agree.
    private static let coverageLock = NSLock()
    private static var coverageCache: (size: Int, modified: Date, covers: Bool?)?

    private static func personalizedManifestCoversThisDevice(at manifestURL: URL) -> Bool? {
        // hasRequiredDDIFiles rebuilds the plan on every call, and the
        // manifest is 800 KB: parse it once per version of the file.
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: manifestURL.path),
              let size = attributes[.size] as? Int,
              let modified = attributes[.modificationDate] as? Date else {
            return nil
        }
        coverageLock.lock()
        if let cached = coverageCache, cached.size == size, cached.modified == modified {
            coverageLock.unlock()
            return cached.covers
        }
        coverageLock.unlock()
        let covers = parsePersonalizedManifestCoverage(at: manifestURL)
        coverageLock.lock()
        coverageCache = (size, modified, covers)
        coverageLock.unlock()
        return covers
    }

    private static func parsePersonalizedManifestCoverage(at manifestURL: URL) -> Bool? {
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? PropertyListSerialization.propertyList(
                from: data,
                format: nil
              ) as? [String: Any],
              let identities = manifest["BuildIdentities"] as? [[String: Any]] else {
            return nil
        }
        let model = deviceProductType()
        guard !model.isEmpty else {
            return nil
        }
        return identities.contains { ($0["Ap,ProductType"] as? String) == model }
    }

    private static func deviceProductType() -> String {
        var size = 0
        guard sysctlbyname("hw.machine", nil, &size, nil, 0) == 0, size > 0 else {
            return ""
        }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.machine", &buffer, &size, nil, 0) == 0 else {
            return ""
        }
        return String(cString: buffer)
    }

    private func makeDownloadPlan(includingCryptex: Bool = false) throws -> DownloadPlan {
        let rootDirectoryURL = try ddiRootDirectoryURL()
        let baseURLString = "https://raw.githubusercontent.com/delon5/DeveloperDiskImage/5423e4e955fbb3a9eef3e1212acfbfc6e7a26236/PersonalizedImages/Xcode_iOS_DDI_Personalized"
        guard let baseURL = URL(string: baseURLString) else {
            throw DDIError.invalidRemoteURL
        }

        let artifacts: [(fileName: String, sha256: String)] = [
            ("BuildManifest.plist", "8edd4a2f4f4ef1fbd7bfe49785d8badc673d1395d1d94d85b132ca8ab5ecaf54"),
            ("Image.dmg", "05fd807da5e19f030fa4941f24800c965c6c77982ab572dd5d1ef778fb69f9ca"),
            ("Image.dmg.trustcache", "36af60889ff5a737874a26daeb8e1a0139ebfebec6ec2e4d8f6a3c1bf1dce35c"),
        ]
        var items = artifacts.map { artifact in
            DownloadItem(
                remoteURL: baseURL.appendingPathComponent(artifact.fileName),
                destinationURL: rootDirectoryURL.appendingPathComponent(
                    artifact.fileName,
                    isDirectory: false
                ),
                expectedSHA256: artifact.sha256
            )
        }

        // The Cryptex variant, for a device the Personalized manifest does
        // not list (the iPhone 18 series and later): its build identity
        // names no device, so Apple can sign it for any model. Decided from
        // the Personalized manifest once it is on disk, so a covered
        // device's plan - and its receipt - is exactly what it was, unless
        // Always Use Cryptex DDI asks for the set, or the Experimental
        // screen is fetching it before switching that on.
        if includingCryptex ||
            Prefs.ExperimentalSettings.alwaysUsesCryptexDDI ||
            Self.personalizedManifestCoversThisDevice(
                at: rootDirectoryURL.appendingPathComponent("BuildManifest.plist", isDirectory: false)
            ) == false {
            guard let cryptexBaseURL = URL(string: Self.cryptexBaseURLString) else {
                throw DDIError.invalidRemoteURL
            }
            let cryptexDirectoryURL = rootDirectoryURL.appendingPathComponent(
                Self.cryptexDirectoryName,
                isDirectory: true
            )
            items += Self.cryptexArtifacts.map { artifact in
                DownloadItem(
                    remoteURL: cryptexBaseURL.appendingPathComponent(artifact.fileName),
                    destinationURL: cryptexDirectoryURL.appendingPathComponent(
                        artifact.fileName,
                        isDirectory: false
                    ),
                    expectedSHA256: artifact.sha256
                )
            }
        }

        return DownloadPlan(
            rootDirectoryURL: rootDirectoryURL,
            receiptURL: rootDirectoryURL.appendingPathComponent(
                ".reynard-ddi-validation.json",
                isDirectory: false
            ),
            items: items
        )
    }

    private func validationReceipt(for plan: DownloadPlan) -> DDIValidationReceipt {
        DDIValidationReceipt(
            sourceRevision: Self.ddiSourceRevision,
            // Keyed by the path under the DDI root: a Personalized file's
            // key is its bare name, exactly as before, and a Cryptex file's
            // is "Cryptex/<name>" - the two sets share three file names,
            // and uniqueKeysWithValues traps on a duplicate.
            hashes: Dictionary(
                uniqueKeysWithValues: plan.items.map {
                    (Self.receiptKey(for: $0.destinationURL, under: plan.rootDirectoryURL), $0.expectedSHA256)
                }
            )
        )
    }

    private static func receiptKey(for fileURL: URL, under rootDirectoryURL: URL) -> String {
        let root = rootDirectoryURL.standardizedFileURL.path
        let path = fileURL.standardizedFileURL.path
        guard path.hasPrefix(root + "/") else {
            return fileURL.lastPathComponent
        }
        return String(path.dropFirst(root.count + 1))
    }

    private static func sha256(at fileURL: URL) throws -> String {
        let fileHandle = try FileHandle(forReadingFrom: fileURL)
        defer {
            fileHandle.closeFile()
        }

        var hasher = SHA256()
        while true {
            let data = fileHandle.readData(ofLength: 1024 * 1024)
            guard !data.isEmpty else {
                break
            }
            hasher.update(data: data)
        }

        return hasher.finalize()
            .map { String(format: "%02x", $0) }
            .joined()
    }
    
    private func ddiRootDirectoryURL() throws -> URL {
        // Points at the shared App Group container so the Helper's own
        // RPPairing JIT self-enablement (see JITSupport.m's
        // ddiDirectoryURL, which now uses the same resolver) can reach
        // the same, real DDI files. Falls back to this app's own
        // private container if the shared one is genuinely unavailable
        // — matches ddiDirectoryURL()'s equivalent fallback on the
        // ObjC side, keeping the main app's own JIT working in that
        // degraded case rather than failing outright (the Helper would
        // still not be able to reach a DDI downloaded to the private
        // fallback location, since it's a separate sandbox).
        if let sharedDDI = ReynardDirectories.shared.sharedDDI {
            return sharedDDI
        }
        // Logged loudly rather than silently falling through — this
        // succeeding for the main app's own downloads/reads can
        // otherwise mask the Helper's own DDI access being broken,
        // since the main app's JIT would keep working normally while
        // the Helper silently never sees a usable DDI.
        NSLog("[AppGroup] WARNING: shared DDI container unavailable — ddiRootDirectoryURL() falling back to private Application Support directory. The Helper extension will NOT be able to read DDI files from this location.")
        return ReynardDirectories.shared.ddi
    }
}

extension DDIManager: URLSessionDownloadDelegate {
    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        stateQueue.async {
            self.handleDownloadProgress(
                taskIdentifier: downloadTask.taskIdentifier,
                totalBytesWritten: totalBytesWritten,
                totalBytesExpectedToWrite: totalBytesExpectedToWrite
            )
        }
    }
    
    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        stateQueue.sync {
            self.completeCurrentFileDownload(location: location, taskIdentifier: downloadTask.taskIdentifier)
        }
    }
    
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else {
            return
        }
        
        stateQueue.async {
            self.handleTaskFailure(taskIdentifier: task.taskIdentifier, error: error)
        }
    }
}
