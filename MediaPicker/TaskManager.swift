//
//  TaskManager.swift
//  MediaPicker
//
//  Created by Kia Abdi on 12/6/23.
//

import Foundation

@MainActor
final class TaskManager: ObservableObject {
    static let imageCompressionRate: CGFloat = 0.7
    
    static let shared = TaskManager()
    
    @Published private(set) var tasks: [Tasks] = []
    
    private init() {}
    
    var isProcessing: Bool {
        tasks.contains { $0.status == .processing }
    }
    
    func newTask(_ task: Tasks) {
        self.tasks.append(task)
        
        if !self.isProcessing {
            Task {
                await self.startNextTask()
            }
        }
    }
    
    func updateTaskMediaStatus(task: Tasks, media: TasksMedia) {
        self.tasks = self.tasks.map {
            if $0.id == task.id {
                var updatedTask = task
                updatedTask.medias = $0.medias.map({ tasksMedia in
                    if tasksMedia.id == media.id {
                        return media
                    } else {
                        return tasksMedia
                    }
                })
                
                return updatedTask
            } else {
                return $0
            }
        }
    }
    
    func removeTaskMedia(task: Tasks, mediaId: String) {
        self.tasks = self.tasks.map {
            if $0.id == task.id {
                var updatedTask = task
                updatedTask.medias = $0.medias.filter({ tasksMedia in
                    return tasksMedia.id != mediaId
                })
                
                return updatedTask
            } else {
                return $0
            }
        }
    }
    
    private func startNextTask() async {
        guard let nextIndex = self.tasks.firstIndex(where: { task in
            task.status == .pending
        }) else { return }
        
        var nextTask = self.tasks[nextIndex]

        do {
            self.tasks = self.tasks.compactMap {
                if $0.id == nextTask.id {
                    nextTask.status = .processing
                    return nextTask
                } else {
                    return $0
                }
            }
            
            for media in nextTask.medias {
                if case .uncompressed(let mediaItemData) = media {
                    switch mediaItemData.state {
                    case .image(let uiImage):
                        // Convert Image
                        if let data = ImageHelper.compress(uiImage: uiImage, compressionQuality: TaskManager.imageCompressionRate) {
                            updateTaskMediaStatus(task: nextTask, media: .compressed(compressedMediaData: .image(data), mediaItemData: mediaItemData))
                        } else {
                            print("Error Compressing image")
                            removeTaskMedia(task: nextTask, mediaId: mediaItemData.id)
                        }
                    case .movie(let inputURL):
                        // Convert Movie
                        let aspectRatio: CGSize = CGSize(width: 9, height: 16)
                        let maxWidth: CGFloat = 1080
                        let outputFileName = media.id.replacingOccurrences(of: "/", with: "-") + ".mp4"
                        
                        do {
                            let outputURL = try await VideoHelper.compress(inputURL: inputURL, aspectRatio: aspectRatio, maxWidth: maxWidth, outputFileName: outputFileName)
                            if let data1 = try? Data(contentsOf: inputURL), let data2 = try? Data(contentsOf: outputURL) {
                                print("Original  : \(String(format: "%.2f", Double(data1.count) / 1024 / 1024)) MB\nCompressed: \(String(format: "%.2f", Double(data2.count) / 1024 / 1024)) MB\n\t-------------------\n\t|   Rate: %\(String(format: "%.1f", 100 * (1.0 - Double(data2.count) / Double(data1.count))))   |\n\t-------------------")
                            }
                            updateTaskMediaStatus(task: nextTask, media: .compressed(compressedMediaData: .movie(outputURL), mediaItemData: mediaItemData))
                        } catch {
                            print("Error Compressing video")
                            removeTaskMedia(task: nextTask, mediaId: mediaItemData.id)
                        }
                    }
                }
            }
            
            // TODO: Hanlde media upload
            
            try await nextTask.onReadyToSubmit(nextTask.medias.isEmpty ? nil : self.tasks.first(where: { $0.id == nextTask.id })?.medias)
            self.tasks.remove(at: nextIndex)
        } catch {
            if let onError = nextTask.onError {
                onError(error)
            }
        }
        
        await startNextTask()
    }
}

enum TasksStatus: Equatable {
    case pending
    case processing
}

enum TasksMedia: Identifiable {
    case uncompressed(mediaItemData: MediaItemData)
    case compressed(compressedMediaData: CompressedMediaData, mediaItemData: MediaItemData)
    case uploading(compressedMediaData: CompressedMediaData, mediaItemData: MediaItemData)
    case uploaded(tasksMediaAPIResponseData: TasksMediaAPIResponseData, compressedMediaData: CompressedMediaData, mediaItemData: MediaItemData)
    
    var id: String {
        switch self {
        case .uncompressed(let mediaItemData):
            mediaItemData.id
        case .compressed( _, let mediaItemData):
            mediaItemData.id
        case .uploading( _, let mediaItemData):
            mediaItemData.id
        case .uploaded( _, _, let mediaItemData):
            mediaItemData.id
        }
    }
}

enum CompressedMediaData {
    case image(Data)
    case movie(URL)
}

struct Tasks {
    let id = UUID().uuidString
    var status: TasksStatus = .pending
    let title: String
    var medias: [TasksMedia]
    var onReadyToSubmit: ([TasksMedia]?) async throws -> Void
    var onError: ((Error) -> Void)?
}

struct TasksMediaAPIResponseData: Decodable, Identifiable {
    let _id: String
    let user: String
    let key: String
    let src: String
    let type: String
    let usecase: String
    let createdAt: String
    
    var id: String {
        self._id
    }
}
struct TasksMediaAPIResponse: Decodable {
    let success: Bool
    let data: TasksMediaAPIResponseData
}
