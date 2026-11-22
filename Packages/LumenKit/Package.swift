// swift-tools-version: 6.0
//
// LumenKit — every portable Lumen module: domain engines, application composition and view
// models. Nothing here imports SwiftUI or UIKit, so the whole package builds and tests on Linux
// as well as on Apple platforms. The interface lives in Packages/LumenInterface.

import PackageDescription

let swiftSettings: [SwiftSetting] = [
    .enableUpcomingFeature("ExistentialAny"),
]

/// A library target with the shared settings.
func module(_ name: String, dependencies: [Target.Dependency] = []) -> Target {
    .target(name: name, dependencies: dependencies, swiftSettings: swiftSettings)
}

/// A test target with the shared settings.
func tests(_ name: String, dependencies: [Target.Dependency]) -> Target {
    .testTarget(name: name, dependencies: dependencies + ["LumenTestSupport"], swiftSettings: swiftSettings)
}

let package = Package(
    name: "LumenKit",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "LumenFoundation", targets: ["LumenFoundation"]),
        .library(name: "LumenPersistence", targets: ["LumenPersistence"]),
        .library(name: "LumenCore", targets: ["LumenCore"]),
        .library(name: "LumenNotifications", targets: ["LumenNotifications"]),
        .library(name: "LumenOrganization", targets: ["LumenOrganization"]),
        .library(name: "LumenSearch", targets: ["LumenSearch"]),
        .library(name: "LumenSync", targets: ["LumenSync"]),
        .library(name: "LumenPlugins", targets: ["LumenPlugins"]),
        .library(name: "LumenAnalytics", targets: ["LumenAnalytics"]),
        .library(name: "LumenKnowledge", targets: ["LumenKnowledge"]),
        .library(name: "LumenAutomation", targets: ["LumenAutomation"]),
        .library(name: "LumenDesignTokens", targets: ["LumenDesignTokens"]),
        .library(name: "LumenWidgetData", targets: ["LumenWidgetData"]),
        .library(name: "LumenApplication", targets: ["LumenApplication"]),
    ],
    targets: [
        .systemLibrary(name: "CSQLite", path: "Sources/CSQLite", providers: [.apt(["libsqlite3-dev"])]),

        module("LumenFoundation"),
        module("LumenPersistence", dependencies: [
            "LumenFoundation",
            .target(name: "CSQLite", condition: .when(platforms: [.linux])),
        ]),

        module("LumenCore", dependencies: ["LumenFoundation", "LumenPersistence"]),
        module("LumenNotifications", dependencies: ["LumenCore"]),
        module("LumenOrganization", dependencies: ["LumenCore"]),
        module("LumenSearch", dependencies: ["LumenCore"]),
        module("LumenSync", dependencies: ["LumenCore"]),
        module("LumenPlugins", dependencies: ["LumenCore"]),
        module("LumenAnalytics", dependencies: ["LumenCore"]),
        module("LumenKnowledge", dependencies: ["LumenCore"]),
        module("LumenAutomation", dependencies: ["LumenCore"]),
        module("LumenDesignTokens"),
        module("LumenWidgetData"),
        module("LumenApplication", dependencies: [
            "LumenCore", "LumenNotifications", "LumenOrganization", "LumenSearch", "LumenSync",
            "LumenPlugins", "LumenAnalytics", "LumenWidgetData", "LumenKnowledge",
        ]),

        module("LumenTestSupport", dependencies: ["LumenFoundation", "LumenPersistence", "LumenCore"]),

        tests("LumenFoundationTests", dependencies: ["LumenFoundation"]),
        tests("LumenPersistenceTests", dependencies: ["LumenPersistence"]),
        tests("LumenCoreTests", dependencies: ["LumenCore"]),
        tests("LumenNotificationsTests", dependencies: ["LumenNotifications"]),
        tests("LumenOrganizationTests", dependencies: ["LumenOrganization"]),
        tests("LumenSearchTests", dependencies: ["LumenSearch"]),
        tests("LumenSyncTests", dependencies: ["LumenSync"]),
        tests("LumenPluginsTests", dependencies: ["LumenPlugins"]),
        tests("LumenAnalyticsTests", dependencies: ["LumenAnalytics"]),
        tests("LumenKnowledgeTests", dependencies: ["LumenKnowledge"]),
        tests("LumenAutomationTests", dependencies: ["LumenAutomation"]),
        tests("LumenDesignTokensTests", dependencies: ["LumenDesignTokens"]),
        tests("LumenApplicationTests", dependencies: ["LumenApplication"]),
    ]
)
