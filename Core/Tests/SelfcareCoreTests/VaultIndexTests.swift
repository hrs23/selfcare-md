import Foundation
import Testing
@testable import SelfcareCore

struct VaultIndexTests {
    @Test func problems() throws {
        let vault = tempVault()
        try vault.write("menus/Bad.md", "---\nrecord: nope\n---\n")
        try vault.write("menus/Good.md", "---\nrecord: check\n---\n")
        try vault.write("daily/2026-01-01.md", "# 2026-01-01\n\n## Memo\n")
        try vault.write("daily/2026-01-02.md", "# 2026-01-02\n\n## Selfcare\n\nhello\n")
        try vault.writeData("daily/2026-01-03.md", Data([0xFF, 0xFE]))
        try vault.write("daily/2026-01-04.md", "# 2026-01-04\n\n## Selfcare\n\n- [x] [[Good]]\n")
        try vault.write(Vault.templatePath, "# Template\n")
        let menus = vault.menuNames().map { MenuFile(name: $0, vault: vault, appleHealthTypes: []) }
        let problems = VaultIndex().problems(vault, menus: menus).map { "\($0.path): \($0.message)" }
        #expect(problems == [
            "daily/2026-01-01.md: No ## Selfcare",
            "daily/2026-01-02.md: Lines with problems",
            "daily/2026-01-03.md: Not UTF-8",
            "menus/Bad.md: Unknown record: nope",
            "templates/Daily.md: No ## Selfcare",
        ])
    }

    @Test func nonUTF8Template() throws {
        let vault = tempVault()
        try vault.writeData(Vault.templatePath, Data([0xFF]))
        #expect(VaultIndex().problems(vault, menus: []).map(\.message) == ["Not UTF-8"])
    }
}

struct ImageTests {
    let files = ["media/a.png", "media/my pic.png", "media/x/b.png"]

    func resolve(_ ref: String) -> String? {
        ImageResolver.resolve(ref, fromDirectory: "menus", files: files)
    }

    @Test func resolvesReferences() {
        #expect(resolve("../media/a.png") == "media/a.png")
        #expect(resolve("./../media/a.png") == "media/a.png")
        #expect(resolve("media/a.png") == "media/a.png")
        #expect(resolve("/media/a.png") == "media/a.png")
        #expect(resolve("b.png") == "media/x/b.png")
        #expect(resolve("other/b.png") == nil)
        #expect(resolve("../media/my%20pic.png") == "media/my pic.png")
        #expect(resolve("<../media/my pic.png>") == "media/my pic.png")
        #expect(resolve("../../media/a.png") == nil)
        #expect(resolve("https://example.com/media/a.png") == nil)
        #expect(resolve("missing.png") == nil)
    }

    @Test func photoMediaPathResolves() {
        let path = "media/\(VaultTools.slug("Squat 100%25 off"))-abc123.jpg"
        #expect(ImageResolver.resolve("../" + path, fromDirectory: "menus", files: [path]) == path)
    }

    @Test func markdownReferences() {
        let body = """
        ![a](../media/a.png) and ![[b.png|200]]
        ![c](../media/my%20pic.png "Title") ![web](https://example.com/x.png)
        ![d](<../media/d.png>)
        """
        #expect(MarkdownImages.references(in: body) == ["../media/a.png", "b.png", "../media/my pic.png", "../media/d.png"])
    }
}
