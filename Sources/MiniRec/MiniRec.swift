import Foundation

@main
struct MiniRecEntry {
    @MainActor
    static func main() async {
        let args = CommandLine.arguments
        
        // If launched via Finder or double-click or explicit 'app' command
        if args.count > 1 && args[1].lowercased() == "app" {
            MiniRecApp.run()
        } else if args.count == 1 {
            if isatty(STDIN_FILENO) == 0 {
                MiniRecApp.run()
            } else {
                await MiniRecCLI.run(arguments: args)
            }
        } else {
            await MiniRecCLI.run(arguments: args)
        }
    }
}
