# Setup: your own MusicKit key and the token service

`am` works without a MusicKit key of its own: by default it uses the shared developer token from the
token service (section 6). This file covers the rest: signing your own developer token, the
playback browser, signing in, and running your own token service.

Order for your own key: 1 (key) → 3 (sign-in) → 4 (listen). Section 2 matters only if playback
fails.

`am` keeps its files in a config directory: `$XDG_CONFIG_HOME/am`, else `~/.config/am` (Linux,
macOS), or `%APPDATA%\am` (Windows). `AM_CONFIG_DIR` overrides it. The examples below use
`~/.config/am`.

---

## 1. MusicKit signing key (Apple Developer portal)

Apple Music needs a *developer token*, a short JWT that `am` signs with a private key from your
Apple Developer account. You create the key once; `am` never stores it, only the token it signs.

You need the **Account Holder** or **Admin** role on the developer team.

### 1a. Register a Media ID

1. Open <https://developer.apple.com/account/resources> (Certificates, Identifiers & Profiles).
2. In the sidebar, click **Identifiers**, then the **+** button at the top left.
3. Select **Media IDs** and click **Continue**.
4. **Description**: `am`.
   Apple shows this text as the *app name* when you grant `am` access to your Apple Music account, so keep it recognizable.
5. **Identifier**: a reverse-domain string, e.g. `media.com.example.am`. Any unique value works.
6. Enable **MusicKit**. ShazamKit and Apple Music Feed aren't needed.
7. Click **Continue**, then **Register**, then **Done**.

### 1b. Create the private key

1. In the same portal, click **Keys** in the sidebar, then **+**.
2. **Key Name**: `am-musickit` (anything unique).
3. Tick **Media Services (MusicKit, ShazamKit, Apple Music Feed)**.
   - If the checkbox is greyed out, the Media ID from 1a is missing.
   - If you have more than one Media ID, click **Configure** next to it, pick the `am` Media ID, and click **Continue**.
4. Click **Continue**, then **Confirm**.
5. Click **Download**. You get `AuthKey_<KEYID>.p8` in `~/Downloads`.
   > ⚠️ Apple lets you download the key **only once**. If you lose it, revoke it and create a new one (each Media ID allows two keys).
6. Note the **Key ID**: the 10-character string in the filename, also shown on the key's detail page.

### 1c. Find your Team ID

<https://developer.apple.com/account> → **Membership details** → **Team ID**: 10 characters, e.g. `AB12CD34EF`.

### 1d. Sign the developer token

Add the two IDs to the config directory's `env` file (this appends, so settings already in the
file stay). Replace `XXXXXXXXXX` (Key ID) and `YYYYYYYYYY` (Team ID) with your values:

```bash
mkdir -p ~/.config/am && chmod 700 ~/.config/am
printf 'TEAM_ID=YYYYYYYYYY\nKEY_ID=XXXXXXXXXX\n' >> ~/.config/am/env
chmod 600 ~/.config/am/env
```

Then pipe the key into `am`, which signs a developer token, stores it as
`~/.config/am/developer-token.jwt` and tests it against Apple:

```bash
am token --key-stdin < ~/Downloads/AuthKey_XXXXXXXXXX.p8
```

**Done when:** it prints `developer token signed: …` and Apple accepts the token. The key is never
printed or written anywhere.

The token is valid for about six months. `am` warns 14 days before it expires; sign a new one the
same way. Keep the `.p8` somewhere safe, such as a password manager, and pipe it in from there
next time. It doesn't need to stay in `~/Downloads`.

The Node prototype in `poc/` is the exception: it reads the key from a file, `KEY_PATH` in `env`
(default `~/.config/am/AuthKey_<KEY_ID>.p8`). Only keep the key there if you run the prototype.

### 1e. Optional, macOS: keep the key in the Keychain

On a Mac the key can live in a login-Keychain item named `am-musickit-p8`, base64-encoded. The item
trusts no app (`-T ""`), so every read asks in an Allow dialog. The key goes through a pipe, never
onto a command line. Replace `path/to/` with where the `.p8` is now:

```bash
printf 'add-generic-password -U -a am -s am-musickit-p8 -l "am MusicKit key" -T "" -w %s\n' \
  "$(base64 < path/to/AuthKey_XXXXXXXXXX.p8 | tr -d '\n')" | security -i
```

Then sign the developer token from it (click **Allow**, not **Always Allow**):

```bash
security find-generic-password -a am -s am-musickit-p8 -w | base64 -D | am token --key-stdin
```

---

## 2. Playback browser

`am` plays through Firefox by default, or Google Chrome with `ENGINE=chrome` in
`~/.config/am/env`. Either must be installed. It runs the browser as a separate hidden instance with
its own profile (`~/.config/am/firefox-profile` or `chrome-profile`), so your normal browser isn't
touched. Firefox downloads Google's Widevine module by itself on first use.

If Apple's licence server rejects the Widevine version Firefox got from Mozilla, `am play` fails
with `WIDEVINE_CDM_EXPIRED`. The first fix is `FIREFOX_WIDEVINE=google` in `~/.config/am/env`,
which makes Firefox fetch Google's current version. Chrome is the fallback after that.

`am doctor` starts the engine and reports DRM, MusicKit and sign-in status.

---

## 3. One-time Apple ID sign-in

```bash
am token     # checks the developer token: Apple must accept it
am signin    # opens a sign-in page in your normal browser
```

On the page, click **Sign in to Apple Music**. Then log in with your Apple ID and 2FA in Apple's own popup and allow access for "am".
Firefox may show a "This site requires DRM" bar on that page. You can ignore it: sign-in doesn't need DRM.
The terminal prints `✔ signed in` and stores the Music User Token in `~/.config/am/music-user-token` (mode 600, valid for about 6 months).
The playback engine reads it from there, so you never sign in inside the hidden browser.

---

## 4. Listen

```bash
am play --full    # 2:55 test track; watches it and verifies it's the full version
```

If you hear nothing, check that your system's audio output isn't muted.

---

## 5. The full-screen player

`am` with no arguments (or `am tui`) opens the player in the terminal: Home, Recently Played, your
library, Favorites, Radio, Charts, Search and Up Next, with playback, favorites and artwork. On
start it checks the developer token and your sign-in; when the Music User Token is missing or Apple
no longer accepts it, it opens the sign-in page in your browser by itself and waits. `?` lists the
keys.

- `Q` quits, stops the music and ends the background process (`am daemon`) and its engine, as
  `am daemon stop` does. That stops everything: also what another TUI or `am play` started.
- `q` (also Ctrl-C, closing the window, `kill`) quits and ends `am daemon` and its engine only
  if nothing else uses them: no music playing (live radio included), no song starting, no other
  TUI open, no other command running, no sign-in waiting. Otherwise, or when it can't tell, they
  keep running.
- Once nothing plays, the engine closes after 5 minutes (`ENGINE_IDLE_MINUTES`), and `am daemon`
  exits with it unless a TUI is still open or a command ran within those minutes. The next
  command starts it again.

- `AM_IMAGES=kitty|placeholders|placements|blocks|off` picks how artwork is drawn (default: kitty
  graphics where the terminal answers the query, else half blocks). `v` cycles it while running.
- `AM_TUI_LOG=<file>` writes what the TUI does (failed requests, never tokens) to a file.
- The volume, the last thing played and where it was are kept in `~/.config/am/tui-state.json`, so
  Space plays it again from there after the engine closed, also in a later session.
- Esc closes a sign-in that opened during the session; `S` starts it again. `NO_COLOR=1` draws
  without colors.

---

## 6. The shared developer token (token service)

For people without a MusicKit key of their own. `am` uses your own developer token when it has a
usable one (section 1). Otherwise it downloads a shared one from the token service: a Cloudflare
Worker (`token-worker/`) that signs a token valid for 7 days. Apple accepts that token only from
the engine page's origin, `http://localhost:47823`. `am` keeps it, with the address it came from,
in `~/.config/am/shared-developer-token.jwt`. It downloads a new one once fewer than 5 days are
left, or when Apple refuses the kept one. A download that fails, or doesn't answer within 10 s,
isn't tried again for an hour while an unexpired token is kept (even one Apple refused), or for
a minute when none is. A service that keeps handing out the refused token counts as a failure.

If TEAM_ID and KEY_ID are set but your own token can't be used (expired, missing, for another
key), `am` uses the shared one and says why: `am token`, `am doctor` and a note in the player.

- Address built into `am`: `https://am-token.xauyxau.workers.dev/token`. A `TOKEN_URL=<url>`
  line in `~/.config/am/env` overrides it, and `TOKEN_URL=` (empty) turns the shared token off.
- It only works with the default port, so leave `AM_PORT` unset.
- The service signs with the operator's MusicKit key (section 1). Revoking or rotating that key
  breaks the operator's own token and the shared one at the same time.

The rest of this section is for running a token service of your own, signed with your key.

### 6a. Deploy

Wrangler (Cloudflare's CLI) is pinned in `mise.toml`. Install it once with `mise install` in the
repo (run `mise trust` first if mise asks). It must be logged in: `wrangler whoami` says whether it
is. If not, run `wrangler login`: it opens the browser.

Deploy the Worker, then put its four settings in as secrets. Each value goes through a pipe, never
onto a command line. The IDs come from your env file. On macOS the key can come from the Keychain
(section 1e; click **Allow**, not **Always Allow**):

```bash
cd token-worker
wrangler deploy
security find-generic-password -a am -s am-musickit-p8 -w | base64 -D | wrangler secret put MUSICKIT_KEY
grep '^TEAM_ID=' ~/.config/am/env | cut -d= -f2- | tr -d '"\n' | wrangler secret put TEAM_ID
grep '^KEY_ID=' ~/.config/am/env | cut -d= -f2- | tr -d '"\n' | wrangler secret put KEY_ID
printf true | wrangler secret put ENABLED
```

Elsewhere, pipe the key in from where you keep it, e.g.
`wrangler secret put MUSICKIT_KEY < AuthKey_XXXXXXXXXX.p8`.

Until all four are in, `/token` answers 500 (settings missing) or 503 (switched off). Point `am`
at your deployment with `TOKEN_URL=https://<your worker>/token` in `~/.config/am/env`.

### 6b. Check it against Apple

In the repo:

```bash
npm run check:token-service
```

It fetches a token from the service and prints its header and claims (never the token). It then
asks Apple:
- `GET /v1/test` and one catalog search, with `Origin: http://localhost:47823`: both must answer
  200.
- `GET /v1/test` with no Origin header, and with `Origin: https://example.com`: Apple must refuse
  both (401 or 403).

Every line must show ✔. Pass another URL as an argument to check a different deployment.

To try `am` itself on the shared token, use an empty config dir, so that your own token isn't
used. Stop the background process first, because it reads your normal config dir:

```bash
am daemon stop
AM_CONFIG_DIR=/tmp/am-shared am token
AM_CONFIG_DIR=/tmp/am-shared am signin
AM_CONFIG_DIR=/tmp/am-shared am play
AM_CONFIG_DIR=/tmp/am-shared am daemon stop
```

`am token` should say `developer token: shared, from https://am-token.xauyxau.workers.dev/token`
(or your `TOKEN_URL`) and `✔ Apple accepted the token`. `am signin` tests Apple's sign-in popup
with the origin-bound token.

### 6c. Turn it off, rotate the key, see how much it's used

- **Off:** `printf false | wrangler secret put ENABLED`, run in `token-worker/`. `/token` then
  answers 503 at once. Tokens already handed out keep working until they expire, within 7 days.
  `printf true | …` turns it back on.
- **Revoke or rotate:** revoke the key in the developer portal (Certificates, IDs & Profiles →
  Keys). That ends every token signed with it, your own included. To carry on, create a new key
  (section 1b), set the new `KEY_ID` in `~/.config/am/env`, sign your own token again
  (`am token --key-stdin`, section 1d), then put `MUSICKIT_KEY` and `KEY_ID` again as in 6a. A
  copy of `am` holding the old token downloads the new one the first time Apple refuses the old
  one (401) on a request `am` sends itself (search, `am token`, the player's lists), sends that
  request again with it, and uses it from then on. A failed download waits as described at the
  top of this section. A running engine page keeps the token it started with: before the next
  play (`am play`, or a song or list started in the player), `am` asks Apple whether it still
  accepts that token, and if not, reloads the page once to take the new one. Until then, a queue
  that's playing fails at its next track. A play that finds the engine page reloading for another
  command waits for that reload. `am daemon stop` closes the engine at once; its next start takes
  the token `am` uses then.
- **Usage:** the Cloudflare dashboard → Workers & Pages → `am-token` → Metrics shows requests and
  errors over time, for up to three months. `wrangler tail am-token` streams live requests.
  These show how often tokens are fetched, not how much they are used against Apple; Apple shows
  nothing about that.
