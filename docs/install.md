# Installing Tabula

[Back to the README](../README.md)

- [Requirements](#requirements)
- [Download and verify](#download-and-verify)
- [Copy to Applications](#copy-to-applications)
- [First launch](#first-launch)
- [After launching](#after-launching)
- [Updating](#updating)
- [Uninstalling](#uninstalling)
- [Where Tabula keeps your data](#where-tabula-keeps-your-data)
- [Size and resource use](#size-and-resource-use)
- [Reporting a problem](#reporting-a-problem)

> **Why macOS warns you.** Tabula is free and not yet signed with an Apple Developer ID or notarized by Apple, so macOS cannot confirm who made it and blocks the first launch with a message such as *"Apple could not verify 'Tabula' is free of malware"* or *"'Tabula' cannot be opened because the developer cannot be verified"*. The steps below tell macOS you trust this app. You do this once per installed version.

## Requirements

macOS 14 Sonoma or later, on an Apple silicon or Intel Mac. Tabula is developed and mostly tested on macOS 26 Tahoe; please [report](#reporting-a-problem) anything that misbehaves on 14 or 15.

## Download and verify

1. From the [latest release](https://github.com/tungnguyenvan/tabula/releases/latest), download `Tabula-<version>.dmg` and `SHA256SUMS.txt` into the same folder.
2. Check that the download is intact and unmodified:
   ```bash
   cd ~/Downloads
   shasum -a 256 -c SHA256SUMS.txt --ignore-missing
   ```
   You should see `Tabula-<version>.dmg: OK`. If not, delete the file and download it again.

## Copy to Applications

Open the DMG and drag **Tabula** onto the **Applications** folder. Then eject the DMG. Don't run Tabula from inside the DMG.

## First launch

**macOS 15 Sequoia and later (including 26 Tahoe)**

1. Open **Applications** and double-click **Tabula**. macOS refuses to open it. Click **Done** (not *Move to Trash*).
2. Open **System Settings › Privacy & Security** and scroll down to **Security**.
3. Next to *"Tabula" was blocked to protect your Mac*, click **Open Anyway**.
4. Confirm with **Open Anyway** again, then enter your Mac password or use Touch ID.

The *Open Anyway* button stays available for about an hour after the blocked attempt. If it isn't there, double-click Tabula again first.

**macOS 14 Sonoma**

1. In **Applications**, Control-click (or right-click) **Tabula** and choose **Open**.
2. In the dialog, click **Open**.

After the first successful launch, Tabula opens normally with a double-click.

**Alternative: Terminal.** If you prefer, remove the download quarantine flag instead of using System Settings:

```bash
xattr -dr com.apple.quarantine /Applications/Tabula.app
```

Only do this for a copy you downloaded from this repository and verified as described in [Download and verify](#download-and-verify).

## After launching

- **Saved passwords:** macOS may ask whether Tabula may use its Keychain item. Choose **Always Allow**. All connections share one item, so one **Always Allow** covers every connection. Tabula isn't signed with an Apple Developer ID, so macOS may ask again after an update; the Keychain is what keeps your database passwords safe. If you choose Deny, connections fail to authenticate; edit the connection and enter the password again.
- **Local network (macOS 15 and later):** the first connection to a server on your local network (such as `192.168.x.x` or `10.x.x.x`) asks for permission. Choose **Allow**. If you denied it, connections fail with "No route to host"; turn it on in **System Settings › Privacy & Security › Local Network**. `localhost`, Docker port forwards and internet hosts aren't affected.

Then create your first connection: see [Creating a connection](connections.md#creating-a-connection).

## Updating

Tabula checks this repository's [latest release](https://github.com/tungnguyenvan/tabula/releases/latest) at launch, at most once a day (turn this off in Settings), and from **Tabula › Check for Updates…**. It shows the release notes, and you can **Install and Relaunch**, open the release page, or skip that version.

- Installing downloads `Tabula-<version>.zip` and `SHA256SUMS.txt` from the release, and refuses the download unless its SHA-256 matches, the bundle identifier and version are right and the code signature is valid. It then replaces the app where it is and relaunches. If copying fails, the previous version is put back.
- The checksum and the archive come from the same GitHub release, so this protects against corrupted or tampered downloads in transit, not against a compromised repository.
- Tabula needs write access to the folder it runs from, so it can't update itself while running from the DMG or from a location macOS moved it to ("App Translocation"). Move it to Applications first.

To update by hand, drag the new version to Applications, replacing the old one; saved connections are kept. Version 0.1.0 has no updater, so install a newer one by hand once.

## Uninstalling

Delete **Tabula** from Applications. To also remove saved connections, delete `~/Library/Application Support/Tabula`. Saved passwords are in **Keychain Access**, under the service `app.tabula.connections` (AI API keys under `app.tabula.ai`).

## Where Tabula keeps your data

- **Connection settings:** `~/Library/Application Support/Tabula/connections.json`, never with passwords.
- **Passwords:** the login Keychain, service `app.tabula.connections`. Deleting a connection deletes its password. AI API keys are in the Keychain too.
- **Open tabs** (query SQL, open tables, filters, schema, history): `~/Library/Application Support/Tabula/Workspaces`, deleted with their connection, or all of them when you turn off **Reopen tabs when connecting** in Settings › General.
- **Saved queries**, **AI conversations** and **local models** are in the `Queries`, `Chats` and `Models` folders of `~/Library/Application Support/Tabula`. Conversations are deleted with their connection; delete models there or in Settings › AI.
- **Network:** Tabula connects to the databases you configure, and to `api.github.com` / `github.com` for updates. With AI on, it also talks to the provider you chose ([what is sent](ai.md#what-is-sent)); with AI agents on, the agents you set up read what their tools return. No telemetry, no account.

## Size and resource use

Measured on an Apple M2 with macOS 26.1: memory with 0.4.0, sizes with 0.5.0, in decimal megabytes.

| | |
| --- | --- |
| Download | 24.0 MB (ZIP), 27.4 MB (DMG) |
| Installed | 62 MB: the app 37 MB and llama.cpp, for local models, 23 MB. One universal app for Apple silicon and Intel. Downloaded models are stored separately. |
| Memory | 28 MB with only the Connections window · 81 MB with a Postgres table open (300 rows) · 79 MB with a MongoDB collection (300 documents) · 70 MB with Postgres, MySQL and Redis connections open |
| CPU idle / metrics refreshing every 3 s | 0% / about 1% |

Memory is the footprint macOS reports, as Activity Monitor shows it. A 5,000-row page takes only a few MB more than 300 rows, because the grid draws just the rows on screen. A model running in Tabula adds about its file size while loaded (0.5 GB for Qwen2.5 Coder 0.5B) and is released after five minutes unused.

[Benchmarks](benchmarks.md) times connecting, paging, sorting, filtering, counting, a 50,000-row result and commits on every database with 100,000-row tables: a 300-row page loads in 0.2 to 4 ms, a 5,000-row page in 4 to 43 ms.

## Reporting a problem

**Help › Report a Problem…** opens a new issue on this repository in your browser, with Tabula's version and build, the macOS version and the kind of Mac filled in. Tabula sends nothing itself: you read and edit the issue before submitting it.
