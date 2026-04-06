# How Permissions Work: TCC, Sandboxing, and AUv3 Extensions

Reference document summarizing Apple's official documentation on how macOS permissions, sandboxing, and file access interact for AUv3 audio unit extensions hosted inside DAWs.

## TCC (Transparency, Consent, and Control)

TCC is the macOS subsystem that manages user-visible app privileges (camera, microphone, contacts, location, etc.), surfaced through System Settings > Privacy & Security. There is no public developer-facing TCC API — higher-level frameworks (AVFoundation, Contacts, etc.) interact with it on behalf of apps.

### How TCC identifies the "responsible" app

macOS tracks a concept of "responsibility" for TCC checks. When a subprocess or XPC service triggers a TCC check, the prompt shows the responsible app's name, the user's decision is recorded for the whole app, and it appears under the app's name in System Settings. There is no general API for managing responsibility; the system sets it up as it starts and manages processes.

> Source: https://developer.apple.com/forums/thread/731504

### TCC and App Extensions

Extensions share privacy controls with their **containing app** (the app that ships the extension), NOT the host app (the DAW loading the extension). When ConjureDSPExtension runs inside Logic Pro, it gets ConjureDSP.app's TCC permissions, not Logic's. Users cannot individually manage extension-specific privacy settings.

The TCC database maintains separate entries for apps (identified by bundle ID) and extensions (identified by path). Permissions granted to the containing app flow to its extensions, but permissions granted to the host app do not.

> Source: https://support.apple.com/guide/security/supporting-extensions-secabd3504cd/web
> Source: https://developer.apple.com/forums/thread/763956

## App Sandbox and Containers

### Per-app sandbox containers

Every sandboxed app gets an isolated container at:

```
~/Library/Containers/<bundle-id>/
```

This container provides a private home directory with standard Library subdirectories (Application Support, Caches, Preferences, etc.). When a sandboxed app calls `FileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)`, it resolves to `~/Library/Containers/<bundle-id>/Data/Library/Application Support/` — not the real `~/Library/Application Support/`.

For non-sandboxed apps, the same API resolves to the actual `~/Library/Application Support/`.

> Source: https://developer.apple.com/library/archive/documentation/FileManagement/Conceptual/FileSystemProgrammingGuide/FileSystemOverview/FileSystemOverview.html
> Source: https://developer.apple.com/library/archive/documentation/FileManagement/Conceptual/FileSystemProgrammingGuide/MacOSXDirectories/MacOSXDirectories.html

### App Group shared containers

App Group containers are stored at:

```
~/Library/Group Containers/<application-group-id>/
```

Apps retrieve the path via `FileManager.containerURL(forSecurityApplicationGroupIdentifier:)`. The group container is a **separate directory** from the per-app sandbox container. Code must explicitly call the group container API — `applicationSupportDirectory` will NOT point here.

The group container has **no predefined internal structure**. Apps create whatever subdirectories they need within it.

> Source: https://developer.apple.com/library/archive/documentation/Miscellaneous/Reference/EntitlementKeyReference/Chapters/EnablingAppSandbox.html

### macOS Sequoia: App Group container protection

As of WWDC24, macOS has extended sandbox protections for shared containers. Prompts are now shown when apps from **other developers** attempt to access group-shared containers. This means the App Group container is tightly locked to your team ID.

> Source: https://developer.apple.com/videos/play/wwdc2024/10123/

## Extension Sandboxing and File Access

### Extensions run in their own sandbox

Extensions run in their own address space, sandboxed like any third-party app, with a container separate from the containing app's container. Communication between host and extension uses interprocess communication mediated by the system framework.

There is no direct communication between an extension and its containing app. The containing app typically is not even running while the extension is running in a DAW. The containing app and the host app do not communicate with each other at all.

> Source: https://support.apple.com/guide/security/supporting-extensions-secabd3504cd/web
> Source: https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/ExtensionOverview.html

### Sharing data via App Groups

The extension and containing app have no direct access to each other's sandbox containers. To share data, both must declare the same App Group entitlement, which gives both read/write access to the shared container at `~/Library/Group Containers/<group-id>/`.

Data accesses must be synchronized to avoid corruption. Recommended approaches: Core Data, SQLite (WAL mode preferred), POSIX locks (`flock()`), `NSFileCoordinator`, or atomic safe-save operations on flat files.

> Source: https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/ExtensionScenarios.html
> Source: https://developer.apple.com/library/archive/technotes/tn2408/_index.html

### Privacy data inheritance

On macOS, all extension templates include the App Sandbox and `com.apple.security.files.user-selected.read-only` entitlements by default. In general, when users give a containing app access to their private data, all extensions in the containing app also receive access. Additional capabilities (network, photos, contacts) must be explicitly declared via entitlements.

> Source: https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/ExtensionCreation.html

## AUv3 Extensions in DAWs

### The `sandboxSafe` flag

The `sandboxSafe` key in Info.plist (Boolean) indicates whether the audio unit can be loaded directly into a sandboxed host process without prompting the user. Audio Units that declare themselves sandbox-safe load without any dialog.

Non-sandbox-safe Audio Units trigger a system dialog when a sandboxed host tries to load them. If the user approves, the host application's sandbox is **disabled entirely**. The system remembers this decision for future launches.

> Source: https://developer.apple.com/library/archive/technotes/tn2247/_index.html
> Source: https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/AudioUnit.html

### Resource usage declarations

Non-sandbox-safe Audio Components must declare their resource needs via a `resourceUsage` dictionary in Info.plist (covering IOKit user clients, Mach services, network access, filesystem access). The system compares declared resource usage against the host's sandbox entitlements. If the host allows those resources, the component is treated as sandbox-safe for that process.

> Source: https://developer.apple.com/library/archive/technotes/tn2247/_index.html

### Host app entitlements for loading AUs

AU hosts need the `com.apple.security.temporary-exception.audio-unit-host` entitlement to load non-sandbox-safe Audio Units. The `com.apple.security.device.microphone` entitlement is needed for audio input. Using the audio-unit-host temporary exception can disable the host app's sandbox completely in compatibility scenarios.

> Source: https://developer.apple.com/library/archive/technotes/tn2312/_index.html
> Source: https://developer.apple.com/library/archive/qa/qa1483/_index.html

### In-process loading changes path resolution

AUv3 extensions support loading in-process in the host. When running in-process in a **non-sandboxed host** (like Logic Pro), `applicationSupportDirectory` resolves to the actual `~/Library/Application Support/`. When running in-process in a **sandboxed host**, it resolves to the host's sandbox container path. This is a critical behavioral difference that affects file discovery.

> Source: https://developer.apple.com/forums/thread/705591

### The App Group container is host-independent

The DAW does not need to be (and cannot be) part of your App Group. The App Group is purely between your containing app and your extension. Regardless of which DAW loads the extension, `containerURL(forSecurityApplicationGroupIdentifier:)` always resolves to the same `~/Library/Group Containers/<group-id>/` path. This makes the App Group container the only reliable, portable location for shared data.

## Summary: What the extension can access

| Location | Accessible? | Notes |
|---|---|---|
| Own sandbox container (`~/Library/Containers/<ext-bundle-id>/`) | Yes | Private to the extension |
| Containing app's container (`~/Library/Containers/<app-bundle-id>/`) | No | No direct access |
| App Group container (`~/Library/Group Containers/<group-id>/`) | Yes | Must explicitly use `containerURL(forSecurityApplicationGroupIdentifier:)` |
| `~/Library/Application Support/` (real) | Maybe | Only when loaded in-process by a non-sandboxed host |
| Host DAW's sandbox container | No | Extension does not inherit host permissions |
| Host DAW's TCC permissions | No | Extension inherits from containing app only |

## Implications for ConjureDSP

1. **Python runtime location**: Storing the Python runtime at `~/Library/Application Support/ConjureDSP/PythonRuntime-3.14/` works when the extension is loaded in-process by a non-sandboxed host (Logic Pro, Ableton, etc.), but would fail if loaded by a sandboxed host or out-of-process — `applicationSupportDirectory` would resolve to a different path. The App Group container is the only location that works reliably regardless of host.

2. **App Group container is the safe path**: The App Group container at `~/Library/Group Containers/group.com.MichaelJancsy.ConjureDSP/` is accessible from the extension regardless of which DAW hosts it, and is the correct place for shared data (presets, tokens, runtime files).

3. **TCC prompts show ConjureDSP**: Any TCC prompts triggered by the extension (e.g., for microphone access) will show ConjureDSP.app's name, not the DAW's name. The user's decision is recorded for ConjureDSP, not for the DAW.

4. **No filesystem access beyond declared entitlements**: The extension cannot access arbitrary filesystem locations. It is limited to its own sandbox container, the App Group container, and whatever the host's sandbox allows (if loaded in-process).
