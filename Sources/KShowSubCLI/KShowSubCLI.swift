// The Swift Programming Language
// https://docs.swift.org/swift-book

import ArgumentParser
import Foundation

@main
struct KShowSubCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: ProcessInfo.processInfo.processName)

    @Option(help: "Specify the input")
    public var input: String

    public func run() throws {
        print("Hello, world!")
    }
}
