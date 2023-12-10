//
//  PickerVM.swift
//  MediaPicker
//
//  Created by Kia Abdi on 12/5/23.
//

import Foundation
import SwiftUI
import PhotosUI

@MainActor
class PickerVM: ObservableObject {
    let taskManager = TaskManager.shared
    
    @Published var selection: [PhotosPickerItem] = [] {
        didSet {
            onSelectionChange()
        }
    }
    @Published private(set) var mediaItems: [MediaItem] = []
    
    @Published var compressed: [CompressedMediaData] = []
    
    var isReadyToSubmit: Bool {
        mediaItems.allSatisfy({ mediaItem in
            if case .loaded(_) = mediaItem.state {
                return true
            } else {
                return false
            }
        })
    }
    
    func submit() {
        if !isReadyToSubmit {
            print("Not yet")
            return
        }
        
        taskManager.newTask(.init(title: "Add Review", medias: mediaItems.compactMap({ mediaItem in
            switch mediaItem.state {
            case .loaded(let mediaData):
                return TasksMedia.uncompressed(mediaItemData: .init(id: mediaItem.id, state: mediaData))
            default:
                return nil
            }
        }), onReadyToSubmit: { medias in
            if let medias = medias {
                for media in medias {
                    switch media {
                    case .compressed(let compressedMediaData, _):
                        self.compressed.append(compressedMediaData)
                    default:
                        print("")
                    }
                }
            } else {
                print("No Media")
            }
        }))
    }
    
    private func onSelectionChange() {
        self.mediaItems.removeAll()
        
        for item in selection {
            let id = item.itemIdentifier ?? UUID().uuidString
            let progress = loadTransferable(from: item, id: id)
            self.mediaItems.append(.init(id: id, state: .loading(progress)))
        }
    }
    
    private func loadTransferable(from pickerItem: PhotosPickerItem, id: String) -> Progress {
        if pickerItem.isVideo {
            return pickerItem.loadTransferable(type: Movie.self) { result in
                DispatchQueue.main.async {
                    switch result {
                    case .success(let data?):
                        self.mediaItems = self.mediaItems.map({ item in
                            if item.id == id {
                                return item.newState(state: .loaded(.movie(data.url)))
                            }
                            return item
                        })
                    case .success(nil):
                        break
                        //                    self.mediaItemsState.removeAll { item in
                        //                        item.id == id
                        //                    }
                    case .failure(let error):
                        self.mediaItems = self.mediaItems.map({ item in
                            if item.id == id {
                                return item.newState(state: .failure(error))
                            }
                            return item
                        })
                    }
                }
            }
        } else {
            return pickerItem.loadTransferable(type: Data.self) { result in
                DispatchQueue.main.async {
                    switch result {
                    case .success(let data?):
                        self.mediaItems = self.mediaItems.map({ item in
                            if item.id == id {
                                if let uiImage = UIImage(data: data) {
                                    return item.newState(state: .loaded(.image(uiImage)))
                                }
                            }
                            return item
                        })
                    case .success(nil):
                        break
                        //                    self.mediaItemsState.removeAll { item in
                        //                        item.id == id
                        //                    }
                    case .failure(let error):
                        self.mediaItems = self.mediaItems.map({ item in
                            if item.id == id {
                                return item.newState(state: .failure(error))
                            }
                            return item
                        })
                    }
                }
            }
        }
    }
}

struct MediaItem: Identifiable {
    let id: String
    var state: MediaItemState
    
    func newState(state newState: MediaItemState) -> MediaItem {
        return MediaItem(id: self.id, state: newState)
    }
}

enum MediaItemState {
    case empty
    case loading(Progress)
    case failure(Error)
    case loaded(MediaItemData.MediaData)
}


struct MediaItemData {
    let id: String
    var state: MediaData
    
    enum MediaData {
        case image(UIImage)
        case movie(URL)
    }
}

struct Movie: Transferable {
    let url: URL
    
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { receivedData in
            let fileName = receivedData.file.lastPathComponent
            let copy: URL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
            
            if FileManager.default.fileExists(atPath: copy.path) {
                try FileManager.default.removeItem(at: copy)
            }
            
            try FileManager.default.copyItem(at: receivedData.file, to: copy)
            return .init(url: copy)
        }
    }
}

extension PhotosPickerItem {
    var isVideo: Bool {
        let videoTypes: Set<UTType> = [.mpeg4Movie, .movie, .video, .quickTimeMovie, .appleProtectedMPEG4Video, .avi, .mpeg, .mpeg2Video]
        return supportedContentTypes.contains(where: videoTypes.contains)
    }
    
    var isImage: Bool {
        let imageTypes: Set<UTType> = [.jpeg, .png, .gif, .tiff, .rawImage, .heic]
        return supportedContentTypes.contains(where: imageTypes.contains)
    }
}
