# Browser link integration

[Back to documentation](README.md)

SideTable registers two native URL schemes:

```text
sidetable://open?server=wss://server.apron.chat/&room=general
apron:?server=wss://server.apron.chat/&room=general
```

Both use Apron's form-encoded `server`, `room`, `message`, and `user` parameters. A message needs a room. Incoming URLs targeting the current server navigate directly. Links to another server open destination review; choose Open to proceed. File > Open Link still offers Continue after you paste or type a URL. They do not connect to a new server before review. Sign-in tokens are accepted only in the standard HTTPS link format, not through custom schemes.

Validated `apron:`, `sidetable:`, and standard Apron HTTPS links inside messages and thread descriptions navigate directly when they target the source server. Links to another server, and all invite/sign-in links, open destination review. Links without `server`, such as `apron:?room=ops`, use the server that supplied the message or description. The source pane determines this address even if another server is selected in the sidebar. Ordinary HTTP/HTTPS links still open in the browser.

Install and launch the updated app to make it available to macOS as a handler. To test a local build explicitly:

```sh
open -a "$PWD/build/Build/Products/Debug/SideTable.app" 'sidetable://open?server=wss://server.apron.chat/&room=general'
```

## Opening shared HTTPS links

Keep sharing the standard `https://link.apron.chat/#server=…&room=…` links. Registering a custom scheme does not make SideTable the handler for that HTTPS domain.

The current [Apron link chooser](https://github.com/apron-chat/link.apron.chat#adding-a-client) offers **Open in an installed app** using `apron:` when its registry contains a native app for the visitor's platform. Its saved default and automatic redirect options currently apply to web clients. It does not currently support an app-specific `sidetable:` redirect.

To expose the installed-app option for desktop visitors, submit this entry to the upstream `clients.json` registry after publishing a SideTable release that includes the URL handlers:

```json
{
  "id": "sidetable",
  "name": "SideTable",
  "description": "A native macOS client for Apron.",
  "homepage": "https://github.com/vrypan/SideTable",
  "source": "https://github.com/vrypan/SideTable",
  "transports": ["wss", "ws"],
  "desktop": {
    "download": "https://github.com/vrypan/SideTable/releases/latest"
  }
}
```

The upstream entry must be accepted and deployed before the site offers it. If multiple installed apps register `apron:`, macOS chooses its handler; `sidetable:` targets SideTable specifically. An **Open in SideTable** button using that scheme would require support in the chooser itself.

Direct HTTPS opening via Universal Links is a separate integration requiring Apple's associated-domains entitlement in the signed app and authorization from the domain through its `apple-app-site-association` file. SideTable does not configure that integration yet.
