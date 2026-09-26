# Memlib

A sticker and GIF library for Windows and Android. The library editor handles importing, folders, favourites and search. On Windows, **Ctrl+Alt+V** opens a frameless popup by default; type to search, use arrow keys to move, press Enter to paste, or Escape to dismiss. Selecting an item attempts to restore the previously focused input and paste into it. Clicking elsewhere closes the popup. Use Settings in the library toolbar to change the global shortcut or enable launch at sign-in. Android currently provides the library and clipboard copy; a keyboard/IME is the next platform milestone.

When the Windows window is hidden, use the Memlib tray icon to reopen the library or launch the picker. The tray menu also has an Exit action. Launch at sign-in is off by default; when enabled, Memlib starts in the tray without opening the library window.

## Run locally

1. Install Flutter and platform toolchains.
2. Run `flutter pub get`.
3. Run `flutter run -d windows` or `flutter run -d android`.

The local library lives under the app support directory. Imported files are copied into app storage, so moving the original files does not break the library. On Windows, drag PNG, GIF, JPEG, or WebP files from Explorer into the library window, or copy those files in Explorer and press Ctrl+V while the library window is focused. They import into the selected folder; normal text pasting in search fields still works.

## Supabase sign-in and sync

Create a Supabase project, then apply [`supabase/migrations/0001_library.sql`](supabase/migrations/0001_library.sql) in its SQL editor. The app accepts the URL and **publishable** key through Dart defines:

```powershell
flutter run -d windows --dart-define=SUPABASE_URL=https://YOUR_PROJECT.supabase.co --dart-define=SUPABASE_PUBLISHABLE_KEY=YOUR_PUBLISHABLE_KEY
```

Open **Sign in** in the library toolbar to create an account or sign in with email and password. If email confirmation is enabled in Supabase, confirm the message first, then sign in. The app opens the account's local cache immediately and syncs folders, favourites, item details and media in the background. The account menu shows sync status and offers **Sync now** and **Sign out**. Files are stored in the private `library-media` bucket under the user's ID; the migration sets row and storage access policies. Keep the service role key out of the app.

Your pre-sign-in library remains on this device as a guest library. After signing in, choose **Import local library** in the account menu to copy it into the account and upload it. This action can be repeated, so each import creates another copy. Signed-in libraries also remain cached on the device after sign-out for offline access when that account signs in again. If two devices edit the same item or folder while disconnected, the library shows **Use cloud** and **Keep device** choices; it does not silently overwrite either edit. Sync errors can be retried from the banner or account menu.

If you already have a `.env` file containing `NEXT_PUBLIC_SUPABASE_URL` and `NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY`, use `./tool/run.ps1 -Device android` (or `windows`). The script passes only those public values and optional GIPHY keys to Flutter. `.env` is ignored by Git.

GIPHY search uses a separate API key for each platform:

```powershell
flutter run -d windows --dart-define=GIPHY_WINDOWS_KEY=YOUR_KEY
flutter run -d android --dart-define=GIPHY_ANDROID_KEY=YOUR_KEY
```

GIPHY results are displayed in their own view with attribution, including inside the Windows quick picker. Search is submitted explicitly to conserve API calls, and more results can be loaded on demand. Choosing a result copies it and, when opened from another app with the quick shortcut, attempts to paste it into the previous input. The app sends GIPHY's view, click, and send analytics events; it does not store GIPHY media in the library. GIPHY beta keys currently allow 100 API calls per hour. Review their current API terms before release.

## Next milestones

1. Android keyboard with rich GIF/sticker insertion, plus a share target for apps that do not accept rich keyboard content.
2. Pinterest OAuth import after Pinterest approves API access. Map board/Pins to folders and preserve source attribution.
3. Test focus restoration and paste behavior across target apps, then package the Windows app for installation.

## Current limits

The Windows paste uses an image clipboard entry for PNG and JPEG files, a file clipboard entry for GIF and WebP files, and simulated Ctrl+V. A target app may accept an image, animated GIF file, or neither depending on its editor. The selected item remains on the clipboard when automatic paste cannot complete. The Android app copies a media file URI to the clipboard, but cannot insert it directly into another app until the keyboard is implemented. GIPHY selections use a temporary transfer file, deleted after an hour when the app next copies GIPHY media.

Windows builds require Visual Studio's **Desktop development with C++** workload, MSVC build tools, CMake tools, and Windows SDK. Run `flutter doctor -v` to check the local installation.
