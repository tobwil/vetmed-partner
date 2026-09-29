import AppKit
import Foundation
let size = 1024
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
NSColor(calibratedRed: 0.07, green: 0.31, blue: 0.28, alpha: 1).setFill()
NSBezierPath(rect: NSRect(x: 0, y: 0, width: size, height: size)).fill()
NSColor(calibratedRed: 0.92, green: 0.97, blue: 0.90, alpha: 1).setFill()
let pad = NSBezierPath()
pad.move(to: NSPoint(x: 280, y: 280))
pad.curve(to: NSPoint(x: 512, y: 590), controlPoint1: NSPoint(x: 200, y: 370), controlPoint2: NSPoint(x: 425, y: 590))
pad.curve(to: NSPoint(x: 744, y: 280), controlPoint1: NSPoint(x: 599, y: 590), controlPoint2: NSPoint(x: 824, y: 370))
pad.curve(to: NSPoint(x: 512, y: 260), controlPoint1: NSPoint(x: 690, y: 220), controlPoint2: NSPoint(x: 595, y: 265))
pad.curve(to: NSPoint(x: 280, y: 280), controlPoint1: NSPoint(x: 429, y: 265), controlPoint2: NSPoint(x: 334, y: 220))
pad.fill()
for rect in [NSRect(x: 210,y: 500,width: 130,height: 170), NSRect(x: 350,y: 650,width: 140,height: 185), NSRect(x: 535,y: 650,width: 140,height: 185), NSRect(x: 690,y: 500,width: 130,height: 170)] { NSBezierPath(ovalIn: rect).fill() }
NSColor(calibratedRed: 0.07, green: 0.31, blue: 0.28, alpha: 1).setFill()
NSBezierPath(roundedRect: NSRect(x: 479,y: 317,width: 66,height: 198), xRadius: 12, yRadius: 12).fill()
NSBezierPath(roundedRect: NSRect(x: 413,y: 383,width: 198,height: 66), xRadius: 12, yRadius: 12).fill()
NSGraphicsContext.restoreGraphicsState()
let destination = URL(fileURLWithPath: CommandLine.arguments[1])
try bitmap.representation(using: .png, properties: [:])!.write(to: destination)
