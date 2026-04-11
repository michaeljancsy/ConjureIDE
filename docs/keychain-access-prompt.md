# Keychain access prompt — why ConjureDSP asks for your login password

If you've seen this dialog while running ConjureDSP:

> **ConjureDSPExtension (ConjureDSP) wants to use your confidential information stored in "com.MichaelJancsy.ConjureDSP.AI" in your keychain.**
>
> To allow this, enter the "login" keychain password.

…this document explains what it is, why it appears, and how to stop it.

## TL;DR

macOS is asking you to authorize the currently-running build of the AU extension to read a keychain item that was created by a differently-signed build. It's a code-signing identity mismatch, not a bug or a security incident. Click **Always Allow** and the prompt will stop for that item until the signature changes again.

## What the service name actually holds

The service string `com.MichaelJancsy.ConjureDSP.AI` is a **legacy misnomer** — despite the `.AI` suffix it has nothing to do with AI. It's the shared service bucket used by `KeychainHelper` for all secrets the extension stores.

Defined once in `ConjureDSPExtension/Common/Utility/KeychainHelper.swift:5`:

```swift
private static let service = "com.MichaelJancsy.ConjureDSP.AI"
```

Items currently written under this service:

| Key | Written by | Purpose |
|---|---|---|
| `tone3000-access-token` | `Tone3000Client.swift:67, 107` | Tone3000 API access token |
| `tone3000-refresh-token` | `Tone3000Client.swift:68, 108` | Tone3000 refresh token |
| `tone3000-token-expiry`  | `Tone3000Client.swift:70, 110` | Access-token expiry timestamp |
| `tone3000-username` | `Tone3000Client.swift:237` | Logged-in Tone3000 username |
| `gitHubToken` | `GitHubService.swift:45` | Personal GitHub PAT for private preset repo sync |

All of these are read back via `KeychainHelper.load(key:)` at extension startup (`Tone3000Client.swift:40-41`, `GitHubService.swift:30`) — which is exactly when the prompt tends to appear.

## Why macOS shows the prompt

Keychain items carry an **access control list (ACL)** that lists the code signatures allowed to read them without a password prompt. The ACL is bound to the requesting process's **code signature**, not its bundle ID or the keychain service string. So when a build signed differently from the one that originally created the item tries to read it, macOS prompts you to authorize the new signature.

When you approve, the new signature gets appended to the item's ACL (if you chose **Always Allow**) and subsequent reads are silent — *until the signature changes again*.

## Common triggers in this project

- **Switching between Debug and Release builds.** Since the Debug/Release identity split, Debug uses bundle ID `com.MichaelJancsy.ConjureDSP.debug.ConjureDSPExtension` and Release uses `com.MichaelJancsy.ConjureDSP.ConjureDSPExtension`. They're distinct keychain clients with distinct signatures.
- **Fresh DerivedData or worktree builds.** A new DerivedData path produces a new ad-hoc signature, which the existing keychain ACL doesn't recognize.
- **Re-signing after `build-release.sh`.** The release pipeline re-signs the extension after export, so the production `.app` ends up with a signature distinct from the CI-built or prior-released variants users may have approved before.
- **First access from a newly-upgraded signed build.** Upgrading from an older Developer ID-signed release to a newer one still changes the specific signature, which triggers the prompt exactly once per item.

## What the buttons do

| Button | Effect |
|---|---|
| **Allow** | One-shot grant for the current process. The next launch will prompt again. |
| **Always Allow** | Adds the current signature to the item's ACL. Future reads from the same signature are silent. |
| **Deny** | `SecItemCopyMatching` returns an error. `Tone3000Client` behaves as logged out; `GitHubService` behaves as if no token is stored. No data is lost — it just stays hidden from the current signature. |

Denying is safe. It won't delete the item or break anything beyond the obvious ("personal GitHub sync won't work until you grant access or re-enter the token").

## How to stop the prompts for good

If the prompts are annoying (or if you keep switching between Debug/Release and don't want to keep clicking through them), the cleanest fix is to nuke and re-create the items:

1. Open **Keychain Access.app**.
2. Select the **login** keychain.
3. Search for `com.MichaelJancsy.ConjureDSP.AI`.
4. Delete every matching entry.
5. Launch ConjureDSP and:
   - Sign back in to Tone3000 (Settings → Tone3000)
   - Re-enter your GitHub PAT (Settings → GitHub)

The newly-written items will be owned by the current signature and won't prompt again from that signature. You'll still see a single prompt the first time you open the build on the "other side" of the Debug/Release split.

## Future cleanup

The `com.MichaelJancsy.ConjureDSP.AI` service string is confusing and should be renamed — `com.MichaelJancsy.ConjureDSP.secrets` or similar would describe what it actually holds. This is deferred because it requires a one-time migration: at startup, try reading each key from both the old and new service names, write to the new service, and delete from the old. Without that migration, existing users would silently be logged out of Tone3000 and lose their saved GitHub PAT on upgrade.
