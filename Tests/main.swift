import Darwin

let all: [Test] = textTests + searchTests + lexTests + markdownTests + archiveTests

let filter = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : nil
exit(runTests(all, filter: filter))
