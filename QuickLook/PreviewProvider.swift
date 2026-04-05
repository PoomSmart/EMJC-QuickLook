//
//  PreviewProvider.swift
//  QuickLook
//
//  Created by PoomSmart on 5/4/2026.
//

import Cocoa
import Quartz
import UniformTypeIdentifiers
import OSLog

private let logger = Logger(subsystem: "com.ps.EMJC.QuickLook", category: "preview")

class PreviewProvider: QLPreviewProvider, QLPreviewingController {

    func providePreview(for request: QLFilePreviewRequest) async throws -> QLPreviewReply {
        let url = request.fileURL
        logger.info("providePreview called for: \(url.lastPathComponent)")

        let didAccess = url.startAccessingSecurityScopedResource()
        logger.info("startAccessingSecurityScopedResource returned: \(didAccess)")
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }

        let fontData: Data
        do {
            fontData = try Data(contentsOf: url)
        } catch {
            logger.error("Failed to read font data: \(error)")
            throw error
        }
        logger.info("Font data size: \(fontData.count) bytes")

        // Bail out immediately for fonts with no sbix/EMJC table so QL shows a clear error
        // rather than a blank preview, and we don't hijack previews for non-emoji TTCs.
        guard hasSbixTable(fontData: fontData) else {
            logger.info("No sbix table found — not an emoji TTC, skipping")
            throw CocoaError(.fileReadUnknown,
                             userInfo: [NSLocalizedDescriptionKey: "Not an emoji font (no sbix table)."])
        }

        // Select curated 30 glyphs: 2 rows of emoji + row of 0–9 keycap digits (matches macOS Font Book).
        let glyphs = selectCuratedSbixGlyphs(fontData: fontData, preferredPPEM: 160)
        logger.info("Selected \(glyphs.count) curated glyphs")
        if let first = glyphs.first {
            logger.info("First glyph: name=\(first.name) ppem=\(first.ppem) type=\(first.graphicType)")
        }

        // Render preview image
        let cellSize = 100
        let columns = 10
        guard let grid = renderEmojiGrid(from: glyphs, cellSize: cellSize, columns: columns, maxCount: 200) else {
            logger.warning("renderEmojiGrid returned nil — falling back to plain text")
            let reply = QLPreviewReply(dataOfContentType: .plainText,
                                       contentSize: CGSize(width: 400, height: 100)) { _ in
                return Data("No EMJC or PNG emoji found in this font's sbix table.".utf8)
            }
            return reply
        }
        logger.info("Grid rendered: \(grid.size.width)x\(grid.size.height)")

        let gridSize = grid.size
        let reply = QLPreviewReply(dataOfContentType: .png, contentSize: gridSize) { _ in
            guard let tiff = grid.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff),
                  let png = bitmap.representation(using: .png, properties: [:]) else {
                logger.error("PNG conversion failed")
                return Data()
            }
            logger.info("Returning PNG of \(png.count) bytes")
            return png
        }
        return reply
    }
}
