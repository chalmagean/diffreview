import AppKit
import MachO

/// The app icon, linked into the binary's `__DATA,__app_icon` section (see Package.swift),
/// since a bare executable has no bundle to keep an .icns in.
enum AppIcon {
    static func load() -> NSImage? {
        guard let header = _dyld_get_image_header(0) else { return nil }
        var size: UInt = 0
        let machHeader = UnsafeRawPointer(header).assumingMemoryBound(to: mach_header_64.self)
        guard let bytes = getsectiondata(machHeader, "__DATA", "__app_icon", &size), size > 0 else { return nil }
        return NSImage(data: Data(bytes: bytes, count: Int(size)))
    }
}
