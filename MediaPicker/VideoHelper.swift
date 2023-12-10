//
//  VideoHelper.swift
//  MediaPicker
//
//  Created by Kia Abdi on 12/7/23.
//

import Foundation
import AVKit
import AVFoundation

final class VideoHelper {
    static let maxBitrate: Float = 4000000
    static let maxFPS: Float = 30
    
    private enum VideoProcessingError: Error {
        case noVideoTrack
        case assetReaderCreationFailed
        case assetWriterCreationFailed
        case assetReaderCantStartReading
    }
    
    static func compress(inputURL: URL, aspectRatio: CGSize, maxWidth: CGFloat, outputFileName: String? = nil, keepAudio: Bool = true) async throws -> URL {
        let theOutputFileName = outputFileName ?? UUID().uuidString
        
        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent(theOutputFileName)
        
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try? FileManager.default.removeItem(at: outputURL)
        }
        
        let asset = AVAsset(url: inputURL)
        
        guard let videoTrack = try? await asset.loadTracks(withMediaType: .video).first,
              let duration = try? await asset.load(.duration),
              let preferredTransform = try? await videoTrack.load(.preferredTransform),
              let sizeAndOrientation = await VideoHelper.getCorrectedNaturalSize(videoTrack: videoTrack, preferredTransform: preferredTransform),
              let currentBitRate = try? await videoTrack.load(.estimatedDataRate),
              let currentFPS = try? await videoTrack.load(.nominalFrameRate) else {
            throw VideoProcessingError.noVideoTrack
        }
        
        let targetBitrate = min(currentBitRate, VideoHelper.maxBitrate)
        let targetFPS = min(currentFPS, VideoHelper.maxFPS)
        let targetSize: CGSize = VideoHelper.getTargetSize(currentSizeAndOrientation: sizeAndOrientation, maxWidth: maxWidth, aspectRatio: aspectRatio)
        
        guard let assetReader = try? AVAssetReader(asset: asset) else {
            throw VideoProcessingError.assetReaderCreationFailed
        }
        
        let videoAssetReaderOutputSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange),
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ]
        let videoAssetReaderOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: videoAssetReaderOutputSettings)
        assetReader.add(videoAssetReaderOutput)
        
        guard let assetWriter = try? AVAssetWriter(outputURL: outputURL, fileType: .mp4) else {
            throw VideoProcessingError.assetWriterCreationFailed
        }
        
        let audioTrack = try? await asset.loadTracks(withMediaType: .audio).first
        
        // MARK: Settings
        let audioAssetReaderOutputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false
        ]
        let audioAssetWriterInputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44100,
            AVEncoderBitRateKey: 128000,
            AVNumberOfChannelsKey: 2
        ]
        let videoAssetWriterInputSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: targetSize.width,
            AVVideoHeightKey: targetSize.height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: targetBitrate,
                AVVideoMaxKeyFrameIntervalKey: targetFPS,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ],
            AVVideoScalingModeKey: AVVideoScalingModeResizeAspect
        ]
        let sourcePixelBufferAttributes: [String : Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferWidthKey as String: targetSize.width,
            kCVPixelBufferHeightKey as String: targetSize.height,
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ]
        
        return try await withCheckedThrowingContinuation { continuation in
            if keepAudio, let audioTrack {
                // MARK: - WITH AUDIO
                // Get uncompressed audio
                let audioAssetReaderOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: audioAssetReaderOutputSettings)
                assetReader.add(audioAssetReaderOutput)
                
                let audioAssetWriterInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioAssetWriterInputSettings)
                
                /// if `true` cant set expectsMediaDataInRealTime to true
                /// Don't change to `true` unless implemenation has been finished
                audioAssetWriterInput.performsMultiPassEncodingIfSupported = false
                
                assetWriter.add(audioAssetWriterInput)
                
                let videoAssetWriterInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoAssetWriterInputSettings)
                videoAssetWriterInput.transform = preferredTransform
                
                /// if `true` cant set expectsMediaDataInRealTime to true
                /// Don't change to `true` unless implemenation has been finished
                videoAssetWriterInput.performsMultiPassEncodingIfSupported = false
                
                let pixelBufferAdaptor = AVAssetWriterInputPixelBufferAdaptor(
                    assetWriterInput: videoAssetWriterInput,
                    sourcePixelBufferAttributes: sourcePixelBufferAttributes
                )
                assetWriter.add(videoAssetWriterInput)
                
                guard assetReader.startReading() else {
                    continuation.resume(throwing: VideoProcessingError.assetReaderCantStartReading)
                    return
                }
                assetWriter.startWriting()
                assetWriter.startSession(atSourceTime: .zero)
                
                let queueLabel = "ai.phantomphood.videoCompressionQueue.\(UUID().uuidString)"
                let processingQueue = DispatchQueue(label: queueLabel)
                
                if audioAssetWriterInput.canPerformMultiplePasses {
                    // TODO: WIP
                    audioAssetWriterInput.respondToEachPassDescription(on: processingQueue) {
                        if audioAssetWriterInput.currentPassDescription == nil {
                            audioAssetWriterInput.markAsFinished()
                            
                            if videoAssetWriterInput.currentPassDescription == nil {
                                assetWriter.finishWriting {
                                    continuation.resume(returning: outputURL)
                                }
                            }
                        } else {
                            audioAssetWriterInput.requestMediaDataWhenReady(on: processingQueue) {
                                while audioAssetWriterInput.isReadyForMoreMediaData {
                                    autoreleasepool {
                                        if let audioBuffer = audioAssetReaderOutput.copyNextSampleBuffer() {
                                            audioAssetWriterInput.append(audioBuffer)
                                        } else {
                                            audioAssetWriterInput.markCurrentPassAsFinished()
                                        }
                                    }
                                }
                            }
                        }
                    }
                } else {
                    audioAssetWriterInput.requestMediaDataWhenReady(on: processingQueue) {
                        while audioAssetWriterInput.isReadyForMoreMediaData {
                            autoreleasepool {
                                if let audioBuffer = audioAssetReaderOutput.copyNextSampleBuffer() {
                                    audioAssetWriterInput.append(audioBuffer)
                                } else {
                                    audioAssetWriterInput.markAsFinished()
                                    
                                    if videoAssetWriterInput.currentPassDescription == nil {
                                        assetWriter.finishWriting {
                                            continuation.resume(returning: outputURL)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                
                if videoAssetWriterInput.canPerformMultiplePasses {
                    // TODO: WIP
                    videoAssetWriterInput.respondToEachPassDescription(on: processingQueue) {
                        if videoAssetWriterInput.currentPassDescription == nil {
                            videoAssetWriterInput.markAsFinished()
                            
                            if audioAssetWriterInput.currentPassDescription == nil {
                                assetWriter.finishWriting {
                                    continuation.resume(returning: outputURL)
                                }
                            }
                        } else {
                            videoAssetWriterInput.requestMediaDataWhenReady(on: processingQueue) {
                                while videoAssetWriterInput.isReadyForMoreMediaData {
                                    autoreleasepool {
                                        if let sampleBuffer = videoAssetReaderOutput.copyNextSampleBuffer() {
                                            let presenationTimeStamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                                            print(presenationTimeStamp.seconds / duration.seconds)
                                            if let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
                                               let scaledBuffer = self.scale(buffer: pixelBuffer, toSize: targetSize, withTransform: preferredTransform) {
                                                if videoAssetWriterInput.isReadyForMoreMediaData {
                                                    pixelBufferAdaptor.append(scaledBuffer, withPresentationTime: presenationTimeStamp)
                                                }
                                            }
                                        } else {
                                            videoAssetWriterInput.markCurrentPassAsFinished()
                                        }
                                    }
                                }
                            }
                        }
                    }
                } else {
                    videoAssetWriterInput.requestMediaDataWhenReady(on: processingQueue) {
                        while videoAssetWriterInput.isReadyForMoreMediaData {
                            autoreleasepool {
                                if let sampleBuffer = videoAssetReaderOutput.copyNextSampleBuffer() {
                                    let presenationTimeStamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                                    print(presenationTimeStamp.seconds / duration.seconds)
                                    if let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
                                       let scaledBuffer = self.scale(buffer: pixelBuffer, toSize: targetSize, withTransform: preferredTransform) {
                                        if videoAssetWriterInput.isReadyForMoreMediaData {
                                            pixelBufferAdaptor.append(scaledBuffer, withPresentationTime: presenationTimeStamp)
                                        }
                                    }
                                } else {
                                    videoAssetWriterInput.markAsFinished()
                                    
                                    if audioAssetWriterInput.currentPassDescription == nil {
                                        assetWriter.finishWriting {
                                            continuation.resume(returning: outputURL)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                
            } else {
                // MARK: - NO AUDIO
                let videoAssetWriterInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoAssetWriterInputSettings)
                videoAssetWriterInput.transform = preferredTransform
                
                /// if `true` cant set expectsMediaDataInRealTime to true
                /// Don't change to `true` unless implemenation has been finished
                videoAssetWriterInput.performsMultiPassEncodingIfSupported = false
                
                let pixelBufferAdaptor = AVAssetWriterInputPixelBufferAdaptor(
                    assetWriterInput: videoAssetWriterInput,
                    sourcePixelBufferAttributes: sourcePixelBufferAttributes
                )
                assetWriter.add(videoAssetWriterInput)
                
                guard assetReader.startReading() else {
                    continuation.resume(throwing: VideoProcessingError.assetReaderCantStartReading)
                    return
                }
                assetWriter.startWriting()
                assetWriter.startSession(atSourceTime: .zero)
                
                let queueLabel = "ai.phantomphood.videoCompressionQueue.\(UUID().uuidString)"
                let processingQueue = DispatchQueue(label: queueLabel)
                
                videoAssetWriterInput.requestMediaDataWhenReady(on: processingQueue) {
                    while videoAssetWriterInput.isReadyForMoreMediaData {
                        autoreleasepool {
                            if let sampleBuffer = videoAssetReaderOutput.copyNextSampleBuffer() {
                                let presenationTimeStamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                                print(presenationTimeStamp.seconds / duration.seconds)
                                if let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
                                   let scaledBuffer = self.scale(buffer: pixelBuffer, toSize: targetSize, withTransform: preferredTransform) {
                                    if videoAssetWriterInput.isReadyForMoreMediaData {
                                        pixelBufferAdaptor.append(scaledBuffer, withPresentationTime: presenationTimeStamp)
                                    }
                                }
                            } else {
                                videoAssetWriterInput.markAsFinished()
                                assetWriter.finishWriting {
                                    continuation.resume(returning: outputURL)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    
    static func getTargetSize(currentSizeAndOrientation: (naturalSize: CGSize, isPortrait: Bool), maxWidth: CGFloat, aspectRatio: CGSize) -> CGSize {
        let currentSize = currentSizeAndOrientation.naturalSize
        let size = currentSize.width * aspectRatio.height / aspectRatio.width > currentSize.height ?
        (currentSize.height * aspectRatio.width / aspectRatio.height >= maxWidth ? // maxSize
         CGSize(width: maxWidth, height: maxWidth * aspectRatio.height / aspectRatio.width) :
            CGSize(width: currentSize.height * aspectRatio.width / aspectRatio.height, height: currentSize.height)) :
        (currentSize.width >= maxWidth ? // maxSize
         CGSize(width: maxWidth, height: maxWidth * aspectRatio.height / aspectRatio.width) :
            CGSize(width: currentSize.width, height: currentSize.width * aspectRatio.height / aspectRatio.width))
        
        return currentSizeAndOrientation.isPortrait ? CGSize(width: size.height, height: size.width) : size
    }
    
    static func getCorrectedNaturalSize(videoTrack: AVAssetTrack, preferredTransform transform: CGAffineTransform) async -> (naturalSize: CGSize, isPortrait: Bool)? {
        guard let naturalSize = try? await videoTrack.load(.naturalSize) else {
            return nil
        }
        
        // Check if the video is in portrait orientation by examining the transform
        let isPortrait = abs(transform.a) == 0 && abs(transform.d) == 0
        
        // If the video is in portrait, swap the width and height
        if isPortrait {
            return (CGSize(width: naturalSize.height, height: naturalSize.width), true)
        } else {
            return (naturalSize, false)
        }
    }
    
    // CIContext to be used for rendering
    static let ciContext = CIContext()
    // Function to scale the image buffer
    static func scale(buffer: CVPixelBuffer, toSize size: CGSize, withTransform transform: CGAffineTransform) -> CVPixelBuffer? {
        let ciImage = CIImage(cvPixelBuffer: buffer)
        
        let originalWidth = CGFloat(CVPixelBufferGetWidth(buffer))
        let originalHeight = CGFloat(CVPixelBufferGetHeight(buffer))
        let scaleX = size.width / originalWidth
        let scaleY = size.height / originalHeight
        let scale = max(scaleX, scaleY) // Maintain aspect ratio
        
        // Calculate translation to center the image if necessary
        let scaledWidth = originalWidth * scale
        let scaledHeight = originalHeight * scale
        let translateX = (size.width - scaledWidth) / 2
        let translateY = (size.height - scaledHeight) / 2
        
        // Apply scaling and translation
        let scaledImage = ciImage
            .transformed(by: CGAffineTransform(translationX: translateX, y: translateY))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        
        // Prepare a new pixel buffer
        var newPixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault,
                                         Int(size.width),
                                         Int(size.height),
                                         CVPixelBufferGetPixelFormatType(buffer),
                                         nil,
                                         &newPixelBuffer)
        
        if status != kCVReturnSuccess {
            // Log error or handle failure
            return nil
        }
        
        guard let unwrappedBuffer = newPixelBuffer else {
            return nil
        }
        
        // Render the scaled image back to the new pixel buffer
        ciContext.render(scaledImage, to: unwrappedBuffer)
        
        return unwrappedBuffer
    }
}
