// swift-tools-version: 6.0
import PackageDescription

let package = Package(
	name: "Reckon",
	platforms: [.macOS(.v15), .iOS(.v17)],
	products: [
		.library(name: "ReckonCore", targets: ["ReckonCore"]),
		.library(name: "ReckonUI", targets: ["ReckonUI"]),
		.executable(name: "ReckonMac", targets: ["ReckonMac"]),
		.executable(name: "reckon", targets: ["reckon"])
	],
	targets: [
		.target(name: "ReckonCore"),
		.target(name: "ReckonUI", dependencies: ["ReckonCore"]),
		.executableTarget(name: "ReckonMac", dependencies: ["ReckonUI"]),
		.executableTarget(name: "reckon", dependencies: ["ReckonCore"]),
		.testTarget(name: "ReckonCoreTests", dependencies: ["ReckonCore"])
	]
)
