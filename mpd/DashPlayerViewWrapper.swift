import SwiftUI

struct DashPlayerViewWrapper: UIViewRepresentable {
    let sampleBufferPlayer: DashSampleBufferPlayer

    func makeUIView(context: Context) -> DashPlayerView {
        DashPlayerView(player: sampleBufferPlayer)
    }

    func updateUIView(_ uiView: DashPlayerView, context: Context) {
        // No updates needed for now
    }
}
