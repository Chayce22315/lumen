// swift-tools-version: 6.0
//
// LumenInterface — the SwiftUI layer. Apple platforms only; built by Xcode as part of the app.
// All behaviour lives in Packages/LumenKit; this package renders view-model state.

import PackageDescription

let swiftSettings: [SwiftSetting] = [
    .enableUpcomingFeature("ExistentialAny"),
]

func kit(_ name: String) -> Target.Dependency {
    .product(name: name, package: "LumenKit")
}

let package = Package(
    name: "LumenInterface",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "LumenDesignSystem", targets: ["LumenDesignSystem"]),
        .library(name: "LumenPlatform", targets: ["LumenPlatform"]),
        .library(name: "LumenUI", targets: ["LumenUI"]),
    ],
    dependencies: [
        .package(path: "../LumenKit"),
    ],
    targets: [
        .target(name: "LumenDesignSystem", dependencies: [kit("LumenDesignTokens")], swiftSettings: swiftSettings),
        .target(
            name: "LumenPlatform",
            dependencies: [
                kit("LumenApplication"), kit("LumenOrganization"), kit("LumenKnowledge"), kit("LumenCore"),
                kit("LumenNotifications"), kit("LumenSync"), kit("LumenFoundation"), kit("LumenWidgetData"),
            ],
            swiftSettings: swiftSettings
        ),
        .target(
            name: "LumenUI",
            dependencies: [
                "LumenDesignSystem",
                kit("LumenPresentation"), kit("LumenApplication"), kit("LumenOrganization"), kit("LumenKnowledge"),
                kit("LumenIntelligence"), kit("LumenAutomation"), kit("LumenAnalytics"), kit("LumenSearch"),
                kit("LumenNotifications"), kit("LumenSync"), kit("LumenPlugins"), kit("LumenCore"), kit("LumenFoundation"),
                kit("LumenDesignTokens"),
            ],
            swiftSettings: swiftSettings
        ),
    ]
)
