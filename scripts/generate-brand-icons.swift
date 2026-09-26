// Generates the NexIIT Recorder icon set from a single square master PNG.
//
// Usage: swift scripts/generate-brand-icons.swift <master.png>
//
// Produces:
//   public/app-icons/nexiit-*.png, public/app-icons/nexiitmac-*.png
//   icons/icons/png/<N>x<N>.png
//   icons/icons/mac/icon.icns   (via iconutil, using a generated .iconset)
//   icons/icons/win/icon.ico
//
// Resampling is done with progressive halving in Core Graphics so that large
// downscale factors (1254 -> 16) do not alias. The master is cropped to its
// alpha bounding box first, so the emitted icons are optically centred.

import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let repoRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

struct Target {
	let size: Int
	/// Fraction of the canvas the artwork should occupy.
	let fill: Double
	let path: String
}

let macFill = 0.82   // macOS expects the squircle inset from the canvas edge
let bleedFill = 1.0  // Windows / Linux / in-app UI use full bleed

var targets: [Target] = []

func addAppIcons(prefix: String, fill: Double) {
	for size in [16, 32, 64, 128, 256, 512, 1024] {
		targets.append(
			Target(
				size: size, fill: fill,
				path: "public/app-icons/\(prefix)-\(size).png"))
	}
}

// In-app icons: the badge carries its own rounded corners, so full bleed.
// The mac set backs the Dock and tray, so it uses the same inset as the .icns.
addAppIcons(prefix: "nexiit", fill: bleedFill)
addAppIcons(prefix: "nexiitmac", fill: macFill)

// electron-builder source set (Linux AppImage reads the whole folder).
for size in [16, 24, 32, 48, 64, 128, 256, 512, 1024] {
	targets.append(
		Target(
			size: size, fill: bleedFill,
			path: "icons/icons/png/\(size)x\(size).png"))
}

func fail(_ message: String) -> Never {
	FileHandle.standardError.write(Data("error: \(message)\n".utf8))
	exit(1)
}

guard CommandLine.arguments.count == 2 else { fail("usage: generate-brand-icons.swift <master.png>") }
let masterURL = URL(fileURLWithPath: CommandLine.arguments[1])
guard let masterData = try? Data(contentsOf: masterURL),
	let masterRep = NSBitmapImageRep(data: masterData),
	let masterCG = masterRep.cgImage
else { fail("could not decode \(masterURL.path)") }

let masterW = masterCG.width
let masterH = masterCG.height
guard masterW == masterH else { fail("master must be square, got \(masterW)x\(masterH)") }

func makeContext(width: Int, height: Int) -> CGContext {
	guard
		let ctx = CGContext(
			data: nil, width: width, height: height, bitsPerComponent: 8,
			bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
			bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
	else { fail("could not create bitmap context \(width)x\(height)") }
	ctx.interpolationQuality = .high
	return ctx
}

// --- crop to the alpha bounding box -------------------------------------------------
let reader = makeContext(width: masterW, height: masterH)
reader.draw(masterCG, in: CGRect(x: 0, y: 0, width: masterW, height: masterH))

guard let src = reader.data else { fail("could not read master pixels") }
let bytesPerPixel = 4
let stride = reader.bytesPerRow
let srcBytes = src.bindMemory(to: UInt8.self, capacity: masterH * stride)

var minX = masterW, minY = masterH, maxX = -1, maxY = -1
for y in 0..<masterH {
	for x in 0..<masterW {
		// premultipliedLast: alpha is the 4th byte
		let alpha = srcBytes[y * stride + x * bytesPerPixel + 3]
		if alpha > 10 {
			if x < minX { minX = x }
			if x > maxX { maxX = x }
			if y < minY { minY = y }
			if y > maxY { maxY = y }
		}
	}
}
guard maxX >= minX, maxY >= minY else { fail("master appears fully transparent") }

let cropRect = CGRect(
	x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
guard let cropped = masterCG.cropping(to: cropRect) else { fail("crop failed") }

let cropAspect = Double(cropped.width) / Double(cropped.height)
print(
	"master \(masterW)x\(masterH)  artwork \(cropped.width)x\(cropped.height) "
		+ "(aspect \(String(format: "%.3f", cropAspect)))")

// --- high quality resample ----------------------------------------------------------

/// Progressively halves `image` until it is within 2x of `target`, then does a
/// final high-quality draw. Avoids the aliasing a single large downscale causes.
func resize(_ image: CGImage, to target: Int) -> CGImage {
	var current = image
	while current.width > target * 2 || current.height > target * 2 {
		let nextW = max(target, current.width / 2)
		let nextH = max(target, current.height / 2)
		let ctx = makeContext(width: nextW, height: nextH)
		ctx.draw(
			current,
			in: CGRect(x: 0, y: 0, width: nextW, height: nextH))
		guard let next = ctx.makeImage() else { fail("resize failed") }
		current = next
	}

	let finalW = max(current.width, target)
	let finalH = max(current.height, target)
	let ctx = makeContext(width: finalW, height: finalH)
	ctx.draw(current, in: CGRect(x: 0, y: 0, width: finalW, height: finalH))
	guard let out = ctx.makeImage() else { fail("final resize failed") }
	return out
}

/// Renders `image` centred on a transparent square canvas of `canvas` pixels,
/// scaled so the artwork occupies `fill` of the canvas width.
func render(_ image: CGImage, canvas: Int, fill: Double) -> CGImage {
	let ctx = makeContext(width: canvas, height: canvas)
	let drawSide = CGFloat(Double(canvas) * fill)
	let scale = drawSide / CGFloat(max(image.width, image.height))
	let drawW = CGFloat(image.width) * scale
	let drawH = CGFloat(image.height) * scale
	let originX = (CGFloat(canvas) - drawW) / 2
	let originY = (CGFloat(canvas) - drawH) / 2
	ctx.draw(image, in: CGRect(x: originX, y: originY, width: drawW, height: drawH))
	guard let out = ctx.makeImage() else { fail("render failed") }
	return out
}

func writePNG(_ image: CGImage, to relativePath: String) {
	let url = repoRoot.appendingPathComponent(relativePath)
	try? FileManager.default.createDirectory(
		at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
	guard
		let dest = CGImageDestinationCreateWithURL(
			url as CFURL, UTType.png.identifier as CFString, 1, nil)
	else { fail("could not open \(relativePath) for writing") }
	CGImageDestinationAddImage(dest, image, nil)
	guard CGImageDestinationFinalize(dest) else { fail("could not write \(relativePath)") }
}

for target in targets {
	let resized = resize(cropped, to: target.size)
	let canvas = render(resized, canvas: target.size, fill: target.fill)
	writePNG(canvas, to: target.path)
}
print("wrote \(targets.count) PNG files")

// --- macOS .icns via iconutil -------------------------------------------------------

let iconsetDir = repoRoot.appendingPathComponent("build/NexIITRecorder.iconset")
try? FileManager.default.createDirectory(at: iconsetDir, withIntermediateDirectories: true)

// iconutil naming: icon_<w>x<h>.png and icon_<w>x<h>@2x.png
let iconsetSpecs: [(name: String, pixels: Int, fill: Double)] = [
	("icon_16x16", 16, macFill), ("icon_16x16@2x", 32, macFill),
	("icon_32x32", 32, macFill), ("icon_32x32@2x", 64, macFill),
	("icon_128x128", 128, macFill), ("icon_128x128@2x", 256, macFill),
	("icon_256x256", 256, macFill), ("icon_256x256@2x", 512, macFill),
	("icon_512x512", 512, macFill), ("icon_512x512@2x", 1024, macFill),
]

for spec in iconsetSpecs {
	let image = render(resize(cropped, to: spec.pixels), canvas: spec.pixels, fill: spec.fill)
	writePNG(image, to: "build/NexIITRecorder.iconset/\(spec.name).png")
}

let icnsURL = repoRoot.appendingPathComponent("icons/icons/mac/icon.icns")
try? FileManager.default.createDirectory(
	at: icnsURL.deletingLastPathComponent(), withIntermediateDirectories: true)

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = [
	"-c", "icns", iconsetDir.path, "-o", icnsURL.path,
]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fail("iconutil failed") }
print("wrote icons/icons/mac/icon.icns")

// --- Windows .ico -------------------------------------------------------------------

// ICO container with PNG-compressed entries (supported since Windows Vista and
// accepted by electron-builder / NSIS).
let icoSizes = [16, 24, 32, 48, 64, 128, 256]
var entries: [(size: Int, data: Data)] = []
for size in icoSizes {
	let image = render(resize(cropped, to: size), canvas: size, fill: bleedFill)
	let mutable = NSMutableData()
	let dest = CGImageDestinationCreateWithData(
		mutable, UTType.png.identifier as CFString, 1, nil)
	guard let dest else { fail("could not encode \(size)px png") }
	CGImageDestinationAddImage(dest, image, nil)
	guard CGImageDestinationFinalize(dest) else { fail("could not encode \(size)px png") }
	entries.append((size, mutable as Data))
}

let headerSize = 6 + entries.count * 16
var ico = Data()

func appendLE32(_ value: UInt32, to data: inout Data) {
	data.append(UInt8(value & 0xff))
	data.append(UInt8((value >> 8) & 0xff))
	data.append(UInt8((value >> 16) & 0xff))
	data.append(UInt8((value >> 24) & 0xff))
}

// ICONDIR is 6 bytes: reserved(2), type(2), imageCount(2).
ico.append(contentsOf: [0, 0, 1, 0])
ico.append(contentsOf: [UInt8(entries.count), 0])
var offset = headerSize
for entry in entries {
	// 256 is encoded as 0 in the single-byte dimension fields.
	let dim = UInt8(entry.size == 256 ? 0 : entry.size)
	ico.append(dim)  // width
	ico.append(dim)  // height
	ico.append(0)  // palette size
	ico.append(0)  // reserved
	ico.append(contentsOf: [1, 0])  // colour planes
	ico.append(contentsOf: [32, 0])  // bits per pixel
	appendLE32(UInt32(entry.data.count), to: &ico)
	appendLE32(UInt32(offset), to: &ico)
	offset += entry.data.count
}
for entry in entries {
	ico.append(entry.data)
}

let icoURL = repoRoot.appendingPathComponent("icons/icons/win/icon.ico")
try ico.write(to: icoURL)
print("wrote icons/icons/win/icon.ico (\(icoSizes.count) sizes)")
