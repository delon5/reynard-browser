//
//  ImagePreviewLoader.swift
//  Reynard
//
//  Created by Minh Ton on 16/6/26.
//

import Foundation
import UIKit

struct ImagePreviewLoader {
    private static let maxImageBytes = 16 * 1024 * 1024
    private static let maxImagePixelCount = 24 * 1024 * 1024
    private static let maxImageDimension = 8_192
    private static let maxDataURLHeaderBytes = 1_024

    private static let networkConfiguration: URLSessionConfiguration = {
        let configuration = URLSessionConfiguration.default
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 20
        return configuration
    }()

    static func image(from url: URL) async -> UIImage? {
        let data: Data?
        if url.isFileURL {
            data = fileData(from: url)
        } else if url.scheme?.lowercased() == "data" {
            data = dataFromDataURL(url.absoluteString)
        } else {
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.setValue("image/*,*/*;q=0.8", forHTTPHeaderField: "Accept")
            data = await BoundedURLDataLoader.data(
                for: request,
                configuration: networkConfiguration,
                maximumBytes: maxImageBytes
            )?.data
        }

        guard let data, data.count <= maxImageBytes else {
            return nil
        }
        return BoundedImageDecoder.image(
            from: data,
            maximumPixelCount: maxImagePixelCount,
            maximumDimension: maxImageDimension
        )
    }

    private static func fileData(from url: URL) -> Data? {
        guard let values = try? url.resourceValues(
            forKeys: [.fileSizeKey, .isRegularFileKey]
        ),
              values.isRegularFile == true,
              let fileSize = values.fileSize,
              fileSize >= 0,
              fileSize <= maxImageBytes,
              let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              data.count <= maxImageBytes else {
            return nil
        }
        return data
    }

    private static func dataFromDataURL(_ value: String) -> Data? {
        guard let commaIndex = value.firstIndex(of: ","),
              value[..<commaIndex].utf8.count <= maxDataURLHeaderBytes else {
            return nil
        }

        let header = value[..<commaIndex].lowercased()
        let payload = value[value.index(after: commaIndex)...]
        let data: Data?
        if header.contains(";base64") {
            let maximumEncodedBytes = ((maxImageBytes + 2) / 3) * 4
            guard payload.utf8.count <= maximumEncodedBytes else {
                return nil
            }
            data = Data(base64Encoded: String(payload))
        } else {
            guard payload.utf8.count <= maxImageBytes * 3 else {
                return nil
            }
            data = String(payload).removingPercentEncoding?.data(using: .utf8)
        }

        guard let data, data.count <= maxImageBytes else {
            return nil
        }
        return data
    }
}
