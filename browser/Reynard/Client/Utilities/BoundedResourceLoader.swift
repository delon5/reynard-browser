//
//  BoundedResourceLoader.swift
//  Reynard
//

import Foundation
import ImageIO
import UIKit

final class BoundedURLDataLoader: NSObject, URLSessionDataDelegate {
    struct Output {
        let data: Data
        let response: URLResponse
    }

    private let request: URLRequest
    private let configuration: URLSessionConfiguration
    private let maximumBytes: Int
    private let lock = NSLock()

    private var completion: ((Output?) -> Void)?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var receivedData = Data()
    private var receivedResponse: URLResponse?
    private var started = false
    private var cancelled = false
    private var finished = false

    init(
        request: URLRequest,
        configuration: URLSessionConfiguration,
        maximumBytes: Int
    ) {
        self.request = request
        self.configuration = configuration
        self.maximumBytes = max(1, maximumBytes)
        super.init()
    }

    func start(completion: @escaping (Output?) -> Void) {
        lock.lock()
        guard !started else {
            lock.unlock()
            completion(nil)
            return
        }
        started = true

        guard !cancelled else {
            finished = true
            lock.unlock()
            completion(nil)
            return
        }

        self.completion = completion
        let session = URLSession(
            configuration: configuration,
            delegate: self,
            delegateQueue: nil
        )
        let task = session.dataTask(with: request)
        self.session = session
        self.task = task
        lock.unlock()

        task.resume()
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let task = self.task
        let shouldFinish = started && !finished
        lock.unlock()

        task?.cancel()
        if shouldFinish {
            finish(with: nil)
        }
    }

    static func data(
        for request: URLRequest,
        configuration: URLSessionConfiguration,
        maximumBytes: Int
    ) async -> Output? {
        let loader = BoundedURLDataLoader(
            request: request,
            configuration: configuration,
            maximumBytes: maximumBytes
        )
        return await withTaskCancellationHandler(
            operation: {
                await withCheckedContinuation { continuation in
                    loader.start { output in
                        continuation.resume(returning: output)
                    }
                }
            },
            onCancel: {
                loader.cancel()
            }
        )
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        var accepted = true
        if let httpResponse = response as? HTTPURLResponse,
           !(200...299).contains(httpResponse.statusCode) {
            accepted = false
        }
        if response.expectedContentLength > Int64(maximumBytes) {
            accepted = false
        }

        if accepted {
            lock.lock()
            if !finished {
                receivedResponse = response
            } else {
                accepted = false
            }
            lock.unlock()
        }

        completionHandler(accepted ? .allow : .cancel)
        if !accepted {
            finish(with: nil)
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        var exceededLimit = false

        lock.lock()
        if !finished {
            if data.count > maximumBytes - receivedData.count {
                exceededLimit = true
            } else {
                receivedData.append(data)
            }
        }
        lock.unlock()

        if exceededLimit {
            dataTask.cancel()
            finish(with: nil)
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        let output: Output?

        lock.lock()
        if error == nil, !finished, let response = receivedResponse {
            output = Output(data: receivedData, response: response)
        } else {
            output = nil
        }
        lock.unlock()

        finish(with: output)
    }

    private func finish(with output: Output?) {
        let completion: ((Output?) -> Void)?
        let session: URLSession?

        lock.lock()
        guard started, !finished else {
            lock.unlock()
            return
        }
        finished = true
        completion = self.completion
        self.completion = nil
        session = self.session
        self.session = nil
        task = nil
        receivedData.removeAll(keepingCapacity: false)
        receivedResponse = nil
        lock.unlock()

        session?.invalidateAndCancel()
        completion?(output)
    }
}

enum BoundedImageDecoder {
    static func image(
        from data: Data,
        maximumPixelCount: Int,
        maximumDimension: Int
    ) -> UIImage? {
        guard !data.isEmpty,
              maximumPixelCount > 0,
              maximumDimension > 0 else {
            return nil
        }

        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(
                  source,
                  0,
                  sourceOptions
              ) as? [CFString: Any],
              let widthNumber = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let heightNumber = properties[kCGImagePropertyPixelHeight] as? NSNumber else {
            return nil
        }

        let width = widthNumber.doubleValue
        let height = heightNumber.doubleValue
        guard width.isFinite, height.isFinite, width > 0, height > 0 else {
            return nil
        }

        let dimensionScale = min(1, Double(maximumDimension) / max(width, height))
        let pixelScale = min(
            1,
            sqrt(Double(maximumPixelCount) / (width * height))
        )
        let scale = min(dimensionScale, pixelScale)
        let thumbnailDimension = max(1, Int(floor(max(width, height) * scale)))

        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: thumbnailDimension,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            thumbnailOptions as CFDictionary
        ),
              image.width > 0,
              image.height > 0,
              image.width <= maximumDimension,
              image.height <= maximumDimension,
              image.width <= maximumPixelCount / image.height else {
            return nil
        }

        return UIImage(cgImage: image)
    }
}
