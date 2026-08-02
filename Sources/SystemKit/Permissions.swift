import Foundation
import Darwin

public enum Permissions {
    /// Probes a TCC-protected location. Without Full Disk Access the kernel
    /// returns EPERM; a missing dir (no Safari data) counts as accessible.
    public static func hasFullDiskAccess() -> Bool {
        let probe = NSHomeDirectory() + "/Library/Safari"
        guard let dir = opendir(probe) else {
            return errno != EPERM
        }
        closedir(dir)
        return true
    }

    public static let fullDiskAccessSettingsURL =
        "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
}
