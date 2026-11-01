import Foundation
import SelfcareCore
import Testing

struct AppHelperTests {
    @Test func exportFileName() {
        #expect(PackInstaller.cleanName("a/b") == "a-b")
        #expect(PackInstaller.cleanName("../x") == "-x")
    }

    @Test func photoMediaPathResolves() {
        let path = "media/\(VaultTools.slug("Squat 100%25 off"))-abc123.jpg"
        #expect(ImageResolver.resolve("../" + path, fromDirectory: "menus", files: [path]) == path)
    }
}
