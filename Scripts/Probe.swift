// Prints duration, dimensions and tracks of a media file (AVFoundation).
// Usage: swift Scripts/Probe.swift <file>
import Foundation
import AVFoundation

guard CommandLine.arguments.count == 2 else {
    print("usage: swift Probe.swift <media-file>")
    exit(1)
}

let url = URL(fileURLWithPath: CommandLine.arguments[1])
let asset = AVURLAsset(url: url)

let duration = try! await asset.load(.duration)
print(String(format: "duration: %.2f s", CMTimeGetSeconds(duration)))

let videoTracks = try! await asset.loadTracks(withMediaType: .video)
let audioTracks = try! await asset.loadTracks(withMediaType: .audio)

if let video = videoTracks.first {
    if let size = try? await video.load(.naturalSize) {
        print("video: \(Int(size.width))×\(Int(size.height))")
    }
} else {
    print("video: none")
}

print(audioTracks.isEmpty ? "audio: none" : "audio: present (\(audioTracks.count) track)")

if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
   let size = attrs[.size] as? Int {
    print("file size: \(size) bytes (\(String(format: "%.2f", Double(size) / 1_048_576)) MiB)")
}
