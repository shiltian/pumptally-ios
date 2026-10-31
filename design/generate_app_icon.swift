#!/usr/bin/env swift

import AppKit
import Foundation

private struct Palette {
    let backgroundTop: String
    let backgroundBottom: String
    let backdrop: String
    let hose: String
    let body: String
    let inset: String
    let droplet: String
}

private let size = 1024
private let projectRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
private let designDirectory = projectRoot.appendingPathComponent("design", isDirectory: true)
private let assetDirectory = projectRoot
    .appendingPathComponent("PumpTally/Assets.xcassets/AppIcon.appiconset", isDirectory: true)

private func svg(for palette: Palette) -> String {
    """
    <svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
      <defs>
        <linearGradient id="background" x1="0" y1="0" x2="960" y2="1024" gradientUnits="userSpaceOnUse">
          <stop offset="0" stop-color="\(palette.backgroundTop)"/>
          <stop offset="1" stop-color="\(palette.backgroundBottom)"/>
        </linearGradient>
        <linearGradient id="pump" x1="287" y1="220" x2="680" y2="803" gradientUnits="userSpaceOnUse">
          <stop offset="0" stop-color="\(palette.body)"/>
          <stop offset="1" stop-color="\(palette.hose)"/>
        </linearGradient>
      </defs>

      <rect width="1024" height="1024" fill="url(#background)"/>

      <!-- A conventional fuel dispenser makes the purpose readable at a glance. -->
      <circle cx="692" cy="334" r="274" fill="\(palette.backdrop)" opacity="0.16"/>

      <!-- Hose and nozzle sit behind the dispenser body. -->
      <path d="M 655 302
               C 722 300 747 337 742 404
               L 731 518
               C 727 562 754 576 792 585"
            fill="none" stroke="\(palette.hose)" stroke-width="46" stroke-linecap="round" stroke-linejoin="round"/>
      <path d="M 766 558
               L 816 581
               L 857 508
               L 886 524
               L 905 490
               L 822 443
               L 752 559 Z"
            fill="\(palette.body)" stroke="\(palette.backgroundBottom)" stroke-width="10" stroke-linejoin="round"/>

      <!-- Main pump housing and its broad base. -->
      <path d="M 294 276
               C 294 232 329 198 373 198
               L 573 198
               C 617 198 652 232 652 276
               L 652 747
               L 294 747 Z"
            fill="url(#pump)"/>
      <path d="M 264 746
               C 264 724 282 706 304 706
               L 642 706
               C 664 706 682 724 682 746
               L 682 785
               C 682 807 664 825 642 825
               L 304 825
               C 282 825 264 807 264 785 Z"
            fill="url(#pump)"/>

      <!-- The dark display contains a fuel drop and a recorded/check mark. -->
      <rect x="344" y="285" width="258" height="197" rx="34" fill="\(palette.inset)"/>
      <path d="M 407 321
               C 407 321 373 363 373 388
               C 373 412 390 430 413 430
               C 436 430 453 412 453 388
               C 453 363 419 321 419 321 Z"
            fill="\(palette.droplet)"/>
      <path d="M 481 386 L 507 411 L 563 350"
            fill="none" stroke="\(palette.hose)" stroke-width="25" stroke-linecap="round" stroke-linejoin="round"/>

      <!-- Simple record lines reinforce the tracking purpose without tiny text. -->
      <rect x="356" y="538" width="203" height="20" rx="10" fill="\(palette.inset)" opacity="0.50"/>
      <rect x="356" y="587" width="245" height="20" rx="10" fill="\(palette.inset)" opacity="0.36"/>
      <rect x="356" y="636" width="166" height="20" rx="10" fill="\(palette.inset)" opacity="0.25"/>
    </svg>
    """
}

private func writeSVGAndPNG(name: String, palette: Palette, previewName: String) throws {
    let source = svg(for: palette)
    let svgURL = designDirectory.appendingPathComponent(name)
    try source.write(to: svgURL, atomically: true, encoding: .utf8)

    guard let vectorImage = NSImage(contentsOf: svgURL),
          let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: size,
            pixelsHigh: size,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
          ),
          let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw NSError(domain: "AppIconGenerator", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not render \(name)"])
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics
    graphics.imageInterpolation = .high
    vectorImage.draw(
        in: NSRect(x: 0, y: 0, width: size, height: size),
        from: .zero,
        operation: .copy,
        fraction: 1
    )
    graphics.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()

    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "AppIconGenerator", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not encode \(name) as PNG"])
    }

    try png.write(to: designDirectory.appendingPathComponent(previewName), options: .atomic)
    if name == "AppIcon.svg" {
        try png.write(to: designDirectory.appendingPathComponent("AppIcon-1024.png"), options: .atomic)
        try png.write(to: assetDirectory.appendingPathComponent("icon.png"), options: .atomic)
    } else if name == "AppIcon-Dark.svg" {
        try png.write(to: designDirectory.appendingPathComponent("AppIcon-Dark-1024.png"), options: .atomic)
        try png.write(to: assetDirectory.appendingPathComponent("icon-dark.png"), options: .atomic)
    } else {
        try png.write(to: designDirectory.appendingPathComponent("AppIcon-Mono-1024.png"), options: .atomic)
        try png.write(to: assetDirectory.appendingPathComponent("icon-tinted.png"), options: .atomic)
    }
}

private let light = Palette(
    backgroundTop: "#178A78",
    backgroundBottom: "#125669",
    backdrop: "#A6E6C9",
    hose: "#C2EBD7",
    body: "#F8F5E7",
    inset: "#14635F",
    droplet: "#FFC76B"
)

private let dark = Palette(
    backgroundTop: "#103C42",
    backgroundBottom: "#102F42",
    backdrop: "#4A9E8A",
    hose: "#72C6AC",
    body: "#E4F3DE",
    inset: "#15484C",
    droplet: "#F4B95E"
)

private let tinted = Palette(
    backgroundTop: "#000000",
    backgroundBottom: "#000000",
    backdrop: "#000000",
    hose: "#FFFFFF",
    body: "#FFFFFF",
    inset: "#000000",
    droplet: "#FFFFFF"
)

do {
    try writeSVGAndPNG(name: "AppIcon.svg", palette: light, previewName: "AppIcon-Preview.png")
    try writeSVGAndPNG(name: "AppIcon-Dark.svg", palette: dark, previewName: "AppIcon-Dark-Preview.png")
    try writeSVGAndPNG(name: "AppIcon-Mono.svg", palette: tinted, previewName: "AppIcon-Mono-Preview.png")
    print("Generated 1024×1024 app icon variants in \(designDirectory.path)")
} catch {
    fputs("App icon generation failed: \(error)\n", stderr)
    exit(1)
}
