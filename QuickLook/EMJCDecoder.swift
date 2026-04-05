//
//  EMJCDecoder.swift
//  QuickLook
//
//  Decodes Apple's EMJC image format and extracts emoji bitmaps from the
//  sbix table of an AppleColorEmoji TTF/TTC font.
//
//  EMJC spec: see EMJC.md in the EmojiFonts project.
//  Decoder algorithm: ported from emjc.py (credit: cc4966/emjc-decoder).
//

import Foundation
import Compression
import Cocoa
import OSLog
import CoreText

private let _keycapLogger = Logger(subsystem: "com.ps.EMJC.QuickLook", category: "keycap")

// MARK: - EMJC Decoder

/// Decodes an EMJC blob into a raw BGRA byte buffer.
/// Returns `nil` if the magic header is wrong or decompression fails.
func decodeEMJC(_ data: Data) -> (pixels: Data, width: Int, height: Int)? {
    guard data.count >= 16 else { return nil }

    // Magic: big-endian "emj1"
    guard data[0] == 0x65, data[1] == 0x6D, data[2] == 0x6A, data[3] == 0x31 else { return nil }

    let width  = Int(data.readLE16(at: 8))
    let height = Int(data.readLE16(at: 10))
    let appendixLength = Int(data.readLE16(at: 12))

    guard width > 0, height > 0 else { return nil }

    let pixelCount  = width * height
    let filterLen   = height
    let colorLen    = pixelCount * 3
    let dstLength   = pixelCount + filterLen + colorLen + appendixLength

    // Decompress lzfse payload starting at byte 16
    let compressed = data.subdata(in: 16 ..< data.count)
    guard let decompressed = lzfseDecompress(compressed, expectedSize: dstLength) else { return nil }
    guard decompressed.count == dstLength else { return nil }

    let alphaSlice    = decompressed[0 ..< pixelCount]
    let filterSlice   = decompressed[pixelCount ..< pixelCount + filterLen]
    let rgbSlice      = decompressed[(pixelCount + filterLen) ..< (pixelCount + filterLen + colorLen)]
    let appendixSlice = decompressed[(pixelCount + filterLen + colorLen)...]

    // Intermediate buffer: 3 signed integers per pixel (base/p/q)
    var buf = [Int32](repeating: 0, count: colorLen + 3)  // +3 guard for stride

    // Apply appendix overrides
    var offset = 0
    for i in 0 ..< appendixLength {
        let a = Int(appendixSlice[appendixSlice.startIndex + i])
        offset += a / 4
        if offset >= colorLen { break }
        buf[offset] = Int32(128 * (a % 4))
        offset += 1
    }

    var dst = Data(count: pixelCount * 4)

    dst.withUnsafeMutableBytes { dstPtr in
        let dstRaw = dstPtr.bindMemory(to: UInt8.self)

        for y in 0 ..< height {
            let filter = Int(filterSlice[filterSlice.startIndex + y])

            for x in 0 ..< width {
                let i = y * width + x

                // Decode zigzag residuals into buf
                buf[i*3+0] = convertToDifference(Int32(rgbSlice[rgbSlice.startIndex + i*3+0]), offset: buf[i*3+0])
                buf[i*3+1] = convertToDifference(Int32(rgbSlice[rgbSlice.startIndex + i*3+1]), offset: buf[i*3+1])
                buf[i*3+2] = convertToDifference(Int32(rgbSlice[rgbSlice.startIndex + i*3+2]), offset: buf[i*3+2])

                // Apply spatial prediction filter
                switch filter {
                case 1:
                    if x > 0 && y > 0 {
                        let left      = buf[(i-1)*3+0]
                        let upper     = buf[(i-width)*3+0]
                        let leftUpper = buf[(i-width-1)*3+0]
                        if abs(left - leftUpper) < abs(upper - leftUpper) {
                            buf[i*3+0] += buf[(i-width)*3+0]
                            buf[i*3+1] += buf[(i-width)*3+1]
                            buf[i*3+2] += buf[(i-width)*3+2]
                        } else {
                            buf[i*3+0] += buf[(i-1)*3+0]
                            buf[i*3+1] += buf[(i-1)*3+1]
                            buf[i*3+2] += buf[(i-1)*3+2]
                        }
                    } else if x > 0 {
                        buf[i*3+0] += buf[(i-1)*3+0]
                        buf[i*3+1] += buf[(i-1)*3+1]
                        buf[i*3+2] += buf[(i-1)*3+2]
                    } else if y > 0 {
                        buf[i*3+0] += buf[(i-width)*3+0]
                        buf[i*3+1] += buf[(i-width)*3+1]
                        buf[i*3+2] += buf[(i-width)*3+2]
                    }
                case 2:
                    if x > 0 {
                        buf[i*3+0] += buf[(i-1)*3+0]
                        buf[i*3+1] += buf[(i-1)*3+1]
                        buf[i*3+2] += buf[(i-1)*3+2]
                    }
                case 3:
                    if y > 0 {
                        buf[i*3+0] += buf[(i-width)*3+0]
                        buf[i*3+1] += buf[(i-width)*3+1]
                        buf[i*3+2] += buf[(i-width)*3+2]
                    }
                case 4:
                    if x > 0 && y > 0 {
                        buf[i*3+0] += filter4Value(buf[(i-1)*3+0], buf[(i-width)*3+0])
                        buf[i*3+1] += filter4Value(buf[(i-1)*3+1], buf[(i-width)*3+1])
                        buf[i*3+2] += filter4Value(buf[(i-1)*3+2], buf[(i-width)*3+2])
                    } else if x > 0 {
                        buf[i*3+0] += buf[(i-1)*3+0]
                        buf[i*3+1] += buf[(i-1)*3+1]
                        buf[i*3+2] += buf[(i-1)*3+2]
                    } else if y > 0 {
                        buf[i*3+0] += buf[(i-width)*3+0]
                        buf[i*3+1] += buf[(i-width)*3+1]
                        buf[i*3+2] += buf[(i-width)*3+2]
                    }
                default: break  // filter 0: no prediction
                }

                // Inverse YCoCg-R color transform
                let base = buf[i*3+0]
                let p    = buf[i*3+1]
                let q    = buf[i*3+2]
                let r: Int32
                let g: Int32
                let b: Int32
                if p < 0 && q < 0 {
                    r = base + p/2 - (q+1)/2
                    g = base + q/2
                    b = base - (p+1)/2 - (q+1)/2
                } else if p < 0 {
                    r = base + p/2 - q/2
                    g = base + (q+1)/2
                    b = base - (p+1)/2 - q/2
                } else if q < 0 {
                    r = base + (p+1)/2 - (q+1)/2
                    g = base + q/2
                    b = base - p/2 - (q+1)/2
                } else {
                    r = base + (p+1)/2 - q/2
                    g = base + (q+1)/2
                    b = base - p/2 - q/2
                }

                // mod-257 wrap (matching Python's b % 257 with negative support)
                let a = UInt8(alphaSlice[alphaSlice.startIndex + i])
                dstRaw[i*4+0] = mod257(b)
                dstRaw[i*4+1] = mod257(g)
                dstRaw[i*4+2] = mod257(r)
                dstRaw[i*4+3] = a
            }
        }
    }

    return (dst, width, height)
}

// MARK: - Helper arithmetic (matching Python decoder exactly)

@inline(__always)
private func convertToDifference(_ value: Int32, offset: Int32) -> Int32 {
    if value & 1 != 0 {
        return -(value >> 1) - offset
    } else {
        return (value >> 1) + offset
    }
}

@inline(__always)
private func filter4Value(_ left: Int32, _ upper: Int32) -> Int32 {
    let value = left + upper + 1
    if value < 0 {
        return -((-value) / 2)
    } else {
        return value / 2
    }
}

@inline(__always)
private func mod257(_ v: Int32) -> UInt8 {
    // matches Python: (v % 257) + 257 if v < 0 else v % 257
    // Python % is always non-negative for positive modulus.
    // Swift/C % can be negative, so we adjust.
    let m = v % 257
    return UInt8(bitPattern: Int8(truncatingIfNeeded: m < 0 ? m + 257 : m))
}

// MARK: - lzfse decompression via Compression framework

private func lzfseDecompress(_ compressed: Data, expectedSize: Int) -> Data? {
    var output = Data(count: expectedSize)
    let result = output.withUnsafeMutableBytes { outPtr -> Int in
        compressed.withUnsafeBytes { inPtr -> Int in
            compression_decode_buffer(
                outPtr.bindMemory(to: UInt8.self).baseAddress!,
                expectedSize,
                inPtr.bindMemory(to: UInt8.self).baseAddress!,
                compressed.count,
                nil,
                COMPRESSION_LZFSE
            )
        }
    }
    return result == expectedSize ? output : nil
}

// MARK: - TTF / sbix parser

/// A single decoded emoji glyph from sbix.
struct SbixGlyph {
    let name: String    // glyph name (or index as string if unavailable)
    let ppem: UInt16
    let graphicType: String  // "emjc", "png ", etc.
    let data: Data
}

/// Returns the byte offset of each sub-font in a TTF or TTC blob.
private func ttcFontOffsets(data: Data) -> [Int] {
    guard data.count >= 4 else { return [] }
    // TTC magic: 'ttcf'
    if data[0] == 0x74, data[1] == 0x74, data[2] == 0x63, data[3] == 0x66 {
        guard data.count >= 12 else { return [] }
        let numFonts = Int(data.readBE32(at: 8))
        guard data.count >= 12 + numFonts * 4 else { return [] }
        return (0 ..< numFonts).map { i in Int(data.readBE32(at: 12 + i * 4)) }
    }
    return [0]  // plain TTF starts at offset 0
}

/// Returns true if any sub-font in the given TTF/TTC data contains an sbix table.
func hasSbixTable(fontData: Data) -> Bool {
    ttcFontOffsets(data: fontData).contains { base in
        TTFParser(data: fontData, base: base)?.tableDirectory["sbix"] != nil
    }
}

// MARK: - Curated glyph selection (matches macOS Font Book preview)

/// Row 1: faces/animals. Row 2: objects/food/symbols.
/// Single-codepoint lookups resolved via cmap.
private let curatedSimpleCodepoints: [UInt32] = [
    // Row 1
    0x1F603, // 😃
    0x1F607, // 😇
    0x1F60D, // 😍
    0x1F61C, // 😜
    0x1F638, // 😸
    0x1F648, // 🙈
    0x1F43A, // 🐺
    0x1F430, // 🐰
    0x1F47D, // 👽
    0x1F409, // 🐉
    // Row 2
    0x1F4B0, // 💰
    0x1F3E1, // 🏡
    0x1F385, // 🎅
    0x1F36A, // 🍪
    0x1F355, // 🍕
    0x1F680, // 🚀
    0x1F6BB, // 🚻
    0x1F4A9, // 💩
    0x1F4F7, // 📷
    0x1F4E6, // 📦
]

/// 2 rows of common emoji + 1 row of keycap digits 1–9, 0.
/// Uses CoreText for shaping so morx/GSUB ligatures (keycaps) are resolved correctly.
func selectCuratedSbixGlyphs(fontData: Data, preferredPPEM: UInt16 = 160) -> [SbixGlyph] {
    // Load font via CoreText — handles TTF and TTC, and uses Apple's own morx/GSUB shaping
    guard let descs = CTFontManagerCreateFontDescriptorsFromData(fontData as CFData) as? [CTFontDescriptor],
          let desc = descs.first else { return [] }
    let ctFont = CTFontCreateWithFontDescriptor(desc, 160, nil)

    let logger = _keycapLogger

    // Rows 1 & 2: single-codepoint emoji
    let simpleIndices: [Int] = curatedSimpleCodepoints.map { cp in
        guard let scalar = Unicode.Scalar(cp) else { return -1 }
        let g = ctGlyphID(for: String(scalar), using: ctFont) ?? -1
        if g < 0 { logger.warning("simple U+\(String(format:"%04X",cp)): not found") }
        return g
    }

    // Row 3: keycap sequences 1–9, 0 — resolved via CoreText (handles morx ligatures)
    let keycapStrings = ["1️⃣","2️⃣","3️⃣","4️⃣","5️⃣","6️⃣","7️⃣","8️⃣","9️⃣","0️⃣"]
    let keycapIndices: [Int] = keycapStrings.map { seq in
        let g = ctGlyphID(for: seq, using: ctFont) ?? -1
        logger.info("keycap '\(seq)': glyphID=\(g)")
        return g
    }

    let offsets = ttcFontOffsets(data: fontData)
    guard let parser = offsets.compactMap({ TTFParser(data: fontData, base: $0) }).first else { return [] }
    return parser.extractSbixGlyphsForIndices(simpleIndices + keycapIndices,
                                              preferredPPEM: preferredPPEM)
        .compactMap { $0 }
}

/// Resolves a string (single emoji or multi-codepoint sequence) to the first glyph ID
/// in the given CTFont using CoreText shaping.
private func ctGlyphID(for string: String, using ctFont: CTFont) -> Int? {
    let attr = NSAttributedString(string: string,
                                  attributes: [kCTFontAttributeName as NSAttributedString.Key: ctFont])
    let line = CTLineCreateWithAttributedString(attr)
    guard let runs = CTLineGetGlyphRuns(line) as? [CTRun], let run = runs.first else { return nil }
    let count = CTRunGetGlyphCount(run)
    guard count > 0 else { return nil }
    var glyphs = [CGGlyph](repeating: 0, count: count)
    CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
    return glyphs[0] != 0 ? Int(glyphs[0]) : nil
}

// MARK: - TTFParser

private struct TTFParser {
    let data: Data

    // sfnt offsets
    let numTables: Int
    let tableDirectory: [String: (offset: UInt32, length: UInt32)]

    /// `base` is the byte offset of the sfnt header within `data`.
    /// For a plain TTF pass 0; for a TTC sub-font pass the offset from `ttcFontOffsets`.
    init?(data: Data, base: Int = 0) {
        self.data = data
        guard base + 12 <= data.count else { return nil }

        let n = Int(data.readBE16(at: base + 4))
        numTables = n
        var dir: [String: (UInt32, UInt32)] = [:]
        dir.reserveCapacity(n)
        let dirStart = base + 12
        for i in 0 ..< n {
            let off = dirStart + i * 16
            guard off + 16 <= data.count else { break }
            let tag = String(bytes: data[off ..< off+4], encoding: .ascii) ?? ""
            let tableOffset = data.readBE32(at: off + 8)
            let tableLength = data.readBE32(at: off + 12)
            dir[tag] = (tableOffset, tableLength)
        }
        tableDirectory = dir
    }

    // MARK: - maxp: number of glyphs

    private func numberOfGlyphs() -> Int {
        guard let (off, _) = tableDirectory["maxp"] else { return 0 }
        let base = Int(off)
        guard base + 6 <= data.count else { return 0 }
        return Int(data.readBE16(at: base + 4))
    }

    // MARK: - post: glyph names (format 2.0)

    private func extractGlyphNames() -> [String] {
        guard let (off, len) = tableDirectory["post"] else { return [] }
        let base = Int(off)
        guard base + 4 <= data.count else { return [] }
        let format = data.readBE32(at: base)
        guard format == 0x00020000 else { return [] }  // format 2.0 only
        guard base + 34 <= data.count else { return [] }
        let numGlyphs = Int(data.readBE16(at: base + 32))
        let indexArrayStart = base + 34
        guard indexArrayStart + numGlyphs * 2 <= data.count else { return [] }

        var indices = [Int]()
        indices.reserveCapacity(numGlyphs)
        for i in 0 ..< numGlyphs {
            indices.append(Int(data.readBE16(at: indexArrayStart + i * 2)))
        }

        var stringTable = [String]()
        var cursor = indexArrayStart + numGlyphs * 2
        let end = base + Int(len)
        while cursor < end && cursor < data.count {
            let strLen = Int(data[cursor])
            cursor += 1
            guard cursor + strLen <= data.count else { break }
            let str = String(bytes: data[cursor ..< cursor + strLen], encoding: .ascii) ?? ""
            stringTable.append(str)
            cursor += strLen
        }

        let macNames: [String] = [
            ".notdef",".null","nonmarkingreturn","space","exclam","quotedbl","numbersign",
            "dollar","percent","ampersand","quotesingle","parenleft","parenright","asterisk",
            "plus","comma","hyphen","period","slash","zero","one","two","three","four","five",
            "six","seven","eight","nine","colon","semicolon","less","equal","greater","question",
            "at","A","B","C","D","E","F","G","H","I","J","K","L","M","N","O","P","Q","R","S","T",
            "U","V","W","X","Y","Z","bracketleft","backslash","bracketright","asciicircum",
            "underscore","grave","a","b","c","d","e","f","g","h","i","j","k","l","m","n","o","p",
            "q","r","s","t","u","v","w","x","y","z","braceleft","bar","braceright","asciitilde",
            "Adieresis","Aring","Ccedilla","Eacute","Ntilde","Odieresis","Udieresis","aacute",
            "agrave","acircumflex","adieresis","atilde","aring","ccedilla","eacute","egrave",
            "ecircumflex","edieresis","iacute","igrave","icircumflex","idieresis","ntilde",
            "oacute","ograve","ocircumflex","odieresis","otilde","uacute","ugrave","ucircumflex",
            "udieresis","dagger","degree","cent","sterling","section","bullet","paragraph",
            "germandbls","registered","copyright","trademark","acute","dieresis","notequal",
            "AE","Oslash","infinity","plusminus","lessequal","greaterequal","yen","mu",
            "partialdiff","summation","product","pi","integral","ordfeminine","ordmasculine",
            "Omega","ae","oslash","questiondown","exclamdown","logicalnot","radical","florin",
            "approxequal","Delta","guillemotleft","guillemotright","ellipsis","nonbreakingspace",
            "Agrave","Atilde","Otilde","OE","oe","endash","emdash","quotedblleft","quotedblright",
            "quoteleft","quoteright","divide","lozenge","ydieresis","Ydieresis","fraction",
            "currency","guilsinglleft","guilsinglright","fi","fl","daggerdbl","periodcentered",
            "quotesinglbase","quotedblbase","perthousand","Acircumflex","Ecircumflex","Aacute",
            "Edieresis","Egrave","Iacute","Icircumflex","Idieresis","Igrave","Oacute",
            "Ocircumflex","apple","Ograve","Uacute","Ucircumflex","Ugrave","dotlessi",
            "circumflex","tilde","macron","breve","dotaccent","ring","cedilla","hungarumlaut",
            "ogonek","caron","Lslash","lslash","Scaron","scaron","Zcaron","zcaron","brokenbar",
            "Eth","eth","Yacute","yacute","Thorn","thorn","minus","multiply","onesuperior",
            "twosuperior","threesuperior","onehalf","onequarter","threequarters","franc","Gbreve",
            "gbreve","Idotaccent","Scedilla","scedilla","Cacute","cacute","Ccaron","ccaron",
            "dcroat"
        ]

        return indices.map { idx in
            if idx < macNames.count { return macNames[idx] }
            let tableIdx = idx - macNames.count
            return tableIdx < stringTable.count ? stringTable[tableIdx] : "\(idx)"
        }
    }

    // MARK: - Fetch specific glyph indices from sbix (ordered, nils for missing)

    func extractSbixGlyphsForIndices(_ indices: [Int], preferredPPEM: UInt16) -> [SbixGlyph?] {
        let nilResult: [SbixGlyph?] = Array(repeating: nil, count: indices.count)
        guard let (sbixOff, _) = tableDirectory["sbix"] else { return nilResult }
        let sbixBase = Int(sbixOff)
        guard sbixBase + 8 <= data.count else { return nilResult }
        let numStrikes = Int(data.readBE32(at: sbixBase + 4))
        guard numStrikes > 0, sbixBase + 8 + numStrikes * 4 <= data.count else { return nilResult }

        var strikes: [(ppem: UInt16, offset: Int)] = []
        for s in 0 ..< numStrikes {
            let rel = Int(data.readBE32(at: sbixBase + 8 + s * 4))
            let strikeAbs = sbixBase + rel
            guard strikeAbs + 4 <= data.count else { continue }
            strikes.append((data.readBE16(at: strikeAbs), strikeAbs))
        }
        strikes.sort { $0.ppem < $1.ppem }
        guard let chosen = strikes.first(where: { $0.ppem == preferredPPEM })
                        ?? strikes.first(where: { $0.ppem > preferredPPEM })
                        ?? strikes.last else { return nilResult }

        let glyphCount = numberOfGlyphs()
        let strikeBase = chosen.offset
        let offsetTableStart = strikeBase + 4
        guard offsetTableStart + (glyphCount + 1) * 4 <= data.count else { return nilResult }
        let glyphNames = extractGlyphNames()

        var result: [SbixGlyph?] = nilResult
        for (pos, g) in indices.enumerated() {
            guard g >= 0, g < glyphCount else { continue }
            let relOff  = Int(data.readBE32(at: offsetTableStart + g * 4))
            let nextOff = Int(data.readBE32(at: offsetTableStart + (g + 1) * 4))
            guard relOff < nextOff else { continue }
            let glyphAbs = strikeBase + relOff
            let len      = nextOff - relOff
            guard glyphAbs + len <= data.count, len >= 8 else { continue }
            let gt = String(bytes: data[glyphAbs+4 ..< glyphAbs+8], encoding: .ascii) ?? ""
            guard gt == "emjc" || gt == "png " else { continue }
            let imgData = data.subdata(in: (glyphAbs + 8) ..< (glyphAbs + len))
            let name = g < glyphNames.count ? glyphNames[g] : "\(g)"
            result[pos] = SbixGlyph(name: name, ppem: chosen.ppem, graphicType: gt, data: imgData)
        }
        return result
    }
}

// MARK: - Data extensions

extension Data {
    @inline(__always) func readBE16(at offset: Int) -> UInt16 {
        let hi = UInt16(self[offset])
        let lo = UInt16(self[offset+1])
        return (hi << 8) | lo
    }
    @inline(__always) func readBE32(at offset: Int) -> UInt32 {
        let b0 = UInt32(self[offset])
        let b1 = UInt32(self[offset+1])
        let b2 = UInt32(self[offset+2])
        let b3 = UInt32(self[offset+3])
        return (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
    }
    @inline(__always) func readLE16(at offset: Int) -> UInt16 {
        let lo = UInt16(self[offset])
        let hi = UInt16(self[offset+1])
        return (hi << 8) | lo
    }
}

// MARK: - Render emoji grid

/// Renders up to `maxCount` decoded EMJC (or PNG) glyphs into a single NSImage grid.
/// Returns `nil` if no renderable glyphs were found.
func renderEmojiGrid(from glyphs: [SbixGlyph], cellSize: Int = 64, columns: Int = 10, maxCount: Int = 100) -> NSImage? {
    var images: [NSImage] = []

    for glyph in glyphs {
        if images.count >= maxCount { break }
        switch glyph.graphicType {
        case "emjc":
            guard let (bgra, w, h) = decodeEMJC(glyph.data) else { continue }
            guard let cgImg = bgraDataToCGImage(bgra, width: w, height: h) else { continue }
            images.append(NSImage(cgImage: cgImg, size: NSSize(width: w, height: h)))
        case "png ":
            guard let img = NSImage(data: glyph.data) else { continue }
            images.append(img)
        default: continue
        }
    }

    guard !images.isEmpty else { return nil }

    let paddingH = cellSize / 5   // left/right outer margin
    let paddingV = cellSize / 8   // vertical gap between rows

    let cols = min(columns, images.count)
    let rows = (images.count + cols - 1) / cols
    let totalW = cols * cellSize + paddingH * 2
    let totalH = rows * cellSize + (rows - 1) * paddingV + paddingV  // paddingV top+bottom too

    let result = NSImage(size: NSSize(width: totalW, height: totalH))
    result.lockFocus()
    NSColor.white.setFill()
    NSRect(x: 0, y: 0, width: totalW, height: totalH).fill()

    for (idx, img) in images.enumerated() {
        let col = idx % cols
        let row = idx / cols
        // NSImage coordinate origin is bottom-left
        let x = paddingH + col * cellSize
        // rows go top-to-bottom; add half paddingV at bottom edge and full paddingV between rows
        let y = (paddingV / 2) + (rows - 1 - row) * (cellSize + paddingV)
        let destRect = NSRect(x: x, y: y, width: cellSize, height: cellSize)
        img.draw(in: destRect, from: .zero, operation: .sourceOver, fraction: 1.0)
    }

    result.unlockFocus()
    return result
}

private func bgraDataToCGImage(_ bgra: Data, width: Int, height: Int) -> CGImage? {
    let bytesPerRow = width * 4
    guard let provider = CGDataProvider(data: bgra as CFData) else { return nil }
    // BGRA bytes in memory: byteOrder32Little interprets each 32-bit pixel as LE,
    // so kCGImageAlphaFirst (non-premult ARGB) stored LE = B,G,R,A in memory = BGRA ✓
    let bitmapInfo = CGBitmapInfo(rawValue:
        CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.first.rawValue)
    return CGImage(
        width: width,
        height: height,
        bitsPerComponent: 8,
        bitsPerPixel: 32,
        bytesPerRow: bytesPerRow,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: bitmapInfo,
        provider: provider,
        decode: nil,
        shouldInterpolate: true,
        intent: .defaultIntent
    )
}
