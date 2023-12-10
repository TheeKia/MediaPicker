//
//  ContentView.swift
//  MediaPicker
//
//  Created by Kia Abdi on 12/1/23.
//

import SwiftUI
import PhotosUI
import AVKit

struct ContentView: View {
    @StateObject var vm = PickerVM()
    @ObservedObject var taskManager = TaskManager.shared
    
    var body: some View {
        VStack {
            if vm.compressed.isEmpty {
                ForEach(vm.mediaItems) { item in
                    switch item.state {
                    case .empty:
                        RoundedRectangle(cornerRadius: 10)
                            .foregroundStyle(.tertiary)
                            .frame(width: 180, height: 320)
                            .overlay {
                                Text("Empty")
                            }
                    case .loading(_):
                        RoundedRectangle(cornerRadius: 10)
                            .foregroundStyle(.tertiary)
                            .frame(width: 180, height: 320)
                            .overlay {
                                Text("Loading")
                            }
                    case .loaded(let mediaData):
                        switch mediaData {
                        case .image(let uiImage):
                            Image(uiImage: uiImage)
                                .resizable()
                                .frame(width: 180, height: 320)
                                .clipShape(.rect(cornerRadius: 10))
                        case .movie(let url):
                            VideoPlayer(player: AVPlayer(url: url))
                                .frame(width: 180, height: 320)
                                .clipShape(.rect(cornerRadius: 10))
                        }
                    case .failure(let error):
                        Text("Error: \(error.localizedDescription)")
                    }
                }
            } else {
                ForEach(vm.compressed.indices, id: \.self) { i in
                    HStack {
                        Image(systemName: "rectangle.compress.vertical")
                        switch vm.compressed[i] {
                        case .image(_):
                            Text("Image")
                        case .movie(let url):
                            VideoPlayer(player: AVPlayer(url: url))
                                .frame(width: 180, height: 320)
                                .clipShape(.rect(cornerRadius: 10))
                        }
                    }
                }
            }
            
            Spacer()
            
            HStack {
                PhotosPicker(selection: $vm.selection, maxSelectionCount: 5, photoLibrary: .shared()) {
                    Text("Pick")
                        .frame(width: 80)
                }
                .buttonStyle(.borderedProminent)
                
                Button {
                    vm.submit()
                } label: {
                    Group {
                        if taskManager.isProcessing {
                            ProgressView()
                        } else {
                            Text("Convert")
                        }
                    }
                    .frame(width: 80)
                }
                .redacted(reason: vm.isReadyToSubmit && !vm.mediaItems.isEmpty ? [] : .placeholder)
                .disabled(!vm.isReadyToSubmit)
                .buttonStyle(.bordered)
            }
            .monospaced()
            .padding(.horizontal)
        }
    }
}

#Preview {
    ContentView()
}
