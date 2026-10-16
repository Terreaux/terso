// swift-tools-version: 6.0
// Terso — a local-first writing instrument for macOS.
// SPDX-License-Identifier: AGPL-3.0-only

import PackageDescription

let package = Package(
    name: "Terso",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Terso", targets: ["TersoApp"]),
        .executable(name: "terso-eval", targets: ["terso-eval"]),
        .executable(name: "terso-fm", targets: ["terso-fm"]),
        .library(name: "TersoCore", targets: ["TersoCore"]),
    ],
    targets: [
        // Value types shared by every subsystem: ranges, snapshots, annotations,
        // suggestions. Nothing here can mutate a document.
        .target(name: "TersoCore"),

        // Deterministic local writing analysis (readability, style, complexity).
        .target(name: "TersoAnalysis", dependencies: ["TersoCore"], resources: [.copy("Resources/WordNet"), .copy("Resources/WritingAlternatives.json")]),

        // Statistical style engine: features, human reference bands, AI-style
        // signals, specificity.
        .target(
            name: "TersoStyle",
            dependencies: ["TersoCore"],
            resources: [.process("Resources")]
        ),

        // Optional AI providers. Deliberately does NOT depend on TersoDocument:
        // providers receive immutable snapshots and return suggestions as data.
        .target(name: "TersoAI", dependencies: ["TersoCore"]),

        // The canonical document and the review gate — the only place where a
        // suggestion can become an edit.
        .target(name: "TersoDocument", dependencies: ["TersoCore"]),

        .executableTarget(
            name: "TersoApp",
            dependencies: ["TersoCore", "TersoAnalysis", "TersoStyle", "TersoAI", "TersoDocument"],
            resources: [.copy("Resources/KaTeX"), .copy("Resources/Markdown"), .copy("Resources/LaTeX")]
        ),
        .executableTarget(
            name: "terso-eval",
            dependencies: ["TersoCore", "TersoStyle", "TersoAnalysis"]
        ),

        .executableTarget(name: "terso-fm", dependencies: ["TersoAI"]),

        .testTarget(name: "TersoCoreTests", dependencies: ["TersoCore"]),
        .testTarget(name: "TersoAnalysisTests", dependencies: ["TersoCore", "TersoAnalysis"], resources: [.copy("Fixtures")]),
        .testTarget(name: "TersoStyleTests", dependencies: ["TersoCore", "TersoStyle"]),
        .testTarget(name: "TersoAITests", dependencies: ["TersoCore", "TersoAI"]),
        .testTarget(name: "TersoDocumentTests", dependencies: ["TersoCore", "TersoDocument", "TersoAI"]),
        .testTarget(name: "TersoAppTests", dependencies: ["TersoApp"]),
    ]
)
