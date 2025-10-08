# Local Share

[![Android APK Builds](https://github.com/ShayNeeo/localshare/actions/workflows/android-apk-build.yml/badge.svg)](https://github.com/ShayNeeo/localshare/actions/workflows/android-apk-build.yml)
[![Flutter](https://img.shields.io/badge/Flutter-3.24.0-blue.svg)](https://flutter.dev/)
[![Dart](https://img.shields.io/badge/Dart-3.0+-blue.svg)](https://dart.dev/)
[![Platform](https://img.shields.io/badge/Platform-Android-green.svg)](https://developer.android.com/)
[![License](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

Small Flutter app (local file sharing) — Android build/release pipeline included.

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

## Website / Landing page

This repository includes a small, static landing page for Local Share located in the `webpage/` folder. The site provides a quick introduction to the app and direct links for users to download the Android APK from the project's GitHub Releases. iOS support is marked "Coming soon." The website is intentionally styled in a black-and-white, retro look.

What users will find on the landing page:
- Logo and project title
- Short introduction to Local Share
- Android download button (links to GitHub Releases)
- iOS button (Coming soon)

Preview the website locally (for contributors or curious users):

```bash
cd webpage
npm install
npm start
# open http://localhost:3000
```
# Local Share

Local Share is a simple, privacy-first app for transferring files between devices on the same local network. No accounts and no cloud storage — files are sent directly between devices on your LAN.

Key highlights
- Fast, local-only file transfers
- No account required, no sign-in
- Designed for ease: send/receive with a few taps

Download
- Android: APKs and releases available on GitHub Releases:
   https://github.com/ShayNeeo/localshare/releases/
- iOS: Coming soon

How to use (high level)
1. Install the Android app from Releases (or your device's Play Store if published).
2. Connect both devices to the same Wi‑Fi or local network.
3. Open Local Share, choose Send or Receive, and follow the on-screen instructions to transfer files.

Privacy & Security
- Transfers happen over your local network only. Files are not uploaded to any cloud service by the app.

Support
- Report bugs or request features via GitHub Issues:
   https://github.com/ShayNeeo/localshare/issues

License
- MIT — see the `LICENSE` file in this repository for details.

Thanks for trying Local Share!
   ```bash
