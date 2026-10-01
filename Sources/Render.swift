import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

enum RenderError: Error, CustomStringConvertible {
    case badPDF, drawFailed, encodeFailed
    var description: String {
        switch self {
        case .badPDF: return "the embedded PDF could not be read"
        case .drawFailed: return "drawing failed"
        case .encodeFailed: return "creating the PNG failed"
        }
    }
}

enum PDFRender {
    /// Size of page 1 in points, as displayed (rotation applied).
    static func pageSize(_ pdf: [UInt8]) -> CGSize? {
        guard let page = firstPage(pdf) else { return nil }
        return displaySize(page)
    }

    /// Renders page 1 to a PNG with a transparent background, `widthPx` pixels wide.
    static func png(_ pdf: [UInt8], widthPx: Int) throws -> (data: [UInt8], width: Int, height: Int) {
        guard let page = firstPage(pdf) else { throw RenderError.badPDF }
        let size = displaySize(page)
        guard size.width > 0, size.height > 0 else { throw RenderError.badPDF }
        let scale = CGFloat(widthPx) / size.width
        let wd = (size.width * scale).rounded(), hd = (size.height * scale).rounded()
        // Extreme aspect ratios or sizes in the PDF: refuse instead of trapping or allocating gigabytes.
        guard wd.isFinite, hd.isFinite, wd <= 20_000, hd <= 20_000 else { throw RenderError.badPDF }
        let w = max(1, Int(wd))
        let h = max(1, Int(hd))

        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw RenderError.drawFailed }
        ctx.clear(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.interpolationQuality = .high
        ctx.setShouldAntialias(true)
        ctx.setShouldSmoothFonts(true)
        ctx.scaleBy(x: CGFloat(w) / size.width, y: CGFloat(h) / size.height)
        // At scale 1 this transform only handles the crop box origin and page rotation.
        let t = page.getDrawingTransform(.cropBox, rect: CGRect(origin: .zero, size: size), rotate: 0, preserveAspectRatio: true)
        ctx.concatenate(t)
        ctx.clip(to: page.getBoxRect(.cropBox))
        ctx.drawPDFPage(page)
        guard let image = ctx.makeImage() else { throw RenderError.drawFailed }

        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out as CFMutableData, UTType.png.identifier as CFString, 1, nil)
        else { throw RenderError.encodeFailed }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw RenderError.encodeFailed }
        return ([UInt8](out as Data), w, h)
    }

    private static func firstPage(_ pdf: [UInt8]) -> CGPDFPage? {
        guard let provider = CGDataProvider(data: Data(pdf) as CFData),
              let doc = CGPDFDocument(provider), doc.numberOfPages >= 1 else { return nil }
        return doc.page(at: 1)
    }

    private static func displaySize(_ page: CGPDFPage) -> CGSize {
        let r = page.getBoxRect(.cropBox)
        let rot = ((page.rotationAngle % 360) + 360) % 360
        return (rot == 90 || rot == 270) ? CGSize(width: r.height, height: r.width) : r.size
    }
}
