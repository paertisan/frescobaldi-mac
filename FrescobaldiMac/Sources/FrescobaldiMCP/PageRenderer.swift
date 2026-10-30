import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Renders PDF pages to PNG so a model can look at the engraved score.
public enum PageRenderer {
    public struct Page: Sendable {
        public var png: Data
        public var pageCount: Int
        public var width: Int
        public var height: Int
        /// Blank stretches were shortened.
        public var trimmed: Bool
    }

    /// Renders page `number` (1-based) of `pdf`, `width` pixels wide on
    /// white. With `trim`, runs of blank rows taller than `maxGap` pixels are
    /// shortened to `maxGap`, so a short score on a big page stays compact.
    public static func render(pdf: URL, page number: Int, width: Int = 1000, trim: Bool = true,
                              maxGap: Int = 40) throws -> Page {
        guard let document = CGPDFDocument(pdf as CFURL) else {
            throw MCPToolError("Couldn't open \(pdf.path) as a PDF.")
        }
        let count = document.numberOfPages
        guard count > 0 else { throw MCPToolError("\(pdf.lastPathComponent) has no pages.") }
        guard (1...count).contains(number), let page = document.page(at: number) else {
            throw MCPToolError("\(pdf.lastPathComponent) has \(count) page\(count == 1 ? "" : "s"); there's no page \(number).")
        }
        let box = page.getBoxRect(.cropBox)
        let scale = CGFloat(width) / box.width
        let height = max(1, Int((box.height * scale).rounded()))
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 255, count: bytesPerRow * height)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let bitmapInfo = CGImageAlphaInfo.noneSkipLast.rawValue

        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: bytesPerRow, space: colorSpace,
                                          bitmapInfo: bitmapInfo) else { return false }
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.interpolationQuality = .high
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: -box.minX, y: -box.minY)
            context.drawPDFPage(page)
            return true
        }
        guard drawn else { throw MCPToolError("Couldn't render the page.") }

        var rows = Array(0..<height)
        if trim { rows = keptRows(pixels, width: width, height: height, maxGap: maxGap) }
        let trimmed = rows.count < height
        var output = [UInt8]()
        output.reserveCapacity(rows.count * bytesPerRow)
        for row in rows { output.append(contentsOf: pixels[row * bytesPerRow..<(row + 1) * bytesPerRow]) }

        guard let provider = CGDataProvider(data: Data(output) as CFData),
              let image = CGImage(width: width, height: rows.count, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: bytesPerRow, space: colorSpace,
                                  bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo), provider: provider,
                                  decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
            throw MCPToolError("Couldn't create the image.")
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
        else { throw MCPToolError("Couldn't encode PNG.") }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw MCPToolError("Couldn't encode PNG.") }
        return Page(png: data as Data, pageCount: count, width: width, height: rows.count, trimmed: trimmed)
    }

    /// Row indices to keep: every row with ink, and at most `maxGap` rows of
    /// each blank stretch (also at the top and bottom).
    static func keptRows(_ pixels: [UInt8], width: Int, height: Int, maxGap: Int) -> [Int] {
        let bytesPerRow = width * 4
        func isBlank(_ row: Int) -> Bool {
            let start = row * bytesPerRow
            var i = start
            while i < start + bytesPerRow {
                if pixels[i] < 235 || pixels[i + 1] < 235 || pixels[i + 2] < 235 { return false }
                i += 4
            }
            return true
        }
        var kept: [Int] = []
        var blankRun = 0
        for row in 0..<height {
            if isBlank(row) {
                blankRun += 1
                if blankRun <= maxGap { kept.append(row) }
            } else {
                blankRun = 0
                kept.append(row)
            }
        }
        return kept.isEmpty ? [0] : kept
    }
}
