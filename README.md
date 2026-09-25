# Memlib

A sticker and GIF library for Windows and Android. The library editor handles importing, folders, favourites and search. On Windows, **Ctrl+Alt+V** opens a frameless popup; type to search, use arrow keys to move, press Enter to paste, or Escape to dismiss. Selecting an item attempts to restore the previously focused input and paste into it. Clicking elsewhere closes the popup. Android currently provides the library and clipboard copy; a keyboard/IME is the next platform milestone.

When the Windows window is hidden, use the Memlib tray icon to reopen the library or launch the picker. The tray menu also has an Exit action.

## Run locally

1. Install Flutter and platform toolchains.
2. Run `flutter pub get`.
3. Run `flutter run -d windows` or `flutter run -d android`.

The local library lives under the app support directory. Imported files are copied into app storage, so moving the original files does not break the library.

## Optional service configuration

Create a Supabase project, then apply [`supabase/migrations/0001_library.sql`](supabase/migrations/0001_library.sql) in its SQL editor. The app accepts the URL and **publishable** key through Dart defines:

```powershell
flutter run -d windows --dart-define=SUPABASE_URL=https://YOUR_PROJECT.supabase.co --dart-define=SUPABASE_PUBLISHABLE_KEY=YOUR_PUBLISHABLE_KEY
```

The schema is ready for private syncing, but the client currently uses local storage only. Do not place a Supabase service role key in the app. Authentication and sync still need to be connected after the project is created.

If you already have a `.env` file containing `NEXT_PUBLIC_SUPABASE_URL` and `NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY`, use `./tool/run.ps1 -Device android` (or `windows`). The script passes only those public values and optional GIPHY keys to Flutter. `.env` is ignored by Git.

GIPHY search uses a separate API key for each platform:

```powershell
flutter run -d windows --dart-define=GIPHY_WINDOWS_KEY=YOUR_KEY
flutter run -d android --dart-define=GIPHY_ANDROID_KEY=YOUR_KEY
```

GIPHY results are displayed in their own view with attribution. The app fetches a selected GIF to copy it, and does not store GIPHY media in the library. GIPHY beta keys currently allow 100 API calls per hour. Review their current API terms before release.

## Next milestones

1. Supabase sign-in, sync, and conflict handling with the local cache retained for fast picker opening.
2. Android keyboard with rich GIF/sticker insertion, plus a share target for apps that do not accept rich keyboard content.
3. Pinterest OAuth import after Pinterest approves API access. Map board/Pins to folders and preserve source attribution.
4. Optional live GIF search providers. KLIPY advertises unlimited production requests after approval, while its test key has 100 calls/hour; its terms prohibit storing its media in a user collection. Keep provider search separate from imported library items.
5. Windows startup/tray integration, editable shortcut, and testing paste behavior across target apps.

## Current limits

The Windows paste uses an image clipboard entry for PNG files, a file clipboard entry for other formats, and simulated Ctrl+V. A target app may accept an image, animated GIF file, or neither depending on its editor. The selected item remains on the clipboard when automatic paste cannot complete. The Android app copies a media file URI to the clipboard, but cannot insert it directly into another app until the keyboard is implemented. GIPHY selections use a temporary transfer file, deleted after an hour when the app next copies GIPHY media.

Windows builds require Visual Studio's **Desktop development with C++** workload, MSVC build tools, CMake tools, and Windows SDK. Run `flutter doctor -v` to check the local installation.
