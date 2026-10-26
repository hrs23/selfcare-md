# selfcare.md

Local-first self-care log (workouts, habits, health) for iPhone. Your records are plain Markdown files that you own and can sync to WebDAV or other storage.

## Build

- `Core/` is a Swift package with the logic and its tests: `swift test --package-path Core`
- `App/` is the iOS app: `xcodegen generate`, then open `SelfcareMD.xcodeproj`

## License

MIT
