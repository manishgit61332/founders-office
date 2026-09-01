#!/usr/bin/env swift

import AppKit
import Foundation

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: request-app-quit.swift <bundle-identifier>\n".utf8))
    exit(64)
}

let bundleIdentifier = CommandLine.arguments[1]
let applications = NSRunningApplication.runningApplications(
    withBundleIdentifier: bundleIdentifier
)

let allRequestsAccepted = applications.reduce(true) { accepted, application in
    application.terminate() && accepted
}
exit(allRequestsAccepted ? 0 : 1)
