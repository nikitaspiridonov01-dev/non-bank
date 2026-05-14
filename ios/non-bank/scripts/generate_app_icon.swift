#!/usr/bin/env swift
//
// Generates the 1024×1024 App Store icon for non-bank.
//
// The icon shares the splash's background + gem so the brand reads
// consistently from icon-tap → splash → app, but **deliberately drops
// the star field** that `SplashView` paints. The home-screen tile is
// small enough that the stars read as noise rather than atmosphere;
// the gem alone, sized to dominate the canvas, is a stronger
// recognition target. The splash keeps the stars because it has more
// pixels to breathe with.
//
//   - Warm near-black background (`#1B1410`) — same value as the
//     `LaunchBackground` colour asset and the splash, so the
//     icon-tap → splash → app transition reads as one piece.
//   - Accent-orange 8-bit gem in the centre with a peach highlight,
//     identical pixel coordinates to the SplashView crystal — scaled
//     up aggressively so the visible body fills ~70 % of the icon
//     width.
//
// Usage:
//     swift scripts/generate_app_icon.swift
//
// Writes to non-bank/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png
// — Xcode picks it up next build, no `.pbxproj` changes needed.

import Foundation
import AppKit
import CoreGraphics

// MARK: - Configuration

let iconSize: CGFloat = 1024
let outputPath = "non-bank/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png"

// Palette matches `AppColors` / `AccentColor` asset.
//
// Background is a warm near-black (`#1B1410`) — same value as the
// `LaunchBackground` colour asset and the splash screen, so the
// icon tap → splash → app transition reads as one piece.
let backgroundRGB: (CGFloat, CGFloat, CGFloat) = (0x1B / 255.0, 0x14 / 255.0, 0x10 / 255.0)
let accentRGB:     (CGFloat, CGFloat, CGFloat) = (0xF1 / 255.0, 0x8A / 255.0, 0x4D / 255.0)

// MARK: - Context setup

let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
guard let ctx = CGContext(
    data: nil,
    width: Int(iconSize),
    height: Int(iconSize),
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: colorSpace,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
    fputs("Failed to create CGContext\n", stderr)
    exit(1)
}

// CG draws bottom-up by default — flip so y grows downward to match
// SwiftUI / splash coordinate conventions.
ctx.translateBy(x: 0, y: iconSize)
ctx.scaleBy(x: 1, y: -1)

// MARK: - Background

ctx.setFillColor(CGColor(red: backgroundRGB.0, green: backgroundRGB.1, blue: backgroundRGB.2, alpha: 1))
ctx.fill(CGRect(x: 0, y: 0, width: iconSize, height: iconSize))

// MARK: - Crystal (same pixel coords as SplashView, scaled up)
//
// SplashView draws on a 200×200 logical canvas; on the splash that's
// scaled to 1.4×. For the icon we want the gem to *dominate* the tile
// — the home-screen tile is too small for atmospheric detail, so the
// gem alone has to carry the brand. We map the 200×200 source onto an
// 1800×1800 region centered in the 1024×1024 icon. Most of the 200-grid
// is empty padding around the crystal body (cols/rows 60..140), so the
// painted gem ends up ≈720 pixels wide — roughly 70 % of the icon
// width. The body's outermost pixels sit at ~152 px from each canvas
// edge, which keeps the gem comfortably clear of iOS's rounded-corner
// mask (≈229 px radius at 1024 px) on every device.

let crystalScale: CGFloat = 1800 / 200
let crystalOriginX = (iconSize - 200 * crystalScale) / 2
let crystalOriginY = (iconSize - 200 * crystalScale) / 2

struct PixelRect {
    let x: CGFloat
    let y: CGFloat
    let w: CGFloat
    let h: CGFloat
    let useHighlight: Bool
}

let crystalPixels: [PixelRect] = [
    // Body
    PixelRect(x: 80, y: 60,  w: 40, h: 10, useHighlight: false),
    PixelRect(x: 70, y: 70,  w: 60, h: 10, useHighlight: false),
    PixelRect(x: 60, y: 80,  w: 80, h: 10, useHighlight: false),
    PixelRect(x: 60, y: 90,  w: 80, h: 10, useHighlight: false),
    PixelRect(x: 60, y: 100, w: 80, h: 10, useHighlight: false),
    PixelRect(x: 70, y: 110, w: 60, h: 10, useHighlight: false),
    PixelRect(x: 80, y: 120, w: 40, h: 10, useHighlight: false),
    PixelRect(x: 90, y: 130, w: 20, h: 10, useHighlight: false),
    // Highlights — drawn after body so they paint on top.
    PixelRect(x: 80, y: 70, w: 10, h: 10, useHighlight: true),
    PixelRect(x: 70, y: 80, w: 10, h: 10, useHighlight: true)
]

for pixel in crystalPixels {
    let color: CGColor
    if pixel.useHighlight {
        // Solid light peach (#FFB590) — same hue family as the accent
        // body, just lighter. The previous version blended white at
        // 55 % opacity which read clearly against the cream background
        // but turns muddy grey on the new warm-dark backdrop. A solid
        // peach keeps the highlight punchy regardless of background.
        color = CGColor(red: 1.0, green: 0xB5 / 255.0, blue: 0x90 / 255.0, alpha: 1)
    } else {
        color = CGColor(red: accentRGB.0, green: accentRGB.1, blue: accentRGB.2, alpha: 1)
    }
    let rect = CGRect(
        x: crystalOriginX + pixel.x * crystalScale,
        y: crystalOriginY + pixel.y * crystalScale,
        width: pixel.w * crystalScale,
        height: pixel.h * crystalScale
    )
    ctx.setFillColor(color)
    ctx.fill(rect)
}

// MARK: - Encode PNG

guard let cgImage = ctx.makeImage() else {
    fputs("Failed to snapshot CGImage from context\n", stderr)
    exit(1)
}
let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: iconSize, height: iconSize))

// Round-trip through NSBitmapImageRep to get a clean PNG with sRGB
// metadata that App Store expects.
guard let tiff = nsImage.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff) else {
    fputs("Failed to build bitmap rep\n", stderr)
    exit(1)
}
guard let pngData = rep.representation(using: .png, properties: [:]) else {
    fputs("Failed to encode PNG\n", stderr)
    exit(1)
}

let outputURL = URL(fileURLWithPath: outputPath)
do {
    try pngData.write(to: outputURL, options: .atomic)
    print("Wrote \(outputPath) (\(pngData.count) bytes)")
} catch {
    fputs("Write failed: \(error)\n", stderr)
    exit(1)
}
