import ArgumentParser

/// Running `macha` with no arguments prints this help screen (a command group with no
/// run() of its own shows help).
@main
struct Macha: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "macha",
        abstract: "Send Mac state to Home Assistant over MQTT.",
        version: "0.1.3",
        subcommands: [
            RunCommand.self,
            StatusCommand.self,
            ConfigureCommand.self,
            DoctorCommand.self,
            ConfigCommand.self,
        ]
    )
}
