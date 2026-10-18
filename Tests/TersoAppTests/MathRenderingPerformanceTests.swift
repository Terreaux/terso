// SPDX-License-Identifier: AGPL-3.0-only
import AppKit
import Testing
@testable import TersoApp

@Suite @MainActor struct MathRenderingPerformanceTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TERSO_BENCHMARK_RENDERING"] == "1"))
    func coldEquationRendering() async throws {
        let renderer = MathImageRenderer()
        let clock = ContinuousClock()
        let start = clock.now
        let requests = (1...16).map { MathRenderRequest(formula: "x_{\($0)} = \\frac{a+\($0)}{b}", display: $0.isMultiple(of: 2)) }
        let images = try await renderer.images(requests: requests, macros: [:], fontSize: 18, width: 600, dark: false)
        #expect(images.count == 16 && images.allSatisfy { $0 != nil })
        print("Cold rendering, 16 distinct equations: \(start.duration(to: clock.now))")
    }

    @Test func batchPreservesOrderFailuresAndCacheIdentity() async throws {
        let renderer = MathImageRenderer()
        let request = MathRenderRequest(formula: #"\vect{p}_T=\frac{a}{b}"#, display: false)
        let requests = [request, MathRenderRequest(formula: #"\unknownCommand{x}"#, display: true), request,
                        MathRenderRequest(formula: #"\sum_{i=1}^{n}x_i"#, display: true)]
        let images = try await renderer.images(requests: requests, macros: [#"\vect"#: #"\mathbf{#1}"#], fontSize: 18, width: 500, dark: false)
        #expect(images.count == requests.count)
        let first = try #require(images[0])
        #expect(first === images[2])
        #expect(images[1] == nil)
        #expect((images[3]?.size.height ?? 0) > 10)
        let cached = try await renderer.images(requests: requests, macros: [#"\vect"#: #"\mathbf{#1}"#], fontSize: 18, width: 500, dark: false)
        #expect(cached[0] === first)
        #expect(cached[3] === images[3])
        let undefined = try await renderer.images(requests: [request], macros: [:], fontSize: 18, width: 500, dark: false)
        #expect(undefined[0] == nil)
    }

    @Test func batchFitsWideMathAndDoesNotLeakDefinitions() async throws {
        let renderer = MathImageRenderer()
        let wide = MathRenderRequest(formula: (1...30).map { "x_{\($0)}" }.joined(separator: "+"), display: true)
        let images = try await renderer.images(requests: [wide,
            MathRenderRequest(formula: #"\gdef\localmacro{x}\localmacro"#, display: false),
            MathRenderRequest(formula: #"\localmacro"#, display: false)], macros: [:], fontSize: 18, width: 180, dark: true)
        let fitted = try #require(images[0])
        #expect(fitted.size.width <= 180)
        #expect(fitted.size.height > 0)
        #expect(images[1] != nil)
        #expect(images[2] == nil)
        let larger = try await renderer.images(requests: [wide], macros: [:], fontSize: 24, width: 600, dark: false)
        #expect(larger[0] !== fitted)
        #expect((larger[0]?.size.width ?? 0) > fitted.size.width)
    }

    @Test func multipleBatchesKeepAllEquationsAndCancellationThrows() async throws {
        let renderer = MathImageRenderer()
        let requests = (1...20).map { MathRenderRequest(formula: "x_{\($0)}", display: false) }
        let images = try await renderer.images(requests: requests, macros: [:], fontSize: 18, width: 500, dark: false)
        #expect(images.count == 20 && images.allSatisfy { $0 != nil })
        let canceled = Task { @MainActor in
            try await renderer.images(requests: requests, macros: [:], fontSize: 18, width: 500, dark: false)
        }
        canceled.cancel()
        do {
            _ = try await canceled.value
            Issue.record("Canceled batch returned images")
        } catch is CancellationError { }
    }
}
