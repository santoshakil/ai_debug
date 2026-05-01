use std::path::PathBuf;

fn main() {
    let manifest_dir = PathBuf::from(std::env::var("CARGO_MANIFEST_DIR").unwrap());
    let repo_root = manifest_dir
        .parent()
        .and_then(|p| p.parent())
        .and_then(|p| p.parent())
        .unwrap()
        .to_path_buf();
    let proto_path = repo_root.join("protos").join("ai_debug.proto");

    println!("cargo:rerun-if-changed={}", proto_path.display());
    println!("cargo:rerun-if-changed=build.rs");

    let out_dir = manifest_dir.join("src").join("pb");
    std::fs::create_dir_all(&out_dir).expect("mkdir src/pb");

    let mut cfg = prost_build::Config::new();
    cfg.out_dir(&out_dir);
    cfg.compile_protos(&[proto_path.as_path()], &[repo_root.join("protos").as_path()])
        .expect("prost compile");

    // cbindgen writes the FFI header to a stable repo path so ffigen + any
    // downstream consumer can find it without depending on CARGO_TARGET_DIR.
    let include_dir = repo_root.join("rust").join("generated");
    std::fs::create_dir_all(&include_dir).ok();
    let header_path = include_dir.join("ai_debug.h");

    let config = cbindgen::Config::from_file(manifest_dir.join("cbindgen.toml")).unwrap_or_default();
    match cbindgen::Builder::new()
        .with_crate(&manifest_dir)
        .with_config(config)
        .generate()
    {
        Ok(bindings) => {
            bindings.write_to_file(&header_path);
        }
        Err(e) => {
            println!("cargo:warning=cbindgen failed: {e}");
        }
    }
}
