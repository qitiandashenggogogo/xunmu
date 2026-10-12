import Foundation
import DiskArbitration

/// A filesystem UUID, or a tagged GPT partition UUID when a third-party driver
/// does not expose one. Never uses mount paths, names, capacity or machine UUIDs.
public enum StableVolumeIdentity {
    public static func identifier(for url: URL) -> String? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        if let value = try? url.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString,
           !value.isEmpty { return value }
        let volumeURL = (try? url.resourceValues(forKeys: [.volumeURLKey]).volume) ?? url
        guard let session = DASessionCreate(nil),
              let disk = DADiskCreateFromVolumePath(nil, session, volumeURL as CFURL),
              let description = DADiskCopyDescription(disk) as? [String: Any],
              let value = description[kDADiskDescriptionMediaUUIDKey as String]
        else { return nil }
        let reference = value as CFTypeRef
        guard CFGetTypeID(reference) == CFUUIDGetTypeID() else { return nil }
        let uuid = unsafeDowncast(reference, to: CFUUID.self)
        guard let text = CFUUIDCreateString(nil, uuid) else { return nil }
        return "partition:" + (text as String)
    }
}
