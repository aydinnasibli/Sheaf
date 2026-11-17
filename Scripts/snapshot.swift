// Asks a running Debug build of Sheaf to save a picture of its window,
// without bringing it to the front, and copies the picture to a path.
//
//     swift Scripts/snapshot.swift /path/to/picture.png
import Foundation

let destination = URL(filePath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "sheaf-window.png")
// Sheaf is sandboxed, so it saves the picture inside its own container.
let picture = FileManager.default.homeDirectoryForCurrentUser
    .appending(path: "Library/Containers/com.aydinnasibli.sheaf/Data/tmp/sheaf-window.png")

try? FileManager.default.removeItem(at: picture)
DistributedNotificationCenter.default().postNotificationName(
    Notification.Name("sheaf.debug.snapshot"), object: nil, userInfo: nil, deliverImmediately: true
)
for _ in 0..<50 where !FileManager.default.fileExists(atPath: picture.path) {
    Thread.sleep(forTimeInterval: 0.1)
}
Thread.sleep(forTimeInterval: 0.2)

do {
    try? FileManager.default.removeItem(at: destination)
    try FileManager.default.copyItem(at: picture, to: destination)
    print(destination.path)
} catch {
    print("Sheaf didn't answer. Is a Debug build running?")
    exit(1)
}
