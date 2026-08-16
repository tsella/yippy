import SwiftUI
import MobileVLCKit

struct RTSPPlayerView: UIViewRepresentable {
    var url: URL
    
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        
        let mediaPlayer = VLCMediaPlayer()
        mediaPlayer.drawable = view
        
        let media = VLCMedia(url: url)
        // Add options to reduce latency
        media.addOption(":network-caching=300")
        media.addOption(":clock-jitter=0")
        media.addOption(":clock-synchro=0")
        
        mediaPlayer.media = media
        mediaPlayer.play()
        
        context.coordinator.mediaPlayer = mediaPlayer
        
        return view
    }
    
    func updateUIView(_ uiView: UIView, context: Context) {
        // Handle updates
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }
    
    class Coordinator: NSObject {
        var mediaPlayer: VLCMediaPlayer?
        
        deinit {
            mediaPlayer?.stop()
        }
    }
}
