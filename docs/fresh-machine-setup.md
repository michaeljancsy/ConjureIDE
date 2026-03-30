# Fresh Machine Setup for ConjureDSP

## 1. Install Rust toolchain
```bash
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
source "$HOME/.cargo/env"
cargo install cbindgen
```

## 2. Remove broken worktree symlinks
If cloned from a repo that had worktree hooks, `rustc-dist` and `rust/python-dist` may be symlinks pointing to the original developer's machine. Delete before running setup:
```bash
rm rustc-dist rust/python-dist
```

## 3. Run setup scripts
```bash
cd rust && ./setup-python.sh        # Python 3.14 + numpy + scipy (~100MB)
cd .. && ./scripts/setup-rustc.sh   # Bundled Rust compiler + wasm32 target (~550MB)
# Also run if missing: ./scripts/setup-monaco.sh, ./scripts/setup-xterm.sh, ./scripts/setup-uv.sh
```

## 4. Code signing
- Add Apple Developer account in Xcode → Settings → Accounts
- Must import `.p12` file (cert + private key). Importing certs alone results in 0 valid identities from `security find-identity -v -p codesigning`
- Or create a new certificate: Xcode → Accounts → Manage Certificates → + → Apple Development

## 5. Build phase codesign fallback
The pbxproj has 4 build phases using `${EXPANDED_CODE_SIGN_IDENTITY}` which can be empty. Added fallback in each:
```bash
SIGN_ID="${EXPANDED_CODE_SIGN_IDENTITY:-'-'}"
```
Also updated `scripts/rebuild-and-copy-export-template.sh` to forward signing overrides to the nested xcodebuild.

## 6. Build & test
```bash
xcodebuild -project ConjureDSP.xcodeproj -scheme ConjureDSP build -allowProvisioningUpdates
xcodebuild -project ConjureDSP.xcodeproj -scheme ConjureDSP test -only-testing:ConjureDSPTests -allowProvisioningUpdates
```

## Known test gap
`exportAndRegisterRustPreset` fails unless export template is built with real signing identity (PluginKit rejects ad-hoc). 236/237 pass.
