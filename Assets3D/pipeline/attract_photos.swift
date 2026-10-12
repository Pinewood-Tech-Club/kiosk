// Bundles the attract screen's photos: swift Assets3D/pipeline/attract_photos.swift <photos dir> [Kiosk/Resources/AttractPhotos]
// Each image is downscaled (longest edge 900 px), its EXIF orientation baked in, flattened onto white, and written as a
// JPEG (quality 0.8) with no metadata beyond the color profile. Output names follow the sorted input names.

import Foundation
import ImageIO
import UniformTypeIdentifiers

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    FileHandle.standardError.write("usage: swift attract_photos.swift <photos dir> [output dir]\n".data(using: .utf8)!)
    exit(1)
}
let input = URL(fileURLWithPath: arguments[1], isDirectory: true)
let output = URL(fileURLWithPath: arguments.count > 2 ? arguments[2] : "Kiosk/Resources/AttractPhotos", isDirectory: true)
let longestEdge = 900
let quality = 0.8
let extensions: Set<String> = ["jpg", "jpeg", "png", "heic"]

let files = try FileManager.default.contentsOfDirectory(at: input, includingPropertiesForKeys: nil)
    .filter { extensions.contains($0.pathExtension.lowercased()) }
    .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

var written: Set<String> = []
for (index, file) in files.enumerated() {
    let name = String(format: "photo-%02d.jpg", index + 1)
    guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
          let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
              kCGImageSourceCreateThumbnailFromImageAlways: true,
              kCGImageSourceCreateThumbnailWithTransform: true,
              kCGImageSourceThumbnailMaxPixelSize: longestEdge,
          ] as CFDictionary) else {
        print("skipped \(file.lastPathComponent): unreadable")
        continue
    }
    let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
    guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { continue }
    let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(rect)
    context.draw(image, in: rect)
    guard let flat = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(output.appendingPathComponent(name) as CFURL,
                                                            UTType.jpeg.identifier as CFString, 1, nil) else { continue }
    CGImageDestinationAddImage(destination, flat, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else {
        print("failed \(name)")
        continue
    }
    written.insert(name)
    print("\(name) \(flat.width)x\(flat.height) <- \(file.lastPathComponent)")
}

let stale = try FileManager.default.contentsOfDirectory(atPath: output.path).filter { !written.contains($0) }
if !stale.isEmpty { print("not from this run, remove by hand: \(stale.sorted().joined(separator: ", "))") }
print("\(written.count) photos in \(output.path)")
