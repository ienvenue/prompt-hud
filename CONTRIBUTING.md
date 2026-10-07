# Contributing to Prompt HUD

Thanks for your interest. Bug reports, ideas and pull requests are all welcome.

## Reporting a bug or asking for a feature

Open an [issue](https://github.com/ienvenue/prompt-hud/issues) and pick a template. For questions and open-ended ideas, use [Discussions](https://github.com/ienvenue/prompt-hud/discussions). For bugs, the most useful details are your macOS version, the app you were typing in, and the exact steps.

## Building

You need macOS 14 or later and Xcode 26 or later.

```bash
scripts/run.sh    # SwiftLint (if installed) → tests → build → restart the app
scripts/test.sh   # tests only, a couple of seconds
```

Install SwiftLint with `brew install swiftlint`. Lint errors stop `run.sh`; warnings don't.

### Code signing

The project signs to run locally by default (`Config/Signing.xcconfig`), so you can build without an Apple account. macOS may then forget the Accessibility permission after a rebuild; toggle Prompt HUD off and on in System Settings → Privacy & Security → Accessibility.

To keep the permission across rebuilds, sign with your own certificate. Create `Config/Signing.local.xcconfig` (it is git-ignored):

```
CODE_SIGN_IDENTITY = Apple Development
DEVELOPMENT_TEAM = YOURTEAMID
```

A free Apple ID added in Xcode → Settings → Accounts is enough.

### Testing against real data

Never test with your own prompts. Point the app at throwaway folders with launch arguments:

```bash
open DerivedData/PromptHUD/Build/Products/Debug/PromptHUD.app --args \
  -phLocalRoot /tmp/ph-local -phSyncRoot /tmp/ph-sync
```

## Project layout

| Path | What's in it |
|---|---|
| `PromptHUD/PHHUD.swift` | The popup |
| `PromptHUD/PHCapture.swift` | The capture and edit form |
| `PromptHUD/PHStore.swift` | Reading, writing, syncing and backing up prompts |
| `PromptHUD/PHSearch.swift` | Search and "similar text" |
| `PromptHUD/PHSystem.swift` | Caret location, inserting (clipboard + ⌘V), shortcut checks |
| `PromptHUD/PHPanel.swift` | Floating window, colors, toast |
| `PromptHUD/PHSettings.swift` | Settings window |
| `PromptHUD/PHUsage.swift` | Local usage log and weekly summary |
| `PromptHUD/Localizable.xcstrings` | All interface text and its translations |
| `PromptHUDTests/` | Tests for the data rules |

## Guidelines for changes

- **Interface text** is written in English in the code. When you add or change text, add the Simplified Chinese translation in `Localizable.xcstrings` too. To check that nothing is missing: `xcodebuild -exportLocalizations -project PromptHUD.xcodeproj -localizationPath /tmp/loc -exportLanguage zh-Hans`.
- **Data safety comes first.**
  - A file iCloud hasn't downloaded yet must never be treated as deleted or be overwritten.
  - Fields the app doesn't use (such as `trigger` and `description`) must be written back unchanged.
  - Changes to the data format need discussion in an issue first.
- **Privacy:** never log prompt text or search text, and don't add network access.
- If you change a rule covered by `PromptHUDTests/main.swift`, update the test as well.
- Keep pull requests focused on one change, and describe how you tested it.

## License

By contributing, you agree that your contributions are licensed under the [MIT License](LICENSE).
