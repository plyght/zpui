// Native reference for the font comparison (tools/font-compare, workflow font-compare.yml).
//
// Renders every case in cases.json with AppKit (NSTextField + NSFont.systemFont(ofSize:weight:))
// on its background colour, the way native macOS chrome draws the system font, and writes:
//   <out>/native-s{1,2}.png   offscreen NSView.cacheDisplay at 1x and 2x
//   <out>/native-window.png   a real on-screen window captured with CGWindowListCreateImage
//   <out>/native.json         per case: CTLine/TextKit glyph x positions, line widths, font info
//   <out>/diag.json           how CoreText resolves the system font along zpui's path vs AppKit's
//
// Usage: swift tools/font-compare/native.swift tools/font-compare/cases.json zig-out/font-compare

import AppKit
import CoreText

struct Case: Decodable { let id: String; let text: String; let size: Double; let weight: Int; let fg: String; let bg: String }
struct Cases: Decodable { let width: Double; let cases: [Case] }

let args = CommandLine.arguments
let casesPath = args.count > 1 ? args[1] : "tools/font-compare/cases.json"
let outDir = args.count > 2 ? args[2] : "zig-out/font-compare"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
let spec = try JSONDecoder().decode(Cases.self, from: Data(contentsOf: URL(fileURLWithPath: casesPath)))
let W = spec.width

// Shared row geometry (the Zig side uses the same formulas).
func rowHeight(_ c: Case) -> Double { (c.size * 1.6).rounded(.up) + 8 }
func baseline(_ c: Case) -> Double { (rowHeight(c) * 0.5 + c.size * 0.35).rounded() }
let textX = 16.0

func color(_ hex: String) -> NSColor {
    var s = hex; if s.hasPrefix("#") { s.removeFirst() }
    var v: UInt64 = 0; Scanner(string: s).scanHexInt64(&v)
    let hasA = s.count == 8
    let r = Double((v >> (hasA ? 24 : 16)) & 0xff) / 255, g = Double((v >> (hasA ? 16 : 8)) & 0xff) / 255
    let b = Double((v >> (hasA ? 8 : 0)) & 0xff) / 255, a = hasA ? Double(v & 0xff) / 255 : 1
    return NSColor(srgbRed: r, green: g, blue: b, alpha: a)
}

func nsWeight(_ w: Int) -> NSFont.Weight {
    switch w {
    case ..<150: return .ultraLight
    case ..<250: return .thin
    case ..<350: return .light
    case ..<450: return .regular
    case ..<550: return .medium
    case ..<650: return .semibold
    case ..<750: return .bold
    case ..<850: return .heavy
    default: return .black
    }
}

func nativeFont(_ c: Case) -> NSFont { NSFont.systemFont(ofSize: CGFloat(c.size), weight: nsWeight(c.weight)) }

final class Rows: NSView {
    let cases: [Case]
    init(_ cases: [Case]) {
        self.cases = cases
        let h = cases.reduce(0) { $0 + rowHeight($1) }
        super.init(frame: NSRect(x: 0, y: 0, width: W, height: h))
        var y = 0.0
        for c in cases {
            let label = NSTextField(labelWithAttributedString: NSAttributedString(string: c.text, attributes: [.font: nativeFont(c), .foregroundColor: color(c.fg)]))
            label.sizeToFit()
            let fieldBaseline = label.firstBaselineOffsetFromTop
            // NSTextField labels inset their text by the 2 pt line fragment padding.
            label.setFrameOrigin(NSPoint(x: textX - 2, y: y + baseline(c) - fieldBaseline))
            addSubview(label)
            y += rowHeight(c)
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func draw(_ dirty: NSRect) {
        var y = 0.0
        for c in cases {
            color(c.bg).setFill()
            NSRect(x: 0, y: y, width: W, height: rowHeight(c)).fill()
            y += rowHeight(c)
        }
    }
}

func writePNG(_ rep: NSBitmapImageRep, _ name: String) {
    let data = rep.representation(using: .png, properties: [:])!
    try! data.write(to: URL(fileURLWithPath: outDir + "/" + name))
    print("wrote \(outDir)/\(name) \(rep.pixelsWide)x\(rep.pixelsHigh)")
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
app.appearance = NSAppearance(named: .darkAqua)

// 1. Offscreen cacheDisplay at 1x and 2x.
for scale in [1, 2] {
    let view = Rows(spec.cases)
    view.appearance = NSAppearance(named: .darkAqua)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(view.bounds.width) * scale, pixelsHigh: Int(view.bounds.height) * scale,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 32)!
    rep.size = view.bounds.size
    view.cacheDisplay(in: view.bounds, to: rep)
    writePNG(rep.converting(to: .sRGB, renderingIntent: .default) ?? rep, "native-s\(scale).png")
}

// 2. Real windows (WindowServer composition, the backing scale of the CI display), in pages.
var pages: [[Case]] = [[]]
var pageH = 0.0
for c in spec.cases {
    if pageH + rowHeight(c) > 640 { pages.append([]); pageH = 0 }
    pages[pages.count - 1].append(c); pageH += rowHeight(c)
}
// CGWindowListCreateImage is marked unavailable in the macOS 15 SDK (still exported): call it via dlsym.
typealias WindowListCreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
func windowImage(_ id: CGWindowID) -> CGImage? {
    guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil }
    let fn = unsafeBitCast(sym, to: WindowListCreateImage.self)
    // .optionIncludingWindow = 1 << 3; .boundsIgnoreFraming = 1 << 0, .bestResolution = 1 << 3
    return fn(.null, 1 << 3, id, (1 << 0) | (1 << 3))?.takeRetainedValue()
}
var captures: [CGImage] = []
var windowScale = 1.0
for page in pages {
    let view = Rows(page)
    let win = NSWindow(contentRect: NSRect(x: 40, y: 40, width: view.bounds.width, height: view.bounds.height), styleMask: [.borderless], backing: .buffered, defer: false)
    win.appearance = NSAppearance(named: .darkAqua)
    win.contentView = view
    win.isOpaque = true
    win.orderFrontRegardless()
    win.displayIfNeeded()
    RunLoop.current.run(until: Date().addingTimeInterval(0.8))
    windowScale = win.backingScaleFactor
    if let img = windowImage(CGWindowID(win.windowNumber)) {
        captures.append(img)
    } else {
        print("window capture failed (no screen recording permission?)")
    }
    win.orderOut(nil)
}
if !captures.isEmpty {
    let w = captures.map { $0.width }.max()!, h = captures.reduce(0) { $0 + $1.height }
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 32)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    var y = h
    for img in captures { y -= img.height; ctx.draw(img, in: CGRect(x: 0, y: y, width: img.width, height: img.height)) }
    writePNG(rep, "native-window.png")
}

// 3. Metrics.
func variation(_ f: CTFont) -> [String: Double] {
    var out: [String: Double] = [:]
    if let v = CTFontCopyVariation(f) as? [NSNumber: NSNumber] {
        for (k, val) in v {
            let t = k.uint32Value
            let tag = String(bytes: [UInt8(t >> 24 & 0xff), UInt8(t >> 16 & 0xff), UInt8(t >> 8 & 0xff), UInt8(t & 0xff)], encoding: .ascii) ?? "\(t)"
            out[tag] = val.doubleValue
        }
    }
    return out
}

func lineInfo(_ f: CTFont, _ text: String) -> (width: Double, xs: [Double], glyphs: [Int]) {
    let s = NSAttributedString(string: text, attributes: [.font: f])
    let line = CTLineCreateWithAttributedString(s)
    var xs: [Double] = [], glyphs: [Int] = []
    for run in CTLineGetGlyphRuns(line) as! [CTRun] {
        let n = CTRunGetGlyphCount(run)
        var pos = [CGPoint](repeating: .zero, count: n), gl = [CGGlyph](repeating: 0, count: n)
        CTRunGetPositions(run, CFRange(location: 0, length: 0), &pos)
        CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &gl)
        xs += pos.map { Double($0.x) }; glyphs += gl.map { Int($0) }
    }
    return (CTLineGetTypographicBounds(line, nil, nil, nil), xs, glyphs)
}

func fontInfo(_ f: CTFont) -> [String: Any] {
    let traits = CTFontCopyTraits(f) as NSDictionary
    return ["postscript": CTFontCopyPostScriptName(f) as String, "size": Double(CTFontGetSize(f)),
            "variation": variation(f), "weightTrait": (traits[kCTFontWeightTrait] as? Double) ?? 0,
            "widthTrait": (traits[kCTFontWidthTrait] as? Double) ?? 0,
            "descriptor": String(describing: CTFontCopyFontDescriptor(f)).replacingOccurrences(of: "\n", with: " ")]
}

var metrics: [[String: Any]] = []
for c in spec.cases {
    let f = nativeFont(c)
    let ct = lineInfo(f as CTFont, c.text)
    // TextKit 1, as NSTextField lays out.
    let storage = NSTextStorage(string: c.text, attributes: [.font: f])
    let lm = NSLayoutManager(); storage.addLayoutManager(lm)
    let tc = NSTextContainer(size: NSSize(width: 100000, height: 1000)); tc.lineFragmentPadding = 0; lm.addTextContainer(tc)
    lm.ensureLayout(for: tc)
    var tkXs: [Double] = []
    for g in 0..<lm.numberOfGlyphs { tkXs.append(Double(lm.location(forGlyphAt: g).x)) }
    metrics.append(["id": c.id, "ct_width": ct.width, "ct_x": ct.xs, "glyphs": ct.glyphs, "tk_x": tkXs,
                    "tk_width": Double(lm.usedRect(for: tc).width), "attr_width": Double(NSAttributedString(string: c.text, attributes: [.font: f]).size().width),
                    "font": fontInfo(f as CTFont)])
}
let mjson = try JSONSerialization.data(withJSONObject: ["window_scale": windowScale, "cases": metrics], options: [.prettyPrinted, .sortedKeys])
try mjson.write(to: URL(fileURLWithPath: outDir + "/native.json"))

// 4. Diagnostics: the system font along zpui's CoreText path and along candidate fixes.
func cssToCT(_ w: Int) -> Double {
    let t: [Double] = [-1.0, -0.7, -0.5, -0.23, 0.0, 0.2, 0.3, 0.4, 0.6, 0.8, 1.0]
    let x = min(max(Double(w) / 100, 0), 10); let i = min(Int(x), 9)
    return t[i] + (t[i + 1] - t[i]) * (x - Double(i))
}

/// zpui (HEAD): every face matching family ".AppleSystemUIFont", each at size = upem, best (width 0, nearest weight), copied to `size`.
func zpuiPath(_ size: Double, _ weight: Int) -> CTFont? {
    let desc = CTFontDescriptorCreateWithAttributes([kCTFontFamilyNameAttribute: ".AppleSystemUIFont"] as CFDictionary)
    let matches = (CTFontDescriptorCreateMatchingFontDescriptors(desc, NSSet(array: [kCTFontFamilyNameAttribute]) as CFSet) as? [CTFontDescriptor]) ?? []
    var best: CTFont? = nil; var bestScore = Double.infinity
    for d in matches {
        let base = CTFontCreateWithFontDescriptor(d, 0, nil)
        let unit = CTFontCreateCopyWithAttributes(base, CGFloat(CTFontGetUnitsPerEm(base)), nil, nil)
        let tr = CTFontCopyTraits(unit) as NSDictionary
        let wt = (tr[kCTFontWeightTrait] as? Double) ?? 0, wd = (tr[kCTFontWidthTrait] as? Double) ?? 0
        let italic = (CTFontGetSymbolicTraits(unit).rawValue & CTFontSymbolicTraits.traitItalic.rawValue) != 0
        let score = abs(wd) * 100 + abs(wt - cssToCT(weight)) + (italic ? 1000 : 0)
        if score < bestScore { bestScore = score; best = unit }
    }
    print("zpui path: \(matches.count) descriptors for .AppleSystemUIFont")
    return best.map { CTFontCreateCopyWithAttributes($0, CGFloat(size), nil, nil) }
}

func usageName(_ w: Int) -> String {
    switch w {
    case ..<150: return "CTFontUltraLightUsage"
    case ..<250: return "CTFontThinUsage"
    case ..<350: return "CTFontLightUsage"
    case ..<450: return "CTFontRegularUsage"
    case ..<550: return "CTFontMediumUsage"
    case ..<650: return "CTFontDemiUsage"
    case ..<750: return "CTFontBoldUsage"
    case ..<850: return "CTFontHeavyUsage"
    default: return "CTFontBlackUsage"
    }
}

var diag: [[String: Any]] = []
let sample = "Hamburgefonstiv quick brown fox 0123456789"
for weight in [400, 500, 600, 700] {
    for size in [11.0, 13.0, 16.0, 20.0, 28.0] {
        let native = NSFont.systemFont(ofSize: size, weight: nsWeight(weight)) as CTFont
        let upem = CGFloat(CTFontGetUnitsPerEm(native))
        var cands: [(String, CTFont?)] = []
        cands.append(("zpui_head", zpuiPath(size, weight)))
        cands.append(("uifont_upem_copy", CTFontCreateCopyWithAttributes(CTFontCreateUIFontForLanguage(.system, upem, nil)!, size, nil, nil)))
        cands.append(("nsfont_upem_copy", CTFontCreateCopyWithAttributes(NSFont.systemFont(ofSize: upem, weight: nsWeight(weight)) as CTFont, size, nil, nil)))
        cands.append(("nsfont_upem_desc", CTFontCreateWithFontDescriptor(CTFontCopyFontDescriptor(NSFont.systemFont(ofSize: upem, weight: nsWeight(weight)) as CTFont), size, nil)))
        let named = CTFontDescriptorCreateWithAttributes([kCTFontNameAttribute: ".AppleSystemUIFont",
                                                          kCTFontTraitsAttribute: [kCTFontWeightTrait: cssToCT(weight)]] as CFDictionary)
        cands.append(("name_traits_desc", CTFontCreateWithFontDescriptor(named, size, nil)))
        let uiW = CTFontCreateUIFontForLanguage(.system, size, nil)!
        let wdesc = CTFontDescriptorCreateWithAttributes([kCTFontTraitsAttribute: [kCTFontWeightTrait: cssToCT(weight)]] as CFDictionary)
        cands.append(("uifont_weight_copy", CTFontCreateCopyWithAttributes(uiW, size, nil, wdesc)))
        // AppKit's own descriptor: the UI usage attribute at the real size (optical size and tracking follow it).
        let usageDesc = CTFontDescriptorCreateWithAttributes(["NSCTFontUIUsageAttribute": usageName(weight)] as CFDictionary)
        cands.append(("usage_desc", CTFontCreateWithFontDescriptor(usageDesc, size, nil)))
        cands.append(("usage_upem_copy", CTFontCreateCopyWithAttributes(CTFontCreateWithFontDescriptor(usageDesc, upem, nil), size, nil, nil)))
        cands.append(("native_desc_size", CTFontCreateWithFontDescriptor(CTFontCopyFontDescriptor(native), size, nil)))
        cands.append(("native_upem_copy", CTFontCreateCopyWithAttributes(CTFontCreateCopyWithAttributes(native, upem, nil, nil), size, nil, nil)))
        let nl = lineInfo(native, sample)
        var row: [String: Any] = ["size": size, "weight": weight, "native": fontInfo(native), "native_width": nl.width]
        var cl: [String: Any] = [:]
        for (name, f) in cands {
            guard let f else { cl[name] = "nil"; continue }
            let li = lineInfo(f, sample)
            let maxdx = zip(li.xs, nl.xs).map { abs($0 - $1) }.max() ?? -1
            var info = fontInfo(f); info["width"] = li.width; info["width_delta"] = li.width - nl.width
            info["max_glyph_dx"] = li.xs.count == nl.xs.count ? maxdx : -1
            info["same_glyphs"] = li.glyphs == nl.glyphs
            cl[name] = info
            print(String(format: "diag %4d %5.1f %-20@ width %8.3f (native %8.3f, Δ %+.3f) maxdx %.3f ps=%@ var=%@", weight, size, name as NSString,
                         li.width, nl.width, li.width - nl.width, maxdx, CTFontCopyPostScriptName(f) as String as NSString, variation(f).description as NSString))
        }
        print("diag native descriptor \(weight) \(size): \(String(describing: CTFontCopyFontDescriptor(native)).replacingOccurrences(of: "\n", with: " "))")
        print(String(format: "diag %4d %5.1f %-20@ ps=%@ var=%@", weight, size, "NATIVE" as NSString, CTFontCopyPostScriptName(native) as String as NSString, variation(native).description as NSString))
        row["candidates"] = cl
        diag.append(row)
    }
}
// Probe: the system font around 28 pt, including the one-ULP-larger size zpui uses on the
// first run of a line (layoutLine breaks ligatures across runs by alternating sizes).
for size in [27.0, 27.5, 28.0, Double(Float(28).nextUp), 28.5, 29.0, 13.0, Double(Float(13).nextUp)] {
    let usageDesc = CTFontDescriptorCreateWithAttributes(["NSCTFontUIUsageAttribute": "CTFontRegularUsage"] as CFDictionary)
    let f = CTFontCreateWithFontDescriptor(usageDesc, CGFloat(size), nil)
    let ns = NSFont.systemFont(ofSize: CGFloat(size), weight: .regular) as CTFont
    let li = lineInfo(f, sample), ln = lineInfo(ns, sample)
    // Every descriptor attribute (tracking, optical size, usage) as CoreText reports it.
    let tracking = String(describing: CTFontDescriptorCopyAttributes(CTFontCopyFontDescriptor(f))).replacingOccurrences(of: "\n", with: " ")
    var gl = li.glyphs.map { CGGlyph($0) }
    var adv = [CGSize](repeating: .zero, count: gl.count)
    CTFontGetAdvancesForGlyphs(f, .default, &gl, &adv, gl.count)
    let tkWidth = NSAttributedString(string: sample, attributes: [.font: NSFont.systemFont(ofSize: CGFloat(size), weight: .regular)]).size().width
    print(String(format: "probe size %.7f ps=%@ ctsize=%.7f var=%@ tracking=%@ ctline=%.4f nsfont_ctline=%.4f attr_size=%.4f", size,
                 CTFontCopyPostScriptName(f) as String as NSString, Double(CTFontGetSize(f)), variation(f).description as NSString,
                 tracking as NSString, li.width, ln.width, Double(tkWidth)))
    print("probe size \(size) advances(first 12): \(adv.prefix(12).map { String(format: "%.3f", $0.width) }.joined(separator: " "))")
    print("probe size \(size) positions(first 12): \(li.xs.prefix(12).map { String(format: "%.3f", $0) }.joined(separator: " "))")
}

let djson = try JSONSerialization.data(withJSONObject: diag, options: [.prettyPrinted, .sortedKeys])
try djson.write(to: URL(fileURLWithPath: outDir + "/diag.json"))
print("done")
