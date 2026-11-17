import AppKit
import UniformTypeIdentifiers

/// What a clicked link in a preview may do. Web and mail links open in their apps. A local
/// file opens in its default app only when it is a document; anything that could run code
/// (scripts, apps, installers, `.command`/`.terminal` files, internet locations, profiles,
/// bundles) is revealed in Finder instead. A cloned repository's README linking to
/// `setup.command` must not run it on a click (git checkouts carry no quarantine attribute,
/// so Gatekeeper wouldn't ask).
enum LinkPolicy {
    @MainActor static func open(_ url: URL) {
        switch url.scheme?.lowercased() {
        case "http", "https", "mailto":
            NSWorkspace.shared.open(url)
        case "file":
            let u = url.standardizedFileURL
            guard let v = try? u.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .contentTypeKey]) else { return }
            if (v.isDirectory == true && v.isPackage != true) || (v.contentType.map(isDocument) ?? false) {
                NSWorkspace.shared.open(u)   // a plain folder opens in Finder
            } else {
                NSWorkspace.shared.activateFileViewerSelecting([u])
            }
        default:
            break
        }
    }

    private static let documents: [UTType] = [.text, .image, .audiovisualContent, .pdf]
    private static let active: [UTType] = [.script, .executable, .application, .applicationBundle, .package, .bundle,
                                           .internetLocation] + ["com.apple.mobileconfig", "com.apple.configprofile",
                                                                 "com.apple.terminal.settings"].compactMap { UTType($0) }

    /// Text, images, media and PDFs, minus the kinds that conform to those but act when opened
    /// (shell and Python scripts are text; configuration profiles are XML).
    static func isDocument(_ t: UTType) -> Bool {
        documents.contains { t.conforms(to: $0) } && !active.contains { t.conforms(to: $0) }
    }
}
