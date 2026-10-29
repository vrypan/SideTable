# Apron Extensions

Extensions add features that [PROTOCOL.md](PROTOCOL.md) does not define. This
document collects extensions in common use, so that clients and servers that
do not know each other can agree on them. PROTOCOL.md wins where the two
disagree.

- A section's heading is the capability that the server advertises.
- Clients use an extension only while the latest `server` frame lists its
  capability, unless its section says otherwise.
- An extension keeps its data under its name in `ext`
  ([§4.12](PROTOCOL.md#412-ext)).
- Clients ignore a field whose value has the wrong type, and use its default.
- Each section says what clients do without the extension.

## `ext:settings`

Adds server-wide settings to the `server` frame, so that clients offer only the
controls that work. What each user may do is in
[`ext:permissions`](#extpermissions).

```json
"ext": {"settings": {"read_cursors": false, "private_rooms": 10}}
```

```ts
class Settings {                  // server.ext.settings
  read_cursors?: boolean = true;  // the server keeps read_message_id
  private_rooms?: number;         // the most private rooms a user may be a member of
}
```

- `read_cursors: false` means that the server ignores `read_message_id`
  ([§4.6](PROTOCOL.md#46-activity)). Clients then send none.
- `private_rooms` counts the private rooms
  ([§4.2.4](PROTOCOL.md#424-creating-and-editing)) without a
  `parent_room_id`. Absent, there is no limit.
- Clients do not offer to create or join a private room past the limit.

## `ext:limits`

Adds a category, `data.ext.limits`, to `retry_after` errors
([§1.1](PROTOCOL.md#11-envelope-and-replies)), so that clients hold back every
request that the same limit counts, rather than send each one to be refused.

```json
{"id": "c42", "error": {"code": -32002, "message": "Posting limit reached", "data": {"retry_after": 40, "ext": {"limits": "write"}}}}
```

| category | the limit counts                                                                       | clients hold back                  |
|----------|----------------------------------------------------------------------------------------|------------------------------------|
| `read`   | `history` or `room_list`                                                               | the refused method                 |
| `write`  | `message`, `reactions`, `room_join`, `room_leave`, and `room_set`                      | every request that `write` counts  |
| `upload` | `message` and `command` requests with a new `upload` embed ([§4.8.2](PROTOCOL.md#482-embed-identity)) | every request that `upload` counts |

- The server sends a category only on a request that its row counts.
- The server sends `write` or `upload` only for a limit that counts every
  request in its row.
- `write` does not count `command`, because a command can do anything.
- Until the delay ends, clients hold back what the last column lists.
- Without a category that they know and that counts the refused request,
  clients handle the error as PROTOCOL.md does.

## `ext:media`

Adds the server's media origins and file limits to the `server` frame, so
that clients load media from them and fit a file before they upload it.

```json
"ext": {"media": {
  "origins": ["https://media.chat.example"],
  "upload": {"image/*": {"max_bytes": 5242880, "max_side": 2048}, "audio/*": {"max_bytes": 10485760}},
  "avatar": {"image/*": {"max_bytes": 262144, "max_side": 512}},
  "emoji": {"image/png": {"max_bytes": 262144}, "image/gif": {"max_bytes": 262144}}
}}
```

```ts
class Media {                     // server.ext.media
  origins?: string[];             // other origins that serve the server's media
  upload?: {[pattern: string]: Limits};  // files for upload embeds (§4.8.4)
  avatar?: {[pattern: string]: Limits};  // images for avatars (§4.8.6)
  emoji?: {[pattern: string]: Limits};   // images for custom emoji (ext:emoji)
}

class Limits {
  max_bytes?: number;             // the largest file, in bytes
  max_side?: number;              // the longest image side, in pixels, after the server scales it down
}
```

- An origin is `scheme://host[:port]`. It is `https:`, or `http:` on a
  loopback host. Clients ignore other entries.
- Clients MAY load the `og` media
  ([§4.8.1](PROTOCOL.md#481-opengraph-metadata-og)) of the server's content
  from `origins`.
- A pattern is a MIME type, `type/*`, or `*/*`. Patterns and types match
  without regard to case.
- A file takes only the `Limits` of its most specific pattern. Limits do not
  combine across patterns.
- The server accepts only the types that match a pattern. A pattern whose
  `Limits` is `{}` accepts its types without a limit.
- A file's type is the `Content-Type` of its write
  ([§4.8.3](PROTOCOL.md#483-writes)).
- The server refuses a write over `max_bytes` with HTTP 413, and a type that
  it does not accept with HTTP 415.
- The server scales a larger image down to `max_side`. Clients MAY scale it
  down before they upload it.
- Without `upload`, `avatar`, or `emoji`, clients apply no limits to those
  files.
- Without the extension, clients load media only from the server's origin,
  and apply no limits.

## `ext:permissions`

Adds the user's permissions to `you` ([§3.3](PROTOCOL.md#33-identity)), so
that clients offer only the controls that the user may use. Roles
([§3.3.4](PROTOCOL.md#334-roles)) are labels only, so clients cannot learn
permissions from them.

```jsonc
// a guest who only reads
"you": {"user_id": "guest_1234", "name": "Guest", "ext": {"permissions": {"write": false}}}
// an admin
"you": {"user_id": "ada", "name": "Ada", "roles": ["admin"], "ext": {"permissions": {"add_members": true, "move_any": true}}}
```

```ts
class Permissions {               // you.ext.permissions
  write?: boolean = true;         // may send the requests of the write row of ext:limits
  add_members?: boolean = false;  // may send room_join with a user_id, in any room
  move_any?: boolean = false;     // may move other users' messages
}
```

- An absent key takes its default.
- Without the extension, clients offer what PROTOCOL.md allows, and handle
  `denied`. They offer to move only the user's own messages.
- `write` refers to the requests that the `write` row of
  [`ext:limits`](#extlimits) lists.
- `add_members` refers to `room_join` with a `user_id`
  ([§4.2.2](PROTOCOL.md#422-membership)). When it is `false`, clients offer
  to add users only to the private rooms that the user is a member of
  ([§4.2.4](PROTOCOL.md#424-creating-and-editing)).
- `move_any` refers to moves ([§4.4](PROTOCOL.md#44-edit)). When it is
  `false`, clients offer to move only the user's own messages.
- The server ignores `ext.permissions` in a `me` request.

## `ext:bio`

Adds a short bio to user objects ([§3.3](PROTOCOL.md#33-identity)), such as
what the user works on.

```json
{"method": "me", "id": "c60", "params": {"ext": {"bio": "Counts things.\nMostly engines."}}}
```

- Clients set the user's `bio` with `me` ([§3.3.2](PROTOCOL.md#332-profile)).
- A server with capability `ext` keeps `bio` like any other key, so clients
  also use the extension with `ext`.
- Clients send at most 250 Unicode code points. `\n` is a line break.
- Clients send no control characters other than `\n`.
- Clients show a bio as plain text, never as CommonMark or HTML.
- Without the extension or capability `ext`, clients send no `bio`.

## `ext:emoji`

Adds custom emoji: images that the server defines, and that users write as
`:name:` in reactions and text. The `server` frame carries the URL of the
catalog, a JSON object keyed by that string, so that clients fetch it only
when they need it. Without the extension, clients show a key in text as
written, and in reactions as a placeholder ([§4.7](PROTOCOL.md#47-reactions)).

```jsonc
// <- the server frame
{
  "method": "server", "params": {
    "apron": 9, "auth": ["token"], "capabilities": ["reactions", "ext:emoji"],
    "ext": {"emoji": {"catalog_url": "https://chat.example/e/catalog-7f3a9c.json"}}
  }
}
// GET https://chat.example/e/catalog-7f3a9c.json returns the catalog
{
  ":partyparrot:": {"url": "https://chat.example/e/Qm7x…", "static_url": "https://chat.example/e/Qm7x…/still", "category": "Parrots", "tags": ["party", "celebrate"]},
  ":shipit:": {"url": "https://chat.example/e/Zr8T…", "width": 64, "height": 32, "alt": "Squirrel in a hat"}
}
// -> a reaction
{"method": "reactions", "id": "c17", "params": {"message_id": "1724803200043", "emojis": ["👍", ":partyparrot:"]}}
// -> text
{"method": "message", "id": "c18", "params": {"room_id": "general", "body": {"text": "Shipped :partyparrot:"}}}
```

```ts
class EmojiExt {                // server.ext.emoji
  catalog_url: string;          // the catalog: an object that maps each key to an Emoji
}

class Emoji {                   // catalog[":name:"]
  url: string;                  // the image
  alt?: string;                 // hover and screen reader text; absent: the key
  width?: number;               // with height, the aspect ratio
  height?: number;
  static_url?: string;          // a still copy of an animated image
  category?: string;            // groups the picker
  tags?: string[];              // more words to search by, in any language
  hidden?: boolean = false;     // rendered, but not offered in the picker
}
```

### Catalog

- A key is `:`, a name, and `:`. A name is one or more of `[A-Za-z0-9_+-]`.
- Keys are case-sensitive.
- `catalog_url` is an `https:` URL, an `http:` URL on a loopback host, or a
  `data:application/json` URL.
- The server changes `catalog_url` when the catalog changes, and sends a new
  `server` frame ([§3.1](PROTOCOL.md#31-server-frame)).
- Clients MAY keep a catalog for as long as `catalog_url` stays the same.
- Clients fetch the catalog when they first need it, such as to show a picker
  or a key. Until they have it, they show keys as without the extension.
- A server that keeps its emoji private sends `ext.emoji` only after sign-in,
  with an unguessable `catalog_url`
  ([§4.8.2](PROTOCOL.md#482-embed-identity)).
- Clients use `width` and `height` together as the aspect ratio. When either
  is absent, the emoji is square.
- A server MAY keep a removed or renamed key as `hidden`, so that earlier
  reactions and text keep their image.
- `url` and `static_url` follow the rules for user avatars
  ([§4.8.6](PROTOCOL.md#486-avatars)).
- Clients SHOULD scale an emoji in text to the height of the line.
- Clients MAY show `static_url` in place of `url`, such as when the user
  prefers reduced motion.

### Reactions

- A `reactions` entry ([§4.7](PROTOCOL.md#47-reactions)) that is a key refers to
  that custom emoji.
- The server MAY refuse a key that the catalog does not have. It MUST accept
  such a key when the user's current set on that message already has it (a
  request carries the whole set, so a removed emoji would otherwise stop the
  user from changing their other reactions).
- Clients show a key that the catalog has as its image, with `alt` or the key
  as its hover text.

### Text

- Clients render a key as its image when the catalog has it, in `body.text`
  and in the fields that PROTOCOL.md calls CommonMark
  ([§3.5.2](PROTOCOL.md#352-rendering)), such as a room's `description` and
  `server.welcome`. Other text stays as written.
- Clients scan from left to right. At each `:`, if the text up to the next
  `:` forms a key that the catalog has, clients render it and continue after
  it. Otherwise they continue at that next `:`. So keys can be adjacent, such
  as `:party-left::party-right:`, and `12:30:partyparrot:` renders
  `:partyparrot:`.
- Keys in CommonMark code spans and code blocks stay text.
- Composers put a space between a mention and a key (a mention can contain
  `:`, [Appendix A.3](PROTOCOL.md#a3-prefixes-in-text)).

### Managing

Suggested convention, with capabilities `command` and `embed:upload`
([§4.1](PROTOCOL.md#41-command), [§4.8.3](PROTOCOL.md#483-writes)):

- `/emoji add :name:` with one `upload` embed adds the file as that key, or
  replaces its image.
- `/emoji remove :name:` removes the key.
