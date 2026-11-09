import AppKit
import Darwin

let options: AppOptions
do {
    options = try AppOptions.parse(arguments: CommandLine.arguments)
} catch {
    FileHandle.standardError.write(
        Data(("Error: \(error.localizedDescription)\n\n" + AppOptions.usage() + "\n").utf8)
    )
    exit(2)
}

if options.showHelp {
    print(AppOptions.usage())
    exit(0)
}
if options.showVersion {
    print("Teams Mic Float \(AppOptions.version)")
    exit(0)
}

let application = NSApplication.shared
application.setActivationPolicy(.accessory)

let appDelegate = MainActor.assumeIsolated {
    AppDelegate(options: options)
}
application.delegate = appDelegate
application.run()

withExtendedLifetime(appDelegate) {}
