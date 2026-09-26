# Memlib Privacy Policy

**Effective September 26, 2026**

Memlib is a sticker and GIF library for Windows and Android developed by [sheepkill15](https://github.com/sheepkill15/MemLib). This policy explains what happens to information when you use the app, including its optional online features.

## Information Memlib handles

- **Your library:** Images and GIFs you import or save, folder names, item names, favorites, usage counts, and source details such as a provider's item ID or page URL.
- **Account information:** If you create a Memlib account, your email address and authentication information are handled by Supabase. Memlib uses your account ID to associate your library with you. The app does not store your password in its library files.
- **Search and interaction data:** A GIPHY search sends your query to GIPHY. When GIPHY results are displayed, selected, or sent, Memlib calls GIPHY's analytics URLs with a randomly generated identifier stored on your device and a timestamp. GIPHY and other network providers may also receive ordinary connection information, such as your IP address.
- **Images you share with Memlib:** The Android share and clipboard import features read the images you choose to provide. The Memlib keyboard reads your local library and sends selected media to the app where you insert or share it. Memlib does not transmit your typed text to its own server.

## How information is used

Memlib uses this information to organize and search your library, insert or share selected media, sign you in, synchronize your library across devices when you opt in to an account, and provide GIPHY search results. It does not sell your personal information or use your library for advertising.

## Local storage and optional cloud sync

Without an account, your library stays in the app's storage on your device. When you sign in, Memlib keeps a local cache and syncs your folders, item details, and media with Supabase. Uploaded media is kept in a private storage bucket with access rules tied to your account. Your guest library is not uploaded unless you choose **Import local library**. A signed-in library cache can remain on the device after sign-out so it is available when that account signs in again.

## Other services and sharing

Memlib uses [Supabase](https://supabase.com/privacy) for account authentication and optional cloud storage, and [GIPHY](https://support.giphy.com/hc/en-us/articles/360032872931-GIPHY-Privacy-Policy) for GIF search, media delivery, and the interaction events described above. When you insert or share an item into another app, that app receives the selected media and handles it under its own privacy policy. Memlib also displays or downloads media from source URLs you choose to use. These providers may process data in countries outside your own.

## Pinterest integration

Pinterest import is planned and is not available in the current app. If released, connecting a Pinterest account will be optional and will use Pinterest's authorization flow. Memlib will request only the access needed to read the boards and Pins you choose to import, and will use that information to create local library items and avoid duplicate imports. We will update this policy with the implemented permissions, token handling, and disconnect controls before that feature is released. Memlib will not ask for your Pinterest password.

## Retention and your choices

You can delete library items and folders in the app. Local data remains until you delete it or uninstall the app; signed-in data remains in Supabase until it is deleted or you request account deletion. Provider backups and logs may take additional time to expire under their retention policies. You can stop cloud sync by signing out, but this does not delete the cloud copy or the local cache. To request access to, correction of, export of, or deletion of your account data, open a [Memlib GitHub issue](https://github.com/sheepkill15/MemLib/issues/new). Do not post passwords, tokens, or other sensitive information in a public issue; we will arrange a private way to verify your request if needed. You may also have a right to complain to your local data protection authority.

## Security and children

Memlib uses HTTPS for its online services and account-based access controls for synced library data. No service can guarantee absolute security. Memlib is not designed for children under 13, and we do not knowingly collect their personal information.

## Changes and contact

We may revise this policy as Memlib changes. The effective date above will be updated when material changes are published. For privacy questions or requests, use the [Memlib GitHub issue tracker](https://github.com/sheepkill15/MemLib/issues/new).
