import ArgumentParser
import Foundation

struct ConfigCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "config",
        abstract: "Print the path to the config file."
    )

    func run() {
        // Only the path, so it works in scripts: open -e "$(macha config)"
        print(Config.path)
    }
}
