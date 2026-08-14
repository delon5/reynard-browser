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
    
    func hasRequiredDDIFiles() -> Bool {
        guard let plan = try? makeDownloadPlan(),
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

        return receipt == validationReceipt(for: plan)
    }
    
    /// TEMPORARY DIAGNOSTIC — checks the downloaded manifest's own
    /// ProductBuildVersion against the version this same, hosted DDI
    /// source was confirmed to be at when last independently verified
    /// (June 2026, via pymobiledevice3's own LATEST_DDI_BUILD_ID
    /// constant: "17E5179g"). A real, separate log from a genuinely
    /// successful mount showed a different, older version
    /// ("16E5121h") — direct, concrete confirmation that DDI build
    /// versions do change over time, and a stale/mismatched version is
    /// a real, plausible explanation for "Error -28: BadBuildManifest"
    /// specifically failing during the live TSS negotiation step
    /// (see JITSupport.m's ensureDDIMounted and the investigation notes
    /// from this session for the full reasoning). This only reports
    /// what it finds — doesn't change any actual JIT behavior, and is
    /// safe to leave in or remove freely.
    func checkDDIVersionStaleness() -> String {
        guard let plan = try? makeDownloadPlan(),
              let manifestItem = plan.items.first(where: { $0.destinationURL.lastPathComponent == "BuildManifest.plist" }),
              fileManager.fileExists(atPath: manifestItem.destinationURL.path),
              let data = try? Data(contentsOf: manifestItem.destinationURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return "Could not read/parse the downloaded manifest to check its version."
        }
        
        let knownGoodVersion = "17E5179g"
        let actualVersion = plist["ProductBuildVersion"] as? String ?? "(missing)"
        
        if actualVersion == knownGoodVersion {
            return "DDI ProductBuildVersion: \(actualVersion) — matches the known-current version. Staleness is NOT the cause."
        } else {
            return "DDI ProductBuildVersion: \(actualVersion) — does NOT match the known-current version (\(knownGoodVersion)). This IS a plausible, genuine cause of the mount failure."
        }
    }
    
    func ensureRequiredDDIFiles(
        progress: @escaping (Double) -> Void,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        if hasRequiredDDIFiles() {
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
                let plan = try self.makeDownloadPlan()
                try self.ensureDDIRootDirectoryExists(at: plan.rootDirectoryURL)
                
                self.activeDownload = ActiveDownload(
                    plan: plan,
                    currentIndex: 0,
                    currentTask: nil,
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
            guard let active = self.activeDownload else {
                _ = try? self.removeDDIRootDirectory()
                return
            }
            
            active.currentTask?.cancel()
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
        
        if shouldCleanup {
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

    private func makeDownloadPlan() throws -> DownloadPlan {
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
        let items = artifacts.map { artifact in
            DownloadItem(
                remoteURL: baseURL.appendingPathComponent(artifact.fileName),
                destinationURL: rootDirectoryURL.appendingPathComponent(
                    artifact.fileName,
                    isDirectory: false
                ),
                expectedSHA256: artifact.sha256
            )
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
            hashes: Dictionary(
                uniqueKeysWithValues: plan.items.map {
                    ($0.destinationURL.lastPathComponent, $0.expectedSHA256)
                }
            )
        )
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
