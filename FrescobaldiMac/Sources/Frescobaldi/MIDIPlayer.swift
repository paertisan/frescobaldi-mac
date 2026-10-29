import AVFoundation
import Combine

/// Plays LilyPond's MIDI output with the General MIDI sound bank built into macOS.
final class MIDIPlayer: ObservableObject {
    @Published private(set) var isPlaying = false
    private var player: AVMIDIPlayer?

    func play(_ url: URL) throws {
        stop()
        let bank = FileManager.default.fileExists(atPath: AppResources.soundBank.path) ? AppResources.soundBank : nil
        let player = try AVMIDIPlayer(contentsOf: url, soundBankURL: bank)
        player.prepareToPlay()
        self.player = player
        isPlaying = true
        player.play { [weak self] in
            DispatchQueue.main.async {
                if self?.player === player {
                    self?.isPlaying = false
                }
            }
        }
    }

    func stop() {
        player?.stop()
        player = nil
        isPlaying = false
    }
}
