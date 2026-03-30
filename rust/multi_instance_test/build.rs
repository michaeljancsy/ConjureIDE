use std::path::PathBuf;

fn main() {
    // python-build-standalone reports LIBDIR as /install/lib (build-time path),
    // so the linker can't find libpython3.14t. Add the actual python-dist/lib
    // to the library search path.
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let python_lib = manifest_dir.join("../python-dist/lib");
    if python_lib.exists() {
        println!("cargo:rustc-link-search=native={}", python_lib.display());
    }
}
