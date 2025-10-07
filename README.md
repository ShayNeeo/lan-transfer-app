# Local Share

[![Android APK Builds](https://github.com/ShayNeeo/lan-transfer-app/actions/workflows/android-apk-build.yml/badge.svg)](https://github.com/ShayNeeo/lan-transfer-app/actions/workflows/android-apk-build.yml)
[![Flutter](https://img.shields.io/badge/Flutter-3.24.0-blue.svg)](https://flutter.dev/)
[![Dart](https://img.shields.io/badge/Dart-3.0+-blue.svg)](https://dart.dev/)
[![Platform](https://img.shields.io/badge/Platform-Android-green.svg)](https://developer.android.com/)
[![License](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

Small Flutter app (LAN upload / transfer) — Android build/release pipeline included.

## What this repo contains

- Flutter app source under `lib/`
- Android native project under `android/`
- GitHub Actions workflow at `.github/workflows/android-apk-build.yml` that:
  - Runs format check, analysis, and builds per-ABI release APKs.
  - Uploads the three ABI APKs as artifacts on every push to `main`.
  - Automatically publishes a GitHub Release (and attaches the APKs) when you push a version tag matching `v*.*.*` (for example `v1.0.1`).

---

## Quick start (local)

Prerequisites:
- Flutter SDK (this repo's workflow uses Flutter 3.24.0).
- Android SDK with platform 35, build tools 35.0.0 and NDK 27.x for release builds (see Troubleshooting).
- Java 17.

Common commands:

Install dependencies:
```bash
flutter pub get
```

Format and analyze:
```bash
dart format .
flutter analyze
```

Run on device (debug):
```bash
flutter run
```

Build split release APKs locally:
```bash
flutter build apk --release --split-per-abi
# Output APKs will be in build/app/outputs/flutter-apk/
```

---

## CI / CD (GitHub Actions)

Workflow location: `.github/workflows/android-apk-build.yml`

Triggers:
- Pushes to `main` will run the build job.
- Pushing a tag that matches `v*.*.*` (example `v1.0.1`) will:
  1. Run the build (same as above),
  2. Then run the `publish-release` job which attaches the three ABI APKs to a GitHub Release named after the tag.

Notes:
- The workflow currently ignores README-only changes (so editing `README.md` alone won't re-run the build).
- Workflow uses Flutter 3.24.0 on `ubuntu-latest` and installs Android SDK platform 35, build-tools 35.0.0 and NDK 27.0.12077973 in CI.

How to create a release (recommended):
1. Commit and push your changes to `main`:
   ```bash
   git add .
   git commit -m "Describe your changes"
   git push
   ```
   (This will run the build job — helpful so you know it passes before tagging.)
2. Create an annotated tag that will be used as the Release title/message:
   ```bash
   git tag -a v1.0.1 -m "release v1.0.1"
   git push origin v1.0.1
   ```
   Pushing the tag triggers the workflow that will publish a GitHub Release and attach the APKs.

If you want the release to be a draft (review before publishing), edit the workflow and set `draft: true` in the `softprops/action-gh-release` configuration.

---

## Signing the release APKs

This repo does not include any keystore or signing keys. To produce a signed release (recommended for Play Store/uploading):

1. Generate an Android keystore (example):
   ```bash
   keytool -genkey -v -keystore ~/my-release-key.jks -alias app-key -keyalg RSA -keysize 2048 -validity 10000
   ```
2. Do NOT commit your keystore or `key.properties`. Add them to [`.gitignore`](.gitignore ) (the repo already ignores signing artifacts).
3. Locally, set up `android/key.properties` with secure values:
   ```
   storePassword=<your-store-password>
   keyPassword=<your-key-password>
   keyAlias=app-key
   storeFile=/absolute/path/to/my-release-key.jks
   ```
4. To sign in CI, store your keystore as an encrypted secret and modify the workflow to:
   - Upload keystore into the runner at runtime (from `secrets`),
   - Provide `key.properties` values via secrets (or create the file from secrets),
   - Add Gradle signing configs that read `key.properties`.

If you'd like, I can add a template CI step to handle secure keystore injection (requires you to create secrets in the repo).

---

## Troubleshooting

- R8 / missing classes (e.g., SplitCompatApplication): ensure [`android/app/build.gradle.kts`](android/app/build.gradle.kts ) uses `compileSdk = 35` and the appropriate `ndkVersion = "27.0.12077973"` when plugins request newer SDK/NDK.
- CI failing to install Android SDK tools: the workflow calls the SDK manager from `${ANDROID_SDK_ROOT}/cmdline-tools/latest/bin/sdkmanager`.
- Formatter or analyzer failures: run `dart format .` and `flutter analyze` locally to see and fix reported issues.
- Permission error when publishing releases (HTTP 403): workflow needs `permissions: contents: write` at the job or workflow level — this repository’s workflow already sets that for the `publish-release` job.

---

## Where to find build outputs

- CI artifacts (if you run the build on GitHub Actions): open the workflow run → Jobs → `build-release-splits` → Artifacts. The three artifacts are named:
  - `release-arm64-v8a`
  - `release-armeabi-v7a`
  - `release-x86_64`

- GitHub Release: when you push a version tag (e.g. `v1.0.1`) the `publish-release` job creates a Release and attaches the three APKs. Visit: `https://github.com/<your-username>/lan-transfer-app/releases`.

---

## Contributing / PRs

- Open a branch, create a PR against `main`.
- CI runs on PRs targeting `main`. Only push tags to create Releases.

---

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
