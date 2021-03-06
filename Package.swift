// swift-tools-version:4.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "gltf_scenekit",
    products: [
        // Products define the executables and libraries produced by a package, and make them visible to other packages.
        .library(
            name: "gltf_scenekit",
            targets: ["gltf_scenekit"]),
    ],
    dependencies: [
        // Dependencies declare other packages that this package depends on.
         .package(url: "https://github.com/3d4medical/DracoSwiftPackage.git", from: "0.0.2"),
    ],
    targets: [
        // Targets are the basic building blocks of a package. A target can define a module or a test suite.
        // Targets can depend on other targets in this package, and on products in packages which this package depends on.
        .target(
            name: "gltf_scenekit",
            dependencies: []),
        .testTarget(
            name: "gltf_scenekitTests",
            dependencies: ["gltf_scenekit"]),
    ]
)


// swift build -Xswiftc "-target" -Xswiftc "x86_64-apple-macosx10.12"

