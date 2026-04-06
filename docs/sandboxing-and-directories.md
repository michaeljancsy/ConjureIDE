# Sandboxing and Directory Access in ConjureDSP

How macOS App Sandbox affects ConjureDSP's components, which directories they access, and where the current implementation is fragile.

## What is App Sandbox?

From [Apple's glossary](https://developer.apple.com/help/glossary/app-sandbox/):

> *App Sandbox* is a macOS access control technology designed to contain damage to the system and the user's data if an app becomes compromised. An app distributed through the Mac App Store must enable App Sandbox.

An app opts into sandboxing via the `com.apple.security.app-sandbox` entitlement (or the `ENABLE_APP_SANDBOX` Xcode build setting, which Xcode merges into the code signature at build time). Once sandboxed, the app is confined to its own **sandbox container** at `~/Library/Containers/<bundle-id>/`. Standard APIs like `FileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)` transparently redirect into this container — the app sees `~/Library/Application Support/` but is actually reading/writing `~/Library/Containers/<bundle-id>/Data/Library/Application Support/`.

Unsandboxed apps have no container. The same API call returns the real `~/Library/Application Support/`.

Source: [Apple — App Sandbox entitlement](https://developer.apple.com/documentation/BundleResources/Entitlements/com.apple.security.app-sandbox)

## ConjureDSP Components: Sandboxed or Not?

| Component | Sandboxed? | How we know |
|---|---|---|
| **ConjureDSP** (host app) | No | `ENABLE_APP_SANDBOX = NO` in `project.pbxproj`; no `com.apple.security.app-sandbox` in `ConjureDSP/ConjureDSP.entitlements` |
| **ConjureDSPExtension** (AU plugin) | Yes | `ENABLE_APP_SANDBOX = YES` in `project.pbxproj` (Debug and Release); Xcode merges this into the extension's code signature at build time |
| **ConjureDSPTerminal** (companion app) | No | `ENABLE_APP_SANDBOX = NO` in `project.pbxproj`; no `com.apple.security.app-sandbox` in `ConjureDSPTerminal/ConjureDSPTerminal.entitlements` |

All three declare the App Group entitlement (`group.com.MichaelJancsy.ConjureDSP`) in their respective `.entitlements` files, giving them access to the shared container at `~/Library/Group Containers/group.com.MichaelJancsy.ConjureDSP/`.

## Which DAWs are Sandboxed?

Whether the host DAW is sandboxed matters because AUv3 extensions can be loaded **in-process** inside the host. When that happens, the extension inherits the host process's sandbox context, which changes how filesystem APIs resolve paths.

### GarageBand: Sandboxed

GarageBand is distributed via the Mac App Store, which [requires App Sandbox](https://developer.apple.com/help/glossary/app-sandbox/). Its sandbox container is at `~/Library/Containers/com.apple.garageband10/`. When GarageBand loads an AU extension in-process, `applicationSupportDirectory` resolves into GarageBand's container — not the extension's own container and not the real `~/Library/Application Support/`.

Source: [JUCE forum — GarageBand X Sandboxing](https://forum.juce.com/t/garageband-x-sandboxing/11739) (community-confirmed container path and behavior)

### Logic Pro: Not Sandboxed

Logic Pro is distributed outside the Mac App Store (direct purchase from Apple). It does not have the `com.apple.security.app-sandbox` entitlement and has no sandbox container in `~/Library/Containers/`. When Logic loads an AU extension in-process, `applicationSupportDirectory` resolves to the real `~/Library/Application Support/`.

Note: Apple has not published official documentation confirming Logic Pro's sandbox status. This can be verified locally: `codesign -d --entitlements - /Applications/Logic\ Pro.app`.

### Ableton Live: Not Sandboxed

Ableton Live is distributed outside the Mac App Store. It is not sandboxed. Same behavior as Logic Pro for path resolution.

### What happens when a sandboxed host loads a non-sandbox-safe AU?

From [Apple TN2247](https://developer.apple.com/library/archive/technotes/tn2247/_index.html):

The system shows a dialog asking the user to approve loading the non-sandbox-safe component. If the user approves, "the system will disable the host application's sandbox" and the component loads. The system remembers the user's choice for future launches. If the user does not approve, the load fails.

This means that in practice, even GarageBand's sandbox may be disabled if the user approves loading a non-sandbox-safe AU. However, relying on this is fragile — the user could deny the prompt, and future macOS versions could change this behavior.

### The `sandboxSafe` flag

Audio Units declare themselves sandbox-safe via the `sandboxSafe` key in `Info.plist`. Sandbox-safe AUs load without any user dialog. Non-sandbox-safe AUs trigger the approval dialog described above.

Source: [Apple — `sandboxSafe` property](https://developer.apple.com/documentation/avfaudio/avaudiounitcomponent/1390100-sandboxsafe)

## Directory Locations

Three directories are relevant to ConjureDSP's data storage:

### 1. Real Application Support

```
~/Library/Application Support/ConjureDSP/
```

The standard macOS location for app data. Accessible to any unsandboxed process. When an unsandboxed app calls `FileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)`, it gets this path.

### 2. App Group Container

```
~/Library/Group Containers/group.com.MichaelJancsy.ConjureDSP/
```

A shared directory accessible to any app/extension that declares the `com.apple.security.application-groups` entitlement with the same group ID. Accessed via `FileManager.containerURL(forSecurityApplicationGroupIdentifier:)`. This path is the same regardless of whether the calling process is sandboxed, which host is loading the extension, or whether loading is in-process or out-of-process.

**Caveat on macOS 26+**: When an *unsandboxed* app accesses `~/Library/Group Containers/`, macOS triggers a TCC "access data from other apps" prompt. This is why the host app and terminal companion use Application Support instead. Sandboxed apps with the App Group entitlement do not trigger this prompt.

### 3. Sandbox Container

```
~/Library/Containers/<bundle-id>/Data/Library/Application Support/
```

Private to a single sandboxed app. Created automatically by macOS. The extension's own container exists at `~/Library/Containers/com.MichaelJancsy.ConjureDSP.ConjureDSPExtension/` (or the debug bundle ID variant), but ConjureDSP does not intentionally store data here.

## What `applicationSupportDirectory` Resolves To

The same API call returns different paths depending on sandbox context:

| Context | `applicationSupportDirectory` resolves to |
|---|---|
| Unsandboxed app (host app, terminal) | `~/Library/Application Support/` |
| Extension running out-of-process (own appex process) | `~/Library/Containers/<ext-bundle-id>/Data/Library/Application Support/` |
| Extension loaded in-process by **unsandboxed** host (Logic Pro, Ableton) | `~/Library/Application Support/` |
| Extension loaded in-process by **sandboxed** host (GarageBand) | `~/Library/Containers/<host-bundle-id>/Data/Library/Application Support/` |

`containerURL(forSecurityApplicationGroupIdentifier:)` always returns `~/Library/Group Containers/group.com.MichaelJancsy.ConjureDSP/` regardless of context.

## Current Directory Usage by Component

### Components using `AppGroupContainer.url` (routed correctly)

These go through the `AppGroupContainer` abstraction, which routes to the App Group container when running as an appex and falls back to Application Support when running in the host app process.

| Component | File | What it stores |
|---|---|---|
| ConjureDSPExtensionAudioUnit | `ConjureDSPExtension/Common/Audio Unit/ConjureDSPExtensionAudioUnit.swift:27` | Python home path resolution |
| SubscriptionManager | `ConjureDSPExtension/Model/SubscriptionManager.swift:95` | License tokens |
| ExportManager | `ConjureDSPExtension/Export/ExportManager.swift:53` | Pending exports staging |
| PackageInstallManager | `ConjureDSPExtension/Model/PackageInstallManager.swift:311` | pip packages |
| CrateInstallManager | `ConjureDSPExtension/Model/CrateInstallManager.swift:346` | Cargo crates |
| ToneModelStore | `ConjureDSPExtension/Model/ToneModelStore.swift:238` | NAM tone models |
| DaemonStatusChecker | `ConjureDSPExtension/Terminal/DaemonStatusChecker.swift:60` | Terminal port discovery |
| MCP tools | `ConjureDSPExtension/Common/Audio Unit/ConjureDSPExtensionAudioUnit+MCP.swift:290` | Package listing, tones |

### Components calling `applicationSupportDirectory` directly (bypassing AppGroupContainer)

These bypass the `AppGroupContainer` abstraction entirely:

| Component | File | What it stores |
|---|---|---|
| PresetManager | `ConjureDSPExtension/Model/PresetManager.swift:39` | User presets (`Presets/`), repo presets (`RepoPresets/`) |
| WasmCache | `ConjureDSPExtension/Compilation/WasmCache.swift:11` | Compiled WASM binaries (`WasmCache/`) |
| ExportRegistry | `ConjureDSPExtension/Export/ExportRegistry.swift:23` | `export-registry.json` |
| CommunityPresetStore | `ConjureDSPExtension/GitHub/CommunityPresetStore.swift:25` | `community-cache/` |

## The Problem

The four components that call `applicationSupportDirectory` directly work today because the major DAWs (Logic Pro, Ableton Live) are unsandboxed and load the extension in-process. In that context, `applicationSupportDirectory` resolves to the real `~/Library/Application Support/ConjureDSP/`, which is the same path the host app and terminal write to.

If a sandboxed DAW (like GarageBand) loads the extension in-process, or if the extension runs out-of-process, those four components would silently read/write to a different directory — the host's sandbox container or the extension's own sandbox container. User presets, WASM cache, export registry, and community cache would all be invisible, and the plugin would appear to have no saved data.

The `AppGroupContainer` abstraction already handles this correctly for the components that use it. The fix is to route the four remaining components through it as well.
