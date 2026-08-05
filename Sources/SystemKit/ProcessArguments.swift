import Foundation
import Darwin

/// Reads a process's command line, so interpreters can be named by what they
/// are actually running.
///
/// `node` is not an answer to "what is holding 1.5 GB of my memory?" — on this
/// very Mac those turned out to be three MCP servers belonging to an editor
/// session, and a prompt offering to close "node" would have killed them
/// without the user having any idea what they were agreeing to. The script is
/// the name a person can judge.
public enum ProcessArguments {
    /// Interpreters whose own name says nothing about what they're doing.
    public static let interpreters: Set<String> = [
        "node", "deno", "bun", "python", "python2", "python3", "ruby", "perl",
        "php", "java", "sh", "bash", "zsh", "osascript",
    ]

    public static func isInterpreter(_ name: String) -> Bool {
        interpreters.contains(name)
    }

    /// The full argv of a process, or empty when it can't be read (another
    /// user's process, or one that exited between the listing and this call).
    public static func arguments(of pid: pid_t) -> [String] {
        // KERN_PROCARGS2 hands back: argc, then the executable path, then a
        // run of NUL-terminated strings — argv followed by the environment.
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return [] }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else {
            return []
        }

        var argc: Int32 = 0
        withUnsafeMutableBytes(of: &argc) { destination in
            buffer.withUnsafeBytes { source in
                destination.copyBytes(from: UnsafeRawBufferPointer(rebasing: source[0..<4]))
            }
        }
        guard argc > 0 else { return [] }

        var strings: [String] = []
        var current: [CChar] = []
        // Skip argc, then the executable path and the padding after it.
        var index = MemoryLayout<Int32>.size
        // Executable path comes first and is followed by one or more NULs.
        while index < size, buffer[index] != 0 { index += 1 }
        while index < size, buffer[index] == 0 { index += 1 }

        while index < size, strings.count < Int(argc) {
            if buffer[index] == 0 {
                strings.append(String(cString: current + [0]))
                current.removeAll(keepingCapacity: true)
            } else {
                current.append(buffer[index])
            }
            index += 1
        }
        return strings
    }

    /// Script extensions worth dropping: `server.js` reads better as `server`,
    /// and nobody thinks of it by its extension.
    private static let scriptExtensions: Set<String> = [
        "js", "mjs", "cjs", "ts", "py", "rb", "pl", "php", "sh", "jar",
    ]

    /// The name to show for an interpreter, from its arguments. `nil` when the
    /// command line says nothing useful — better the plain interpreter name
    /// than a confident guess.
    public static func scriptName(fromArguments arguments: [String]) -> String? {
        // Everything after the interpreter itself, minus its flags.
        for argument in arguments.dropFirst() {
            if argument.hasPrefix("-") { continue }
            // `node --experimental-x=1 script.js`: skip flag values too.
            let component = (argument as NSString).lastPathComponent
            guard !component.isEmpty, component != "." else { continue }
            let ext = (component as NSString).pathExtension.lowercased()
            let bare = ext.isEmpty || !scriptExtensions.contains(ext)
                ? component
                : (component as NSString).deletingPathExtension
            // A bare `node` with no script is a REPL; nothing to name it after.
            guard !bare.isEmpty, bare != "-" else { continue }
            return bare
        }
        return nil
    }

    /// Convenience: the display name for a live interpreter process.
    public static func scriptName(of pid: pid_t) -> String? {
        scriptName(fromArguments: arguments(of: pid))
    }
}
