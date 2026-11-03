import AppKit

/// scripts/install-app.sh stages a new build next to a running Kite (`.Kite.app.new`) and leaves a waiter that
/// swaps it in once Kite quits. The waiter can miss the quit: it looks once a second, so a Kite reopened within
/// that second starts the old build again, and a restart of the Mac ends the waiter. Then everything merged since
/// (Claude's saved handoffs, for one) is missing until the next quit.
///
/// So a Kite that starts with a build staged beside it finishes the swap itself: before it opens any profile, it
/// hands the swap to a shell that waits for this process to end, moves the staged build in and opens it, and quits.
enum StagedUpdate {
    /// Call first thing at launch. Returns only when there's nothing to swap.
    @MainActor static func finishIfWaiting() {
        let bundle = Bundle.main.bundleURL.standardizedFileURL
        guard bundle.pathExtension == "app" else { return }
        let staged = bundle.deletingLastPathComponent().appendingPathComponent(".\(bundle.lastPathComponent).new")
        guard FileManager.default.fileExists(atPath: staged.appendingPathComponent("Contents/MacOS").path) else { return }
        // Another Kite from this bundle (`open -n`) would keep the swap waiting; leave it to the waiter then.
        let me = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { $0.processIdentifier != me && $0.bundleURL?.standardizedFileURL == bundle }
        guard others.isEmpty else { return }

        let swap = Process()
        swap.executableURL = URL(fileURLWithPath: "/bin/bash")
        // A test run (KITE_SUPPORT_PATH) starts the new build itself so it keeps its environment; `open` wouldn't.
        swap.arguments = ["-c", script, "kite-swap", String(me), bundle.path, staged.path,
                          ProcessInfo.processInfo.environment["KITE_SUPPORT_PATH"] == nil ? "open" : "exec"]
        swap.standardInput = FileHandle.nullDevice
        swap.standardOutput = FileHandle.nullDevice
        swap.standardError = FileHandle.nullDevice
        do {
            try swap.run()
        } catch {
            NSLog("Kite: couldn't start the staged update's swap: \(error)")
            return
        }
        NSLog("Kite: a newer build is staged at \(staged.path); swapping it in and reopening")
        exit(0)
    }

    /// $1 is Kite's pid, $2 the bundle, $3 the staged build, $4 how to start it again. Claims the staged build with
    /// one rename, like install-app.sh's waiter (whichever claims it first moves it in), and never swaps under a
    /// running Kite. Kite opens again either way, on the old build if the swap couldn't happen.
    static let script = #"""
        pid=$1 dest=$2 staged=$3 how=$4
        for _ in $(seq 200); do kill -0 "$pid" 2>/dev/null || break; sleep 0.05; done
        claimed="$(dirname "$dest")/.Kite.app.swapping.$$"
        if ! kill -0 "$pid" 2>/dev/null && ! pgrep -f "^$dest/Contents/MacOS/Kite( |\$)" >/dev/null \
            && mv "$staged" "$claimed" 2>/dev/null; then
            rm -rf "$dest"
            mv "$claimed" "$dest"
            /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$dest"
            touch "$dest"
            # install-app.sh's waiter ends by itself once its file is gone.
            rm -f "$(dirname "$dest")/.Kite.app.waiter"
        fi
        if [ "$how" = exec ]; then
            exec "$dest/Contents/MacOS/Kite"
        fi
        open "$dest"
        """#
}
