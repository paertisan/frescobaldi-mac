import AppKit
import FrescobaldiCore
import PDFKit
import SwiftUI

/// The New Score wizard's preview: page 1 of the score being set up,
/// engraved by LilyPond a moment after each change.
@MainActor
final class ScorePreview: ObservableObject {
    /// The whole page.
    @Published private(set) var page: NSImage?
    /// Just the music, larger.
    @Published private(set) var music: NSImage?
    @Published private(set) var isEngraving = false
    /// Why there's no up-to-date picture.
    @Published private(set) var problem: String?

    private let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("Frescobaldi-new-score-\(UUID().uuidString.prefix(8))", isDirectory: true)
    private var shown: ScoreSpec?
    private var pending: DispatchWorkItem?
    private var job: EngraveJob?
    private var run = 0

    func update(_ spec: ScoreSpec) {
        guard spec != shown else { return }
        shown = spec
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.engrave(spec) }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    /// Stops engraving and removes the temporary files.
    func stop() {
        pending?.cancel()
        job?.cancel()
        try? FileManager.default.removeItem(at: folder)
    }

    private func engrave(_ spec: ScoreSpec) {
        job?.cancel()
        job = nil
        guard !spec.players.isEmpty else {
            page = nil
            music = nil
            isEngraving = false
            problem = "Add an instrument to see the score."
            return
        }
        guard let lilypond = Preferences.lilypond() else {
            problem = "LilyPond wasn't found, so there's no preview. Set its location in Settings."
            return
        }
        run += 1
        let run = run
        // The score is enough: no parts, no MIDI.
        var score = spec
        score.makeParts = false
        score.midi = false
        do {
            // Named as the project will be without a title of its own.
            let main = try ProjectTemplate.write(score, to: folder.appendingPathComponent("\(run)/Untitled Score"),
                                                 version: AppDelegate.shared.lilypondVersion)
            let job = EngraveJob(lilypond: lilypond, source: main, mode: .publish)
            try job.start(output: { _ in }, completion: { result in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self.finished(result, run: run) }
                }
            })
            self.job = job
            isEngraving = true
        } catch {
            isEngraving = false
            problem = error.localizedDescription
        }
    }

    private func finished(_ result: EngraveJob.Result, run: Int) {
        let data = result.pdfs.first.flatMap { try? Data(contentsOf: $0) }
        try? FileManager.default.removeItem(at: folder.appendingPathComponent("\(run)"))
        // A newer run replaces this one.
        guard run == self.run, !result.cancelled else { return }
        job = nil
        isEngraving = false
        if let data, let pdfPage = PDFDocument(data: data)?.page(at: 0), let rendered = Self.render(pdfPage) {
            page = rendered.page
            music = rendered.music
            problem = nil
        } else {
            problem = result.messages.first(where: \.severity.isError)?.message
                ?? "LilyPond couldn't engrave the score."
        }
    }
}

extension ScorePreview {
    /// The page at 1200 pixels wide, and the part of it with ink on it.
    static func render(_ page: PDFPage) -> (page: NSImage, music: NSImage)? {
        let bounds = page.bounds(for: .mediaBox)
        let width = 1200
        let scale = CGFloat(width) / bounds.width
        let height = Int(bounds.height * scale)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(.white)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -bounds.minX, y: -bounds.minY)
        page.draw(with: .mediaBox, to: context)
        guard let image = context.makeImage(), let data = context.data else { return nil }

        // The ink's bounding box; rows are stored top to bottom.
        let pixels = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        var (minX, minY, maxX, maxY) = (width, height, -1, -1)
        for y in 0..<height {
            let row = pixels + y * width * 4
            for x in 0..<width where row[x * 4] < 200 || row[x * 4 + 1] < 200 || row[x * 4 + 2] < 200 {
                minX = min(minX, x)
                maxX = max(maxX, x)
                minY = min(minY, y)
                maxY = max(maxY, y)
            }
        }
        let size = { (image: CGImage) in NSSize(width: CGFloat(image.width) / 2, height: CGFloat(image.height) / 2) }
        let whole = NSImage(cgImage: image, size: size(image))
        guard maxX >= minX else { return (whole, whole) }
        let margin = width / 40
        let crop = CGRect(x: minX - margin, y: minY - margin, width: maxX - minX + 2 * margin, height: maxY - minY + 2 * margin)
            .intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard let music = image.cropping(to: crop) else { return (whole, whole) }
        return (whole, NSImage(cgImage: music, size: size(music)))
    }
}

struct ScorePreviewPane: View {
    @ObservedObject var preview: ScorePreview
    @State private var wholePage = false

    var body: some View {
        VStack(spacing: 10) {
            ZStack(alignment: .topTrailing) {
                if let image = wholePage ? preview.page : preview.music {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .background(Color.white)
                        .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
                        .onTapGesture { wholePage.toggle() }
                        .help(wholePage ? "Click to zoom in on the music" : "Click to see the whole page")
                } else {
                    Rectangle()
                        .fill(Color.white.opacity(0.08))
                        .aspectRatio(210 / 297, contentMode: .fit)
                }
                if preview.isEngraving {
                    ProgressView()
                        .controlSize(.small)
                        .padding(8)
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
            Text(preview.problem ?? (wholePage ? "Page 1 of the score. Click to zoom in." : "The start of the score. Click for the whole page."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 300)
        .frame(maxHeight: .infinity)
        .background(Color(nsColor: .underPageBackgroundColor))
    }
}
