// Pixel diff of two PNGs of the same size: max and mean channel delta (0–255), how many pixels differ, the
// box around them, and optionally a diff image (differing pixels in red over a faded copy of A).
// Usage: swift scripts/perf/imgdiff.swift A.png B.png [diff.png|-] [x,y,w,h in pixels]
import AppKit

func pixels(_ path: String) -> (data: [UInt8], width: Int, height: Int) {
    guard let image = NSImage(contentsOfFile: path),
          let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        fatalError("can't read \(path)")
    }
    let w = cg.width, h = cg.height
    var data = [UInt8](repeating: 0, count: w * h * 4)
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
    return (data, w, h)
}

let args = CommandLine.arguments
let a = pixels(args[1]), b = pixels(args[2])
guard a.width == b.width, a.height == b.height else {
    print("size differs: \(a.width)x\(a.height) vs \(b.width)x\(b.height)")
    exit(1)
}
var maxDelta = 0, total = 0, differing = 0
var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
var out = a.data
var region = (x: 0, y: 0, w: a.width, h: a.height)
if args.count > 4 {
    let v = args[4].split(separator: ",").compactMap { Int($0) }
    region = (v[0], v[1], v[2], v[3])
}
for y in region.y..<min(region.y + region.h, a.height) {
    for x in region.x..<min(region.x + region.w, a.width) {
        let i = (y * a.width + x) * 4
        var d = 0
        for c in 0..<3 { d = max(d, abs(Int(a.data[i + c]) - Int(b.data[i + c]))) }
        total += d
        maxDelta = max(maxDelta, d)
        if d > 0 {
            differing += 1
            minX = min(minX, x); minY = min(minY, y); maxX = max(maxX, x); maxY = max(maxY, y)
            out[i] = 255; out[i + 1] = 0; out[i + 2] = 0; out[i + 3] = 255
        } else {
            for c in 0..<3 { out[i + c] = UInt8(Int(out[i + c]) / 3) }
        }
    }
}
let n = region.w * region.h
let box = differing > 0 ? "box px [\(minX),\(minY) \(maxX - minX + 1)x\(maxY - minY + 1)]" : "identical"
print("max=\(maxDelta) mean=\(String(format: "%.4f", Double(total) / Double(n))) differing=\(differing)/\(n) \(box)")
if args.count > 3, args[3] != "-" {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: &out, width: a.width, height: a.height, bitsPerComponent: 8, bytesPerRow: a.width * 4,
                        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[3]))
}
