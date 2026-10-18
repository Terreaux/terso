// SPDX-License-Identifier: AGPL-3.0-only
import AppKit
import Testing
import WebKit
@testable import TersoApp

@Suite @MainActor struct MathBatchSnapshotTests {
    @Test func equationBelowInitialWebViewHeightRetainsItsInk() async throws {
        let preceding = (1...7).map { index in
            let rows = (1...18).map { "x_{\(index),\($0)}=\\frac{a+b}{c}" }.joined(separator: #" \\ "#)
            return MathRenderRequest(formula: #"\begin{matrix}"# + rows + #"\end{matrix}"#, display: true)
        }
        let target = MathRenderRequest(formula: #"z_{\mathrm{final}}=\frac{a^2+b^2}{c}"#, display: true)
        let requests = preceding + [target]
        // Prove this fixture reaches beyond the renderer's initial 2,000-point
        // frame rather than merely assuming that a long formula is tall enough.
        let rectangles = try await batchRectangles(requests: requests, width: 500, fontSize: 22)
        let finalRect = try #require(rectangles.last as? [Double])
        #expect(finalRect[1] > 2000)

        let images = try await MathImageRenderer().images(requests: requests, macros: [:], fontSize: 22, width: 500, dark: false)
        let actual = try #require(images.last.flatMap { $0 })
        let expected = try await standaloneImage(target, width: 500, fontSize: 22, dark: false)
        try expectMatchingInk(actual, expected, dark: false)
    }

    @Test(arguments: [false, true])
    func narrowTallEquationMatchesStandaloneSnapshot(dark: Bool) async throws {
        let rows = (1...10).map { index in
            #"\frac{a_{"# + String(index) + #"}+b^2}{c}+x_1+x_2+x_3+x_4+x_5+x_6+x_7"#
        }.joined(separator: #" \\ "#)
        let target = MathRenderRequest(formula: #"\begin{matrix}"# + rows + #"\end{matrix}"#, display: true)
        let images = try await MathImageRenderer().images(
            requests: [MathRenderRequest(formula: "p+q", display: false), target],
            macros: [:], fontSize: 20, width: 150, dark: dark)
        let actual = try #require(images[1])
        let expected = try await standaloneImage(target, width: 150, fontSize: 20, dark: dark)
        #expect(actual.size.width <= 150)
        #expect(actual.size.height > 40)
        try expectMatchingInk(actual, expected, dark: dark)
    }

    /// Compare against the pre-batch, one-formula HTML path, including its font
    /// loading and width fitting. A non-nil PDF image can still contain no ink.
    private func standaloneImage(_ request: MathRenderRequest, width: Double, fontSize: Double, dark: Bool) async throws -> NSImage {
        let web = makeWebView(width: width)
        defer { web.stopLoading() }
        web.loadHTMLString(ScienceMathHTML.document(source: request.formula, math: true, dark: dark,
                                                    fontSize: fontSize, display: request.display, strictRender: true), baseURL: nil)
        let deadline = ContinuousClock.now + .seconds(8)
        var ready = false
        while ContinuousClock.now < deadline {
            ready = (try? await web.evaluateJavaScript("document.querySelector('.katex') !== null && document.fonts.status === 'loaded'")) as? Bool ?? false
            if ready { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        try #require(ready)
        // Offscreen web views can suspend animation frames. Poll native-side
        // until post-font width fitting yields the same rectangle twice.
        var previousRect: [Double]?
        var stableRect: [Double]?
        for _ in 0..<20 {
            let current = try #require(try await web.evaluateJavaScript("(() => { const r=document.querySelector('.katex').getBoundingClientRect(); return [r.x,r.y,r.width,r.height]; })()") as? [Double])
            if current == previousRect { stableRect = current; break }
            previousRect = current
            try await Task.sleep(for: .milliseconds(25))
        }
        let rect = try #require(stableRect)
        let capture = WKPDFConfiguration()
        capture.rect = CGRect(x: max(0, rect[0] - 2), y: max(0, rect[1] - 2),
                              width: min(width, rect[2] + 4), height: rect[3] + 4)
        let image = try #require(NSImage(data: try await web.pdf(configuration: capture)))
        image.size = capture.rect!.size
        return image
    }

    private func batchRectangles(requests: [MathRenderRequest], width: Double, fontSize: Double) async throws -> [Any] {
        let web = makeWebView(width: width)
        defer { web.stopLoading() }
        web.loadHTMLString(MathBatchHTML.document(requests: requests, macros: [:], fontSize: fontSize, dark: false), baseURL: nil)
        let deadline = ContinuousClock.now + .seconds(8)
        while ContinuousClock.now < deadline {
            if let result = try? await web.evaluateJavaScript("window.__tersoMathRects"), let rectangles = result as? [Any] {
                let geometry = try await web.evaluateJavaScript("JSON.stringify({innerWidth,clientWidth:document.documentElement.clientWidth,bodyWidth:document.body.clientWidth,height:document.body.scrollHeight,last:window.__tersoMathRects.at(-1)})")
                print("Tall batch geometry: \(String(describing: geometry))")
                return rectangles
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        Issue.record("Batch did not finish loading its fonts and equation bounds")
        return []
    }

    private func makeWebView(width: Double) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: width, height: 2000), configuration: config)
        web.setValue(false, forKey: "drawsBackground")
        return web
    }

    private func expectMatchingInk(_ actual: NSImage, _ expected: NSImage, dark: Bool) throws {
        let actualInk = try ink(in: actual, dark: dark)
        let expectedInk = try ink(in: expected, dark: dark)
        #expect(actualInk.count > 80)
        #expect(expectedInk.count > 80)
        // Subpixel y positions can change antialiasing between stacked and
        // isolated PDF captures; allow a small tolerance, not missing glyphs.
        #expect(abs(Double(actualInk.count - expectedInk.count)) / Double(max(1, expectedInk.count)) < 0.15)
        #expect(abs(actualInk.bounds.width - expectedInk.bounds.width) <= 3)
        #expect(abs(actualInk.bounds.height - expectedInk.bounds.height) <= 3)
        #expect(abs(actual.size.width - expected.size.width) <= 2,
                "Actual image: \(actual.size); standalone image: \(expected.size). Actual ink: \(actualInk); standalone ink: \(expectedInk)")
        #expect(abs(actual.size.height - expected.size.height) <= 2,
                "Actual image: \(actual.size); standalone image: \(expected.size). Actual ink: \(actualInk); standalone ink: \(expectedInk)")
    }

    private func ink(in image: NSImage, dark: Bool) throws -> (count: Int, bounds: NSRect) {
        let width = max(1, Int(ceil(image.size.width * 2)))
        let height = max(1, Int(ceil(image.size.height * 2)))
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                  colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.size = NSSize(width: CGFloat(width), height: CGFloat(height))
        let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let frame = NSRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
        (dark ? NSColor.black : NSColor.white).setFill()
        frame.fill()
        image.draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1)
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        var count = 0, minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                let brightness = (color.redComponent + color.greenComponent + color.blueComponent) / 3
                guard dark ? brightness > 0.5 : brightness < 0.5 else { continue }
                count += 1
                minX = min(minX, x); minY = min(minY, y)
                maxX = max(maxX, x); maxY = max(maxY, y)
            }
        }
        let bounds = count == 0 ? NSRect.zero : NSRect(x: CGFloat(minX), y: CGFloat(minY),
                                                    width: CGFloat(maxX - minX + 1), height: CGFloat(maxY - minY + 1))
        return (count, bounds)
    }
}
