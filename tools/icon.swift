import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024
let space = CGColorSpaceCreateDeviceRGB()
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
// Background: deep navy at the bottom to bright blue at the top.
let colors = [CGColor(red: 0.04, green: 0.10, blue: 0.28, alpha: 1), CGColor(red: 0.16, green: 0.45, blue: 0.96, alpha: 1)] as CFArray
let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: size), options: [])
// A waveform: seven rounded white bars.
let heights: [CGFloat] = [0.18, 0.34, 0.56, 0.74, 0.50, 0.30, 0.16]
let barWidth: CGFloat = 70, gap: CGFloat = 46
let total = CGFloat(heights.count) * barWidth + CGFloat(heights.count - 1) * gap
var x = (CGFloat(size) - total) / 2
ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
for h in heights {
    let barHeight = h * CGFloat(size)
    let rect = CGRect(x: x, y: (CGFloat(size) - barHeight) / 2, width: barWidth, height: barHeight)
    ctx.addPath(CGPath(roundedRect: rect, cornerWidth: barWidth / 2, cornerHeight: barWidth / 2, transform: nil))
    ctx.fillPath()
    x += barWidth + gap
}
let out = URL(fileURLWithPath: CommandLine.arguments[1])
let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
precondition(CGImageDestinationFinalize(dest))
