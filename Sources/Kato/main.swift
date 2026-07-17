import Foundation
import KatoCore

// CLI subcommand mode is detected before the app starts. With no subcommand,
// the menu-bar agent app launches.
let arguments = Array(CommandLine.arguments.dropFirst())
if let subcommand = arguments.first, KatoCLI.knownSubcommands.contains(subcommand) {
    let code = await KatoCLI.run(subcommand: subcommand, arguments: Array(arguments.dropFirst()))
    exit(code)
}

KatoApp.main()
