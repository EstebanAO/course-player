#if MEDIA_PROBE
import Foundation
import AVFoundation

@main
struct MediaProbe {
    static func main() async {
        guard CommandLine.arguments.count > 1 else { exit(2) }
        let asset = AVURLAsset(url: URL(fileURLWithPath: CommandLine.arguments[1]))
        do {
            let duration = try await asset.load(.duration)
            let video = try await asset.loadTracks(withMediaType: .video)
            let audio = try await asset.loadTracks(withMediaType: .audio)
            print("duration=\(duration.seconds) videoTracks=\(video.count) audioTracks=\(audio.count)")
            exit(video.isEmpty ? 1 : 0)
        } catch {
            print("error=\(error)")
            exit(1)
        }
    }
}
#endif
