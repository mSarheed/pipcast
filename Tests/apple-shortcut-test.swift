import Foundation

@main
struct AppleShortcutTest {
    static func main() {
        var failures = 0

        func check(_ description: String, _ condition: @autoclosure () -> Bool) {
            if condition() {
                print("PASS  \(description)")
            } else {
                print("FAIL  \(description)")
                failures += 1
            }
        }

        let volume = UUID(uuidString: "97A1DDFA-76F3-4872-A672-25D5F35B7882")!
        let pdf = UUID(uuidString: "B63D79CE-D540-4E8C-B5E4-B3BF5FDD1897")!
        let recipes = UUID(uuidString: "DCA44E1D-F062-424D-BA7C-FA91DBFE33FF")!

        // The tool's real output on a Mac holding three shortcuts, in its own order.
        let listed = AppleShortcut.parseList(
            """
            Set Volume to 50% (97A1DDFA-76F3-4872-A672-25D5F35B7882)
            Summarize PDF (B63D79CE-D540-4E8C-B5E4-B3BF5FDD1897)
            Leftover Recipes (DCA44E1D-F062-424D-BA7C-FA91DBFE33FF)

            """)
        check("every listed shortcut is read", listed.count == 3)
        check("sorted by name, not listing order", listed.map(\.id) == [recipes, volume, pdf])
        check("the name loses its identifier", listed.first?.name == "Leftover Recipes")

        let parenthesised = AppleShortcut.parseList("Log (Work) Hours (\(volume.uuidString))")
        check("a name may carry parentheses", parenthesised.first?.name == "Log (Work) Hours")
        check("the trailing identifier still resolves", parenthesised.first?.id == volume)

        // The runner merges stderr in, so anything not shaped like a row must fall out.
        let noisy = AppleShortcut.parseList(
            """
            Error: something went wrong
            Broken (not-a-uuid)
            (\(pdf.uuidString))
            Summarize PDF (\(pdf.uuidString))
            Summarize PDF again (\(pdf.uuidString))
            """)
        check("noise, a bad identifier and a nameless row are dropped", noisy.count == 1)
        check("a repeated identifier keeps its first row", noisy.first?.name == "Summarize PDF")
        check("empty output is an empty library", AppleShortcut.parseList("").isEmpty)
        check(
            "a CRLF listing still parses",
            AppleShortcut.parseList("A (\(pdf.uuidString))\r\nB (\(volume.uuidString))\r\n").count == 2)

        // The sweep: whatever a store or binding still names that the fresh read no longer lists.
        let gone = UUID(uuidString: "0F6E3C1A-2B4D-4E5F-8A9B-1C2D3E4F5A6B")!
        let unbound = UUID(uuidString: "5A6B7C8D-9E0F-4A1B-8C2D-3E4F5A6B7C8D")!
        let stored = [
            AppleShortcut.entryID(for: volume), AppleShortcut.entryID(for: gone),
            "quicklink:\(gone.uuidString.lowercased())", "com.apple.Safari", "apple-shortcut:nope"
        ]
        let stale = AppleShortcut.staleIDs(referencedBy: stored, bound: [pdf, unbound], live: listed)
        check("a preference or binding for a deleted shortcut is stale", stale == [gone, unbound])
        check(
            "an empty read frees nothing, since it may be a read gone wrong",
            AppleShortcut.staleIDs(referencedBy: stored, bound: [pdf], live: []).isEmpty)
        check(
            "nothing referenced means nothing to sweep",
            AppleShortcut.staleIDs(referencedBy: ["com.apple.Safari"], bound: [], live: listed).isEmpty)

        let shortcut = AppleShortcut(id: recipes, name: "Leftover Recipes")
        check("an entry id round-trips", AppleShortcut.id(fromEntryID: shortcut.entryID) == recipes)
        check("another kind's id is refused", AppleShortcut.id(fromEntryID: "quicklink:\(recipes)") == nil)
        check("a malformed id is refused", AppleShortcut.id(fromEntryID: "apple-shortcut:nope") == nil)

        // Icon files: named by shortcut and pixels, so a changed icon is a new path.
        let icon = AppleShortcutIconFile(id: volume, digest: "0123456789abcdef")
        check(
            "an icon file is named by its lowercase id and digest",
            icon.fileName == "97a1ddfa-76f3-4872-a672-25d5f35b7882-0123456789abcdef.png")
        check("an icon file name round-trips", AppleShortcutIconFile(fileName: icon.fileName) == icon)
        let foreign = [
            "97a1ddfa-76f3-4872-a672-25d5f35b7882-0123456789abcdef.tiff",
            "97a1ddfa-76f3-4872-a672-25d5f35b7882-0123456789ABCDEF.png",
            "97a1ddfa-76f3-4872-a672-25d5f35b7882-0123.png",
            "97a1ddfa-76f3-4872-a672-25d5f35b7882-0123456789abcdeg.png",
            "not-a-uuid-0123456789abcdef.png", ".DS_Store", "0123456789abcdef.png"
        ]
        check(
            "a foreign or malformed file name is refused",
            foreign.allSatisfy { AppleShortcutIconFile(fileName: $0) == nil })

        let newer = AppleShortcutIconFile(id: volume, digest: "fedcba9876543210")
        let orphan = AppleShortcutIconFile(id: gone, digest: "0123456789abcdef")
        let pdfIcon = AppleShortcutIconFile(id: pdf, digest: "aaaaaaaaaaaaaaaa")
        let scanned = AppleShortcutIconFile.resolve(
            fileNames: [newer.fileName, orphan.fileName, ".DS_Store", icon.fileName, pdfIcon.fileName],
            live: listed)
        check(
            "a scan keeps one icon per live shortcut",
            scanned.kept == [volume: icon, pdf: pdfIcon])
        check(
            "a scan frees a deleted shortcut's icon, a duplicate and anything foreign",
            Set(scanned.stale) == [newer.fileName, orphan.fileName, ".DS_Store"])
        check(
            "a scan of an empty folder keeps nothing",
            AppleShortcutIconFile.resolve(fileNames: [], live: listed) == ([:], []))

        let cachedIcons = [volume: icon]
        check(
            "only a shortcut without an icon is read outside a sweep",
            AppleShortcutIconFile.pending(live: listed, cached: cachedIcons, sweep: false)
                == [recipes, pdf])
        check(
            "a sweep re-reads every icon, since a new glyph keeps the identifier",
            AppleShortcutIconFile.pending(live: listed, cached: cachedIcons, sweep: true)
                == [recipes, volume, pdf])
        check(
            "nothing is read once every icon is cached",
            AppleShortcutIconFile.pending(
                live: listed, cached: [volume: icon, pdf: pdfIcon, recipes: icon], sweep: false
            ).isEmpty)

        print(failures == 0 ? "\nALL PASSED" : "\n\(failures) failed")
        if failures > 0 { exit(1) }
    }
}
