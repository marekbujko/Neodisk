//
//  CushionTreemapRenderer.swift
//  TreemapKit
//
//  Rasterizes treemap cells into a CGImage with per-pixel cushion shading.
//

import CoreGraphics
import Foundation

public enum CushionTreemapRenderer {
    /// Directional light, image coordinates (y down), pointing from the
    /// surface toward the light: above and to the top-left of the map.
    private nonisolated static let light = normalized(SIMD3<Double>(-0.3, -0.3, 0.906))
    private nonisolated static let ambient = 0.30
    private nonisolated static let diffuse = 0.70

    /// Renders `cells` at `scale` (2 for Retina). Cell rects are in view
    /// points; the output image covers `bounds` (typically the visible
    /// window plus overscan margin).
    public nonisolated static func render(cells: [TreemapCell], bounds: CGRect, scale: CGFloat) -> CGImage? {
        let width = Int((bounds.width * scale).rounded())
        let height = Int((bounds.height * scale).rounded())
        guard width > 0, height > 0 else { return nil }

        let bytesPerRow = width * 4
        // Render directly into a CFData that the CGImage's data provider
        // retains without copying — a plain [UInt8] would cost a full-buffer
        // copy (~25 MB at 2× on a large window) on every render.
        let byteCount = bytesPerRow * height
        guard let pixelData = CFDataCreateMutable(kCFAllocatorDefault, byteCount) else { return nil }
        CFDataSetLength(pixelData, byteCount)
        guard let rawBase = CFDataGetMutableBytePtr(pixelData) else { return nil }

        // Prefill with a dark background so sub-pixel cells that get skipped
        // read as seams rather than holes.
        var background: [UInt8] = [18, 18, 22, 255]
        memset_pattern4(rawBase, &background, byteCount)

        // Cells never overlap, so concurrent chunks write disjoint pixels.
        nonisolated(unsafe) let base = rawBase
        let chunkCount = max(1, min(cells.count, ProcessInfo.processInfo.activeProcessorCount))
        let chunkSize = (cells.count + chunkCount - 1) / max(1, chunkCount)

        DispatchQueue.concurrentPerform(iterations: chunkCount) { chunkIndex in
            // With ceil-divided chunks, trailing chunks can start past the
            // end (e.g. 10 cells / 8 cores → chunkSize 2 → chunk 7 starts
            // at 14); start..<end would trap with end < start.
            let start = min(chunkIndex * chunkSize, cells.count)
            let end = min(start + chunkSize, cells.count)
            for index in start..<end {
                rasterize(
                    cell: cells[index],
                    origin: bounds.origin,
                    scale: Double(scale),
                    into: base,
                    width: width,
                    height: height,
                    bytesPerRow: bytesPerRow
                )
            }
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let provider = CGDataProvider(data: pixelData) else { return nil }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    private nonisolated static func rasterize(
        cell: TreemapCell,
        origin: CGPoint,
        scale: Double,
        into base: UnsafeMutablePointer<UInt8>,
        width: Int,
        height: Int,
        bytesPerRow: Int
    ) {
        // Pixel bounds relative to the render origin; consistent rounding on
        // shared edges leaves no gaps.
        let originX = Double(origin.x)
        let originY = Double(origin.y)
        let x0 = max(0, Int(((Double(cell.rect.minX) - originX) * scale).rounded()))
        let x1 = min(width, Int(((Double(cell.rect.maxX) - originX) * scale).rounded()))
        let y0 = max(0, Int(((Double(cell.rect.minY) - originY) * scale).rounded()))
        let y1 = min(height, Int(((Double(cell.rect.maxY) - originY) * scale).rounded()))
        guard x1 > x0, y1 > y0 else { return }

        let surface = cell.surface
        let r = Double(cell.rgb.x)
        let g = Double(cell.rgb.y)
        let b = Double(cell.rgb.z)

        // SIMD lane constants, hoisted out of the pixel loops. Every vector
        // expression below mirrors the scalar tail's operation tree exactly
        // (same operations, same order), so the two paths agree bit-for-bit.
        let laneCount = 8
        let laneIndices = SIMD8<Double>(0, 1, 2, 3, 4, 5, 6, 7)
        let originXV = SIMD8<Double>(repeating: originX)
        let scaleV = SIMD8<Double>(repeating: scale)
        let xaV = SIMD8<Double>(repeating: surface.xa)
        let xbV = SIMD8<Double>(repeating: surface.xb)
        let lightXV = SIMD8<Double>(repeating: light.x)
        let lightZV = SIMD8<Double>(repeating: light.z)
        let ambientV = SIMD8<Double>(repeating: ambient)
        let diffuseV = SIMD8<Double>(repeating: diffuse)
        let rV = SIMD8<Double>(repeating: r)
        let gV = SIMD8<Double>(repeating: g)
        let bV = SIMD8<Double>(repeating: b)
        let halfV = SIMD8<Double>(repeating: 0.5)
        let oneV = SIMD8<Double>(repeating: 1)
        let scale255V = SIMD8<Double>(repeating: 255)
        let zeroV = SIMD8<Double>()
        let alphaV = SIMD8<UInt32>(repeating: 255 &<< 24)

        for py in y0..<y1 {
            // Sample the surface at the pixel center, in view coordinates.
            let yCenter = originY + (Double(py) + 0.5) / scale
            let gy = surface.ya + surface.yb * yCenter
            // Per-row constants: gy·gy and gy·light.y are reused unchanged by
            // every lane, matching the scalar `gy * gy` / `gy * light.y`.
            let gySquaredV = SIMD8<Double>(repeating: gy * gy)
            let gyLightYV = SIMD8<Double>(repeating: gy * light.y)
            var offset = py * bytesPerRow + x0 * 4
            var px = x0

            // Vector body: 8 pixels per iteration.
            while px + laneCount <= x1 {
                let pxV = SIMD8<Double>(repeating: Double(px)) + laneIndices
                let xCenter = originXV + (pxV + halfV) / scaleV
                let gx = xaV + xbV * xCenter

                // Surface normal is (-gx, -gy, 1) (unnormalized).
                let normalLength = (gx * gx + gySquaredV + oneV).squareRoot()
                let dot = (-gx * lightXV - gyLightYV + lightZV) / normalLength
                let shade = ambientV + diffuseV * pointwiseMax(zeroV, dot)

                // Clamp to [0, 255] and truncate toward zero, exactly like the
                // scalar `UInt8(min(255, max(0, …)))`.
                let red = truncateToU32(pointwiseMin(scale255V, pointwiseMax(zeroV, rV * shade * scale255V)))
                let green = truncateToU32(pointwiseMin(scale255V, pointwiseMax(zeroV, gV * shade * scale255V)))
                let blue = truncateToU32(pointwiseMin(scale255V, pointwiseMax(zeroV, bV * shade * scale255V)))
                // Pack RGBA little-endian into one 32-bit word per pixel and
                // store all 8 pixels with a single unaligned vector store.
                let pixels = red | (green &<< 8) | (blue &<< 16) | alphaV
                UnsafeMutableRawPointer(base + offset)
                    .storeBytes(of: pixels, toByteOffset: 0, as: SIMD8<UInt32>.self)
                offset += laneCount * 4
                px += laneCount
            }

            // Scalar tail for the last (x1 - px) < 8 pixels.
            while px < x1 {
                let xCenter = originX + (Double(px) + 0.5) / scale
                let gx = surface.xa + surface.xb * xCenter

                // Surface normal is (-gx, -gy, 1) (unnormalized).
                let normalLength = (gx * gx + gy * gy + 1).squareRoot()
                let dot = (-gx * light.x - gy * light.y + light.z) / normalLength
                let shade = ambient + diffuse * max(0, dot)

                base[offset] = UInt8(min(255, max(0, r * shade * 255)))
                base[offset + 1] = UInt8(min(255, max(0, g * shade * 255)))
                base[offset + 2] = UInt8(min(255, max(0, b * shade * 255)))
                base[offset + 3] = 255
                offset += 4
                px += 1
            }
        }
    }

    /// Truncates non-negative doubles in [0, 2^31) toward zero, per lane —
    /// identical to `UInt32(d)` but branch-free so it compiles to vector
    /// instructions. `UInt32.init(_: Double)` carries trap checks per lane and
    /// `SIMD8<UInt32>.init(_:rounding:)` goes through an unspecialized generic
    /// path; both measured an order of magnitude slower.
    ///
    /// Adding 2^52 pushes the integer part into the low mantissa bits
    /// (round-to-nearest-even); subtracting it back yields round(d), then one
    /// is subtracted from lanes that rounded up to recover floor(d). Re-adding
    /// 2^52 to the now-integral value leaves the integer in the low 32 bits of
    /// the bit pattern.
    private nonisolated static func truncateToU32(_ d: SIMD8<Double>) -> SIMD8<UInt32> {
        let magic = SIMD8<Double>(repeating: 0x1.0p52)
        let rounded = (d + magic) - magic
        let floored = rounded.replacing(with: rounded - 1, where: rounded .> d)
        let bits = unsafeBitCast(floored + magic, to: SIMD8<UInt64>.self)
        return SIMD8<UInt32>(truncatingIfNeeded: bits)
    }

    private nonisolated static func normalized(_ v: SIMD3<Double>) -> SIMD3<Double> {
        let length = (v.x * v.x + v.y * v.y + v.z * v.z).squareRoot()
        return SIMD3(v.x / length, v.y / length, v.z / length)
    }
}
