//
//  ImageHelper.swift
//  MediaPicker
//
//  Created by Kia Abdi on 12/7/23.
//

import Foundation
import UIKit

final class ImageHelper {
    enum ImageFormat {
        case jpeg
        case png
    }
    
    /// Compresses a UIImage to the specified format.
    /// - Parameters:
    ///   - uiImage: The UIImage to compress.
    ///   - compressionQuality: The quality of the compression for JPEG format (0.0 to 1.0). Ignored for PNG format.
    ///   - format: The desired image format (JPEG or PNG).
    /// - Returns: Compressed image data, or nil if compression fails. For JPEG, the quality is adjustable. For PNG, the compression is lossless.
    static func compress(uiImage: UIImage, compressionQuality: CGFloat = 0.7, format: ImageFormat = .jpeg) -> Data? {
        switch format {
        case .jpeg:
            return uiImage.jpegData(compressionQuality: compressionQuality)
        case .png:
            return uiImage.pngData()
        }
    }
}
