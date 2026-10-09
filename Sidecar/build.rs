//! Generates the gRPC client for `proto/keymapp.proto`.
//!
//! Only the client is generated; the sidecar never serves Keymapp's API.

use std::env;
use std::error::Error;
use std::path::Path;

/// Location protoc usually has on macOS when it is not on `PATH`.
const HOMEBREW_PROTOC: &str = "/opt/homebrew/bin/protoc";

fn main() -> Result<(), Box<dyn Error>> {
    locate_protoc()?;

    tonic_prost_build::configure()
        .build_client(true)
        .build_server(false)
        .compile_protos(&["proto/keymapp.proto"], &["proto"])?;

    println!("cargo:rerun-if-changed=proto/keymapp.proto");
    Ok(())
}

/// `prost-build` shells out to `protoc`; fail early with an actionable message
/// instead of letting the generated include fail with "No such file".
fn locate_protoc() -> Result<(), Box<dyn Error>> {
    if env::var_os("PROTOC").is_some() || protoc_on_path() {
        return Ok(());
    }
    if Path::new(HOMEBREW_PROTOC).is_file() {
        env::set_var("PROTOC", HOMEBREW_PROTOC);
        return Ok(());
    }
    Err(
        "protoc not found: install it (`brew install protobuf`) or point PROTOC at the binary"
            .into(),
    )
}

/// `prost-build` looks up `protoc` on `PATH` when `PROTOC` is unset.
fn protoc_on_path() -> bool {
    let Some(path) = env::var_os("PATH") else {
        return false;
    };
    env::split_paths(&path).any(|dir| dir.join("protoc").is_file())
}
