![SideTable](assets/readme-header.svg)

A native macOS client for [Apron](https://github.com/shazow/apron), with rooms, threads, Markdown, inline images, and file sharing.

## Install

Requires **macOS 14 or later**, on Apple silicon or Intel.

1. Download the universal `.dmg` from the [latest release](https://github.com/vrypan/SideTable/releases/latest).
2. Open it and drag **SideTable** into **Applications**.
3. Launch SideTable and click **Add Server** to connect to your Apron server.

Updates are available through **SideTable > Check for Updates…**. Automatic checks can be changed in **Settings > General > Updates**.

## Use

Enter your server’s hostname or WebSocket URL and choose one of its sign-in methods. You can try `wss://server.apron.chat/` as a guest. Posting and other actions depend on the server’s permissions.

- **Return** sends; **Shift-Return** adds a line break.
- **⌘K** switches conversations; **⌘F** searches loaded messages.
- Hover over or right-click a message to reply, react, start a thread, or copy its link.
- **File > Open Link…** (**⌘L**) opens shared Apron links.
- Click an image or choose **Preview** on a file to open Quick Look.
- **Settings > Storage** lets you clear saved conversations and downloaded media.

Closing the last window keeps SideTable connected; choose **Quit** to disconnect. Sign-in tokens are stored in Keychain. Apron messages are not end-to-end encrypted.

See the [usage guide](docs/usage.md) for connection options, threads, attachments, and storage details.

## More

[Release notes](Changelog.md) · [Development](docs/development.md) · [Documentation](docs/README.md) · [Third-party notices](THIRD_PARTY_NOTICES.md)
