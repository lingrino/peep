import Foundation

// Extension entry point. Warm fonts and tables on a background thread while dyld, AppKit and
// Quick Look's view-service setup run on this one (see Prewarm), then hand off to the
// standard extension main, which never returns.
@_silgen_name("NSExtensionMain")
func NSExtensionMain(_ argc: Int32, _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Int32

DispatchQueue.global(qos: .userInteractive).async { Prewarm.run() }
#if PEEP_DIAG
Diag.start()
#endif
exit(NSExtensionMain(CommandLine.argc, CommandLine.unsafeArgv))
