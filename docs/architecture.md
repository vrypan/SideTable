# Architecture and implementation limits

[Documentation](README.md) · [SideTable](../README.md)

`Sidetable/` contains the native application, feature views, and platform integrations. `Packages/ApronCore/` contains the independent wire models, reducer, transport, session, fixtures, and probe. App and UI tests live in `SidetableTests/` and `SidetableUITests/`. Design and implementation plans stay under [`plans/`](../plans/001-macos-client-design.md).

## Branding

The app and Dock icon use `Sidetable/Resources/SideTable.icns`, copied directly from `brand/SideTable-Brand-Kit-v2/apps/macos/SideTable.icns`. The v2 icon uses an espresso-brown (`#3B2118`) symbol on golden yellow (`#FFD23F`), with transparent outer margins and reinforced artwork at small sizes. Follow the [v2 brand guide](../brand/SideTable-Brand-Kit-v2/guide/SideTable-Brand-Guide-v2.md) for future updates. To repackage the supplied PNGs, run `iconutil -c icns brand/SideTable-Brand-Kit-v2/apps/macos/SideTable.iconset -o Sidetable/Resources/SideTable.icns`. Its bundle setting is maintained in `project.yml`; regenerate the Xcode project after changing that configuration. `assets/SideTable-dark.svg` is the previous monochrome variant and is no longer used by the app.


## Implementation limits

This is an initial working client, not complete web-client parity. Native passkeys, remote push/APNs, streaming/HTML embeds, Markdown tables/extensions, syntax highlighting, and multiple accounts on one endpoint are not implemented. CommonMark blocks render natively. Parsing is limited to 64 KiB of input, 32 levels of nesting, and 4,096 nodes; over-limit content falls back to bounded plain text, with the full source available through Copy Text. Uploads are session-only: quitting stops transfers. Retry Same Operation retains files when acknowledgement is lost. Upload links are single-use, so an interrupted PUT offers Reattach to Composer rather than silently resending the message. Retry Upload is available only for a failure before any network transfer. A successful PUT waits for the server’s attachment snapshot; cancelling locally does not delete the message.

Attachment downloads are limited to 64 MiB and automatic image downloads to 8 MiB. Composer website previews use macOS Link Presentation, with a ten-second metadata timeout, at most three concurrent links, and downsampled images held in memory for the active draft. The system manages those downloads; SideTable retains and decodes image representations only up to 8 MiB. A parallel, ephemeral HTTP request reads at most 1 MiB of page HTML, following HTTP(S) redirects without cookies or stored credentials. The system libxml2 HTML parser extracts OpenGraph tags without executing scripts or loading external resources. Available `og.image` URLs and image attributes accompany outgoing link embeds as hints for the server to proxy or replace; image bytes are not submitted. Attachment media loading is restricted to the server’s origin and its declared media origins. Cached files can be displayed without another download. See [usage and storage](usage.md) for cache behavior.

History starts with a recent page and loads older pages on demand, while the transcript reveals messages in batches of 150. Very large logs still need further profiling. UI automation and public native connectivity are environment-dependent; see the recorded verification results in [the implementation status](../plans/003-implementation-status.md).
