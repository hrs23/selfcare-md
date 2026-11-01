# selfcare.md

Local-first self-care log (workouts, habits, health) for iPhone. Your records are plain Markdown files that you own and can sync to WebDAV or S3-compatible storage.

## Build

Requirements: Xcode 26 (Swift 6.2) and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

- `Core/` is a Swift package with the logic and its tests: `swift test --package-path Core`
- `App/` is the iOS app: `xcodegen generate`, then open `SelfcareMD.xcodeproj`
- Builds embed an OpenAI API key for testing the assistant if one is set in `DEBUG_OPENAI_API_KEY` or `~/.config/selfcare-md/debug-openai-key`; the button that fills it in appears only in Debug and TestFlight builds. Build without it for anything you distribute.
- The WebDAV integration test runs only when `SELFCARE_WEBDAV_URL` is set (with `SELFCARE_WEBDAV_USER` and `SELFCARE_WEBDAV_PASSWORD`).

## Vault

The vault is the app's folder, shown in the Files app as On My iPhone › selfcare.md › selfcare.

- `daily/YYYY-MM-DD.md`: one page per day
- `menus/<name>.md`: one Menu per file
- `workouts/`: Apple Health workouts as TCX
- `media/`: images
- `templates/Daily.md`: the plan copied into each new day

## Packs

A pack is a folder with a `README.md`, `menus/*.md` and `media/`. Menu frontmatter keys: `record` (check, avoid or sets), `fields`, `initial`, `tags`, `thumbnail` and `apple-health`. Bundled packs live in `App/Resources/Packs/<language>/`.

## License

MIT
