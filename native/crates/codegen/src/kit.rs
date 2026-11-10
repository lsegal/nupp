//! Link kits travel as gzip-compressed POSIX tar archives. This fetches one
//! over HTTPS; checking it against the size and SHA-256 the caller's catalog
//! holds and unpacking it are the compiler's, in Nupp
//! (`nupp.tools.build.kitarchive`). Nothing here decides where kits live or
//! which one a build needs.

use std::fs;
use std::io::Read;
use std::path::Path;

/// The largest archive this will fetch.
const LIMIT: u64 = 1 << 30;

/// Fetches `url` into `path`, refusing a body that is not `size` bytes. The
/// file is written only once the whole body has arrived; the caller checks its
/// digest before unpacking it.
pub fn fetch(url: &str, path: &Path, size: u64) -> Result<(), String> {
    if !url.starts_with("https://") {
        return Err(format!("kits are fetched over HTTPS only, not {url}"));
    }
    let _ = rustls::crypto::ring::default_provider().install_default();
    let client = reqwest::blocking::Client::builder()
        .user_agent(concat!("nupp/", env!("CARGO_PKG_VERSION")))
        .build()
        .map_err(|e| format!("cannot start an HTTPS client: {e}"))?;
    let response = client.get(url).send().map_err(|e| format!("cannot fetch {url}: {e}"))?;
    if !response.status().is_success() {
        return Err(format!("fetching {url} answered {}", response.status()));
    }
    let mut bytes = Vec::new();
    response
        .take(size.min(LIMIT) + 1)
        .read_to_end(&mut bytes)
        .map_err(|e| format!("reading {url} failed: {e}"))?;
    if bytes.len() as u64 != size {
        return Err(format!("the kit archive is {} bytes; its catalog record says {size}", bytes.len()));
    }
    fs::write(path, &bytes).map_err(|e| format!("cannot write {}: {e}", path.display()))
}
