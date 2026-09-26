# Memlib

A sticker and GIF library for Windows and Android. The library editor handles importing, folders, favourites and search. On Windows, **Ctrl+Alt+V** opens a frameless popup by default; type to search, use arrow keys to move, press Enter to paste, or Escape to dismiss. Selecting an item attempts to restore the previously focused input and paste into it. Clicking elsewhere closes the popup. Use Settings in the library toolbar to change the global shortcut or enable launch at sign-in. On Android, enable the Memlib keyboard to insert library items or GIPHY results from a text field in another app.

When the Windows window is hidden, use the Memlib tray icon to reopen the library or launch the picker. The tray menu also has an Exit action. Launch at sign-in is off by default; when enabled, Memlib starts in the tray without opening the library window.

## Run locally

1. Install Flutter and platform toolchains.
2. Run `flutter pub get`.
3. Run `flutter run -d windows` or `flutter run -d android`.

The local library lives under the app support directory. Imported files are copied into app storage, so moving the original files does not break the library. On Windows, drag PNG, GIF, JPEG, or WebP files from Explorer into the library window, or copy those files in Explorer and press Ctrl+V while the library window is focused. They import into the selected folder; normal text pasting in search fields still works.

## Supabase sign-in and sync

Create a Supabase project, then apply [`supabase/migrations/0001_library.sql`](supabase/migrations/0001_library.sql), [`supabase/migrations/0002_item_source.sql`](supabase/migrations/0002_item_source.sql), and [`supabase/migrations/0003_source_identity.sql`](supabase/migrations/0003_source_identity.sql) in its SQL editor, in that order. Apply only migrations you have not already run. The app accepts the URL and **publishable** key through Dart defines:

```powershell
flutter run -d windows --dart-define=SUPABASE_URL=https://YOUR_PROJECT.supabase.co --dart-define=SUPABASE_PUBLISHABLE_KEY=YOUR_PUBLISHABLE_KEY
```

Open **Sign in** in the library toolbar to create an account or sign in with email and password. If email confirmation is enabled in Supabase, confirm the message first, then sign in. The app opens the account's local cache immediately and syncs folders, favourites, item details and media in the background. The account menu shows sync status and offers **Sync now** and **Sign out**. Files are stored in the private `library-media` bucket under the user's ID; the migration sets row and storage access policies. Keep the service role key out of the app.

Your pre-sign-in library remains on this device as a guest library. After signing in, choose **Import local library** in the account menu to copy it into the account and upload it. Repeating the import skips items already copied from that guest library. Signed-in libraries also remain cached on the device after sign-out for offline access when that account signs in again. If two devices edit the same item or folder while disconnected, the library shows **Use cloud** and **Keep device** choices; it does not silently overwrite either edit. Sync errors can be retried from the banner or account menu.

If you already have a `.env` file containing `NEXT_PUBLIC_SUPABASE_URL` and `NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY`, use `./tool/run.ps1 -Device android` (or `windows`). The script passes those public values, optional GIPHY keys, and the optional GIPHY save permission flag to Flutter. `.env` is ignored by Git.

GIPHY search uses a separate API key for each platform:

```powershell
flutter run -d windows --dart-define=GIPHY_WINDOWS_KEY=YOUR_KEY
flutter run -d android --dart-define=GIPHY_ANDROID_KEY=YOUR_KEY
```

GIPHY results are displayed in their own view with attribution, including inside the Windows quick picker and Android keyboard. Search is submitted explicitly to conserve API calls, and more results can be loaded on demand. Choosing a result copies or inserts it. The app sends GIPHY's view, click, and send analytics events. GIPHY beta keys currently allow 100 API calls per hour.

GIPHY library saving and favouriting are implemented but **disabled until you have GIPHY approval**. Once approved, set `GIPHY_LIBRARY_SAVES_ENABLED=true` in your local `.env` and add a repository Actions **variable** with that name and value for signed builds. The save button adds a result to the selected folder; the star adds it to favourites or toggles an already saved result. Each item stores `sourceType` and `sourceId` independently of its source page and file path; GIPHY uses its stable result ID to avoid importing the same result twice, even if its page URL changes. These fields sync through Supabase. Android keyboard save and star actions queue the selected GIF and finish importing it when Memlib next opens.

## Android keyboard and sharing

Open the keyboard icon in Memlib, choose **Set up keyboard**, and enable **Memlib stickers** in Android settings. In another app's text field, switch to the Memlib keyboard. Browse folders or favourites, search your library, or use the GIPHY tab. Tap an item to insert it into an editor that accepts image content. If that editor does not accept images from keyboards, Memlib copies the media URI to the clipboard; long-press the tile to open Android's share sheet. Use **ABC** for basic text entry and the globe button to return to another keyboard.

Android can receive images shared from another app, including multiple images, and imports them into the selected folder. You can also use **Import files** or the keyboard icon's **Import image from clipboard** option in the main app. The Android keyboard reads the local library cache, so signed-in folders, favourites, and synced files remain available offline.

## Next milestones

1. Test Android keyboard insertion, fallback sharing, and image imports on a physical device across target apps.
2. Pinterest OAuth import after Pinterest approves API access. Map board/Pins to folders and use each Pin ID as the source identity to skip items already imported.
3. Test Windows focus restoration and paste behavior across target apps, then package the Windows app for installation.

## Current limits

The Windows paste uses an image clipboard entry for PNG and JPEG files, a file clipboard entry for GIF and WebP files, and simulated Ctrl+V. A target app may accept an image, animated GIF file, or neither depending on its editor. The selected item remains on the clipboard when automatic paste cannot complete. Android insertion depends on the target editor declaring support for the image MIME type; other editors need the clipboard or share sheet. GIPHY selections use a temporary transfer file, deleted after an hour when the app next copies GIPHY media.

Windows builds require Visual Studio's **Desktop development with C++** workload, MSVC build tools, CMake tools, and Windows SDK. Run `flutter doctor -v` to check the local installation.

## Signed CI builds

The [GitHub Actions workflow](.github/workflows/signed-builds.yml) runs analysis and tests on pushes to `develop` and pull requests to `master`. Each push to `master` also builds a signed Windows ZIP and signed Android APK and App Bundle; the artifacts remain downloadable from that workflow run for 30 days. It can also be started manually. Development happens on `develop`, and merging a completed feature into `master` triggers the signed builds.

The permanent Android upload keystore and Windows signing PFX were generated locally in `%USERPROFILE%\.memlib-signing`, outside this Git repository. Keep an offline backup of this directory; losing the Android key can prevent future updates signed with the same identity. The Android application ID is `com.sheepkill15.memlib`. The Windows certificate is self-signed for development: the EXE is Authenticode signed, but other Windows machines will not trust its publisher until you replace the PFX with a certificate from a trusted code-signing provider. The workflow accepts a replacement PFX using the same secret names.

Add these **repository Actions secrets** under GitHub Settings → Secrets and variables → Actions before merging the workflow into `master`:

| Secret | Local source |
| --- | --- |
| `ANDROID_KEYSTORE_B64` | `%USERPROFILE%\.memlib-signing\upload-keystore.base64.txt` |
| `ANDROID_KEYSTORE_PASSWORD` | `androidKeystorePassword` in `%USERPROFILE%\.memlib-signing\credentials.json` |
| `ANDROID_KEY_PASSWORD` | `androidKeyPassword` in the same credentials file |
| `WINDOWS_PFX_B64` | `%USERPROFILE%\.memlib-signing\memlib-code-signing.base64.txt` |
| `WINDOWS_PFX_PASSWORD` | `windowsPfxPassword` in the credentials file |
| `SUPABASE_URL` | `NEXT_PUBLIC_SUPABASE_URL` in `.env` |
| `SUPABASE_PUBLISHABLE_KEY` | `NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY` in `.env` |
| `GIPHY_WINDOWS_KEY` | `GIPHY_WINDOWS_KEY` in `.env` |
| `GIPHY_ANDROID_KEY` | `GIPHY_ANDROID_KEY` in `.env` |

The Base64 files contain private keys encoded as text; treat them like the keystores themselves. Neither keystore nor local passwords belong in Git. The local Android build reads the ignored `android/key.properties`. Windows CI signs the EXE and DLL files inside the ZIP and checks for Authenticode signatures. Android CI verifies the APK and App Bundle signatures before uploading artifacts.
