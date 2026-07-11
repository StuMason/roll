//! One-click Crunch (#19): tar the take (minus the full-res camera master),
//! upload it to crunch with the hostname pinned to the origin's public IP
//! (Cloudflare Free caps request bodies at 100MB — real packs blow through
//! that; the tailnet IP won't do because `tailscale serve` owns tailnet:443
//! on the box), poll the job, and land `crunch.json` in the take dir. Status
//! streams to the UI as `roll://crunch` events, mirroring `roll://state`.
//!
//! A `crunch.job` marker sits in the take dir while a job is in flight so a
//! relaunch can resume polling (processing runs ~0.6–0.7× realtime — long
//! enough to quit the app mid-crunch). It's removed when `crunch.json` lands
//! or the job fails; it survives lost-contact so resume can pick it up.

use std::collections::HashSet;
use std::net::{SocketAddr, TcpStream};
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::Duration;

use serde::{Deserialize, Serialize};
use tauri::{AppHandle, Emitter, Manager};

/// Origin-side body cap (PHP + Laravel validation, verified 2026-07-03).
/// Checked before taring so a too-big pack fails in milliseconds, not via a
/// 422 after a full upload.
const ORIGIN_CAP_BYTES: u64 = 300 * 1024 * 1024;
const POLL_EVERY: Duration = Duration::from_secs(5);
/// Consecutive poll failures tolerated before giving up. The job keeps running
/// server-side; `crunch.job` stays behind so a relaunch resumes the poll.
const MAX_POLL_ERRORS: u32 = 10;

// ---- config (~/.config/roll/config.json) ----
// The key must never live in the repo (it's public); URL and origin have
// sensible defaults so the file usually holds a single line.

#[derive(Deserialize, Clone)]
struct Config {
    crunch_api_key: String,
    #[serde(default = "default_url")]
    crunch_url: String,
    #[serde(default = "default_origin")]
    crunch_origin: String,
}
fn default_url() -> String {
    "https://crunch.stumason.dev".into()
}
fn default_origin() -> String {
    // the Netcup box's public IP — Traefik serves the real LE cert there, no
    // Cloudflare in the path (NOT the tailnet IP: tailscale serve owns that :443)
    "159.195.194.97:443".into()
}

fn config_path() -> PathBuf {
    std::env::var_os("HOME")
        .map(PathBuf::from)
        .unwrap_or_default()
        .join(".config/roll/config.json")
}

fn load_config() -> Result<Config, String> {
    let path = config_path();
    let txt = std::fs::read_to_string(&path).map_err(|_| {
        format!(
            "no crunch config — create {} with {{\"crunch_api_key\": \"…\"}}",
            path.display()
        )
    })?;
    serde_json::from_str(&txt).map_err(|e| format!("bad {}: {e}", path.display()))
}

// ---- events (roll://crunch) ----

#[derive(Serialize, Clone)]
#[serde(rename_all = "camelCase")]
struct CrunchEvent {
    take: String,
    dir: String,
    /// taring | uploading | queued | processing | completed | failed
    status: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    stage: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    done: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    total: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    error: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    job_id: Option<String>,
}

fn emit(app: &AppHandle, take: &str, dir: &Path, status: &str, ev: CrunchPatch) {
    let _ = app.emit(
        "roll://crunch",
        CrunchEvent {
            take: take.to_string(),
            dir: dir.to_string_lossy().into_owned(),
            status: status.to_string(),
            stage: ev.stage,
            done: ev.done,
            total: ev.total,
            error: ev.error,
            job_id: ev.job_id,
        },
    );
}

/// The optional half of a CrunchEvent, so call sites only name what they have.
#[derive(Default)]
struct CrunchPatch {
    stage: Option<String>,
    done: Option<u64>,
    total: Option<u64>,
    error: Option<String>,
    job_id: Option<String>,
}

// ---- in-flight guard (double-click / double-resume protection) ----

#[derive(Default)]
pub struct Inflight(pub Mutex<HashSet<String>>);

// ---- the command ----

#[tauri::command]
pub fn crunch_pack(app: AppHandle, dir: String) -> Result<(), String> {
    let dir = PathBuf::from(&dir);
    if !dir.join("manifest.json").exists() {
        return Err("not a finalized pack (no manifest.json)".into());
    }
    let take = dir
        .file_name()
        .map(|s| s.to_string_lossy().into_owned())
        .unwrap_or_default();
    claim(&app, &take)?;
    tauri::async_runtime::spawn(drive(app, dir, take, None));
    Ok(())
}

/// On launch, resume polling any take that has a dangling `crunch.job` (the
/// app quit mid-crunch; the job kept running server-side).
pub fn resume_jobs(app: &AppHandle, root: &Path) {
    let Ok(entries) = std::fs::read_dir(root) else {
        return;
    };
    for e in entries.flatten() {
        let dir = e.path();
        let job_file = dir.join("crunch.job");
        if !dir.is_dir() || !job_file.exists() {
            continue;
        }
        if dir.join("crunch.json").exists() {
            let _ = std::fs::remove_file(&job_file); // stale marker — already landed
            continue;
        }
        let job_id = std::fs::read_to_string(&job_file)
            .ok()
            .and_then(|t| serde_json::from_str::<serde_json::Value>(&t).ok())
            .and_then(|v| v["id"].as_str().map(String::from));
        let Some(job_id) = job_id else {
            let _ = std::fs::remove_file(&job_file); // unreadable — treat as never started
            continue;
        };
        let take = dir
            .file_name()
            .map(|s| s.to_string_lossy().into_owned())
            .unwrap_or_default();
        if claim(app, &take).is_err() {
            continue;
        }
        tauri::async_runtime::spawn(drive(app.clone(), dir, take, Some(job_id)));
    }
}

fn claim(app: &AppHandle, take: &str) -> Result<(), String> {
    let inflight = app.state::<Inflight>();
    let mut set = inflight.0.lock().unwrap();
    if !set.insert(take.to_string()) {
        return Err("already crunching this take".into());
    }
    Ok(())
}

/// Owns one take's crunch lifecycle end-to-end; emits `failed` on any error
/// and always releases the in-flight claim.
async fn drive(app: AppHandle, dir: PathBuf, take: String, resume_job: Option<String>) {
    if let Err(e) = run(&app, &dir, &take, resume_job).await {
        emit(
            &app,
            &take,
            &dir,
            "failed",
            CrunchPatch {
                error: Some(e),
                ..Default::default()
            },
        );
    }
    if let Some(state) = app.try_state::<Inflight>() {
        state.0.lock().unwrap().remove(&take);
    }
}

async fn run(
    app: &AppHandle,
    dir: &Path,
    take: &str,
    resume_job: Option<String>,
) -> Result<(), String> {
    let cfg = load_config()?;

    // Reach the origin before doing any work — and fail with the *actual*
    // problem ("tailnet down") rather than a mysterious upload timeout.
    let origin = cfg.crunch_origin.clone();
    let addr = tauri::async_runtime::spawn_blocking(move || origin_reachable(&origin))
        .await
        .map_err(|e| e.to_string())??;
    let client = build_client(&cfg, addr)?;

    let job_id = match resume_job {
        Some(id) => {
            emit(
                app,
                take,
                dir,
                "processing",
                CrunchPatch {
                    job_id: Some(id.clone()),
                    ..Default::default()
                },
            );
            id
        }
        None => {
            let (names, total) = upload_entries(dir)?;
            if total > ORIGIN_CAP_BYTES {
                return Err(format!(
                    "pack is {}MB — over crunch's 300MB origin cap",
                    total / (1024 * 1024)
                ));
            }
            emit(app, take, dir, "taring", CrunchPatch::default());
            let tar_path = std::env::temp_dir().join(format!("roll-crunch-{take}.tar"));
            let tar_len = {
                let (dir2, tar2) = (dir.to_path_buf(), tar_path.clone());
                tauri::async_runtime::spawn_blocking(move || make_tar(&dir2, &tar2, &names))
                    .await
                    .map_err(|e| e.to_string())??
            };
            emit(app, take, dir, "uploading", CrunchPatch::default());
            let uploaded = upload(&client, &cfg, &tar_path, tar_len).await;
            let _ = std::fs::remove_file(&tar_path);
            let id = uploaded?;
            // marker first, then the event — if we die right here, resume works
            let _ = std::fs::write(
                dir.join("crunch.job"),
                serde_json::json!({ "id": id }).to_string(),
            );
            emit(
                app,
                take,
                dir,
                "queued",
                CrunchPatch {
                    job_id: Some(id.clone()),
                    ..Default::default()
                },
            );
            id
        }
    };

    poll(app, &client, &cfg, dir, take, &job_id).await
}

// ---- pieces ----

/// What goes in the tar: everything in the take dir except the full-res
/// camera master (edator's copy — crunch analyses `camera.proxy.mp4`), our
/// own outputs/markers, and dotfile junk. `keyframes/` rides along whole.
/// Returns (relative names for tar, total bytes for the pre-flight cap check).
fn upload_entries(dir: &Path) -> Result<(Vec<String>, u64), String> {
    let mut names = Vec::new();
    let mut total = 0u64;
    for e in std::fs::read_dir(dir).map_err(|e| e.to_string())?.flatten() {
        let name = e.file_name().to_string_lossy().into_owned();
        let Ok(meta) = e.metadata() else { continue };
        if name.starts_with('.')
            || name == "camera.mp4"
            || name == "crunch.json"
            || name == "crunch.job"
        {
            continue;
        }
        if meta.is_dir() {
            if name == "keyframes" {
                for k in std::fs::read_dir(e.path())
                    .map_err(|e| e.to_string())?
                    .flatten()
                {
                    if let Ok(m) = k.metadata() {
                        if m.is_file() {
                            total += m.len();
                        }
                    }
                }
                names.push(name);
            }
            continue; // no other dirs are part of the pack contract
        }
        total += meta.len();
        names.push(name);
    }
    names.sort();
    Ok((names, total))
}

/// Plain tar, no gzip — the media inside is already compressed, and the
/// upload is ~1s over the tailnet. COPYFILE_DISABLE stops BSD tar emitting
/// `._*` AppleDouble entries (crunch rejects anything but plain relative
/// names; roll-push.sh learned this the hard way).
fn make_tar(dir: &Path, tar_path: &Path, names: &[String]) -> Result<u64, String> {
    let out = std::process::Command::new("tar")
        .env("COPYFILE_DISABLE", "1")
        .arg("-C")
        .arg(dir)
        .arg("-cf")
        .arg(tar_path)
        .args(names)
        .output()
        .map_err(|e| format!("tar: {e}"))?;
    if !out.status.success() {
        return Err(format!(
            "tar failed: {}",
            String::from_utf8_lossy(&out.stderr).trim()
        ));
    }
    std::fs::metadata(tar_path)
        .map(|m| m.len())
        .map_err(|e| format!("tar output: {e}"))
}

fn origin_reachable(origin: &str) -> Result<SocketAddr, String> {
    let addr: SocketAddr = origin
        .parse()
        .map_err(|e| format!("bad crunch_origin '{origin}': {e}"))?;
    TcpStream::connect_timeout(&addr, Duration::from_secs(3)).map_err(|_| {
        format!(
            "can't reach crunch's origin {origin} — the upload goes direct \
             (packs >100MB can't go via Cloudflare), so it needs that box up"
        )
    })?;
    Ok(addr)
}

/// An HTTP client with the crunch hostname pinned to the tailnet origin (the
/// curl `--resolve` trick) — TLS still validates against the real hostname.
fn build_client(cfg: &Config, addr: SocketAddr) -> Result<reqwest::Client, String> {
    let host = cfg
        .crunch_url
        .split("://")
        .nth(1)
        .unwrap_or(&cfg.crunch_url)
        .split(['/', ':'])
        .next()
        .unwrap_or_default()
        .to_string();
    reqwest::Client::builder()
        .resolve(&host, addr)
        .connect_timeout(Duration::from_secs(10))
        .build()
        .map_err(|e| e.to_string())
}

/// POST the tar (streamed from disk, never held in RAM) → job id from the 202.
async fn upload(
    client: &reqwest::Client,
    cfg: &Config,
    tar_path: &Path,
    tar_len: u64,
) -> Result<String, String> {
    let file = tokio::fs::File::open(tar_path)
        .await
        .map_err(|e| format!("open tar: {e}"))?;
    let body = reqwest::Body::wrap_stream(tokio_util::io::ReaderStream::new(file));
    let part = reqwest::multipart::Part::stream_with_length(body, tar_len)
        .file_name("pack.tar")
        .mime_str("application/x-tar")
        .map_err(|e| e.to_string())?;
    let form = reqwest::multipart::Form::new().part("pack", part);
    let resp = client
        .post(format!("{}/pack", cfg.crunch_url))
        .bearer_auth(&cfg.crunch_api_key)
        .multipart(form)
        .send()
        .await
        .map_err(|e| format!("upload failed: {e}"))?;
    let code = resp.status();
    let text = resp.text().await.unwrap_or_default();
    if code.as_u16() != 202 {
        let short: String = text.chars().take(300).collect();
        return Err(format!("upload rejected ({code}): {short}"));
    }
    serde_json::from_str::<serde_json::Value>(&text)
        .ok()
        .and_then(|v| v["id"].as_str().map(String::from))
        .ok_or_else(|| format!("202 but no job id in response: {text}"))
}

/// Poll `/jobs/{id}` until it lands. Transient poll errors are retried (the
/// job keeps running server-side); MAX_POLL_ERRORS in a row gives up but
/// leaves `crunch.job` so a relaunch resumes.
async fn poll(
    app: &AppHandle,
    client: &reqwest::Client,
    cfg: &Config,
    dir: &Path,
    take: &str,
    job_id: &str,
) -> Result<(), String> {
    let url = format!("{}/jobs/{}", cfg.crunch_url, job_id);
    let mut errs = 0u32;
    loop {
        tokio::time::sleep(POLL_EVERY).await;
        let v = match fetch_json(client, cfg, &url).await {
            Ok(v) => {
                errs = 0;
                v
            }
            Err(e) => {
                errs += 1;
                if errs >= MAX_POLL_ERRORS {
                    return Err(format!(
                        "lost contact with crunch (job {job_id} may still be running — \
                         reopen the app to resume): {e}"
                    ));
                }
                continue;
            }
        };
        let status = v["status"].as_str().unwrap_or("");
        let stage = v["progress"]["stage"].as_str().map(String::from);
        match status {
            "completed" => {
                let result = v.get("result").cloned().unwrap_or(serde_json::Value::Null);
                if result.is_null() {
                    return Err("crunch reported completed but sent no result".into());
                }
                let pretty = serde_json::to_string_pretty(&result).map_err(|e| e.to_string())?;
                std::fs::write(dir.join("crunch.json"), pretty)
                    .map_err(|e| format!("write crunch.json: {e}"))?;
                let _ = std::fs::remove_file(dir.join("crunch.job"));
                emit(
                    app,
                    take,
                    dir,
                    "completed",
                    CrunchPatch {
                        job_id: Some(job_id.to_string()),
                        ..Default::default()
                    },
                );
                return Ok(());
            }
            "failed" => {
                // the job is dead — a retry means a fresh upload, so drop the marker
                let _ = std::fs::remove_file(dir.join("crunch.job"));
                let err = v["error"]
                    .as_str()
                    .unwrap_or("crunch failed (no error detail)")
                    .to_string();
                return Err(match &stage {
                    Some(s) => format!("{err} (died in {s})"),
                    None => err,
                });
            }
            // queued | processing → live status for the UI (ocr carries
            // done/total for a real progress bar; other stages are label-only)
            other => emit(
                app,
                take,
                dir,
                if other == "queued" {
                    "queued"
                } else {
                    "processing"
                },
                CrunchPatch {
                    stage,
                    done: v["progress"]["done"].as_u64(),
                    total: v["progress"]["total"].as_u64(),
                    job_id: Some(job_id.to_string()),
                    ..Default::default()
                },
            ),
        }
    }
}

async fn fetch_json(
    client: &reqwest::Client,
    cfg: &Config,
    url: &str,
) -> Result<serde_json::Value, String> {
    client
        .get(url)
        .bearer_auth(&cfg.crunch_api_key)
        .timeout(Duration::from_secs(30))
        .send()
        .await
        .map_err(|e| e.to_string())?
        .error_for_status()
        .map_err(|e| e.to_string())?
        .json()
        .await
        .map_err(|e| e.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn upload_entries_excludes_master_and_markers() {
        let dir = std::env::temp_dir().join(format!("crunch-test-{}", std::process::id()));
        let kf = dir.join("keyframes");
        std::fs::create_dir_all(&kf).unwrap();
        for f in [
            "manifest.json",
            "camera.mp4",
            "camera.proxy.mp4",
            "screen.mp4",
            "crunch.json",
            "crunch.job",
            ".DS_Store",
        ] {
            std::fs::write(dir.join(f), b"x").unwrap();
        }
        std::fs::write(kf.join("100.png"), [0u8; 10]).unwrap();
        let (names, total) = upload_entries(&dir).unwrap();
        assert_eq!(
            names,
            vec![
                "camera.proxy.mp4",
                "keyframes",
                "manifest.json",
                "screen.mp4"
            ]
        );
        assert_eq!(total, 3 + 10); // three 1-byte files + the keyframe
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn tar_is_plain_relative_paths() {
        let dir = std::env::temp_dir().join(format!("crunch-tar-{}", std::process::id()));
        std::fs::create_dir_all(dir.join("keyframes")).unwrap();
        std::fs::write(dir.join("manifest.json"), b"{}").unwrap();
        std::fs::write(dir.join("keyframes/1.png"), b"p").unwrap();
        let tar = dir.join("out.tar");
        let names = vec!["keyframes".to_string(), "manifest.json".to_string()];
        let len = make_tar(&dir, &tar, &names).unwrap();
        assert!(len > 0);
        let out = std::process::Command::new("tar")
            .arg("-tf")
            .arg(&tar)
            .output()
            .unwrap();
        let listing = String::from_utf8_lossy(&out.stdout);
        for line in listing.lines() {
            assert!(
                !line.starts_with('/') && !line.starts_with("./") && !line.contains(".."),
                "bad entry: {line}"
            );
            assert!(!line.contains("._"), "AppleDouble leaked: {line}");
        }
        assert!(listing.contains("manifest.json"));
        assert!(listing.contains("keyframes/1.png"));
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn config_defaults_fill_in() {
        let c: Config = serde_json::from_str(r#"{"crunch_api_key":"k"}"#).unwrap();
        assert_eq!(c.crunch_url, "https://crunch.stumason.dev");
        assert_eq!(c.crunch_origin, "159.195.194.97:443");
    }

    /// Full transport round-trip against LIVE crunch (tailnet + real config +
    /// a real pack dir required), driving the same functions production uses.
    /// Run: CRUNCH_E2E_DIR=<take dir> cargo test e2e -- --ignored --nocapture
    #[tokio::test]
    #[ignore]
    async fn e2e_upload_and_poll() {
        let dir = PathBuf::from(std::env::var("CRUNCH_E2E_DIR").expect("set CRUNCH_E2E_DIR"));
        let cfg = load_config().expect("~/.config/roll/config.json");
        let addr = origin_reachable(&cfg.crunch_origin).expect("origin reachable");
        let client = build_client(&cfg, addr).expect("client");

        let (names, total) = upload_entries(&dir).expect("entries");
        assert!(names.contains(&"manifest.json".to_string()));
        assert!(
            !names.contains(&"camera.mp4".to_string()),
            "master must stay local"
        );
        eprintln!("tar list: {names:?} ({total} bytes)");

        let tar = std::env::temp_dir().join("crunch-e2e.tar");
        let len = make_tar(&dir, &tar, &names).expect("tar");
        let id = upload(&client, &cfg, &tar, len)
            .await
            .expect("upload → job id");
        let _ = std::fs::remove_file(&tar);
        eprintln!("job {id} accepted (202), polling…");

        let url = format!("{}/jobs/{}", cfg.crunch_url, id);
        for i in 0..240 {
            tokio::time::sleep(POLL_EVERY).await;
            let v = fetch_json(&client, &cfg, &url).await.expect("poll");
            let status = v["status"].as_str().unwrap_or("?");
            eprintln!("[{i}] {status} {}", v["progress"]);
            match status {
                "completed" => {
                    let result = v.get("result").cloned().expect("result body");
                    assert!(
                        result.is_object(),
                        "result should be the crunch.json object"
                    );
                    std::fs::write(
                        dir.join("crunch.json"),
                        serde_json::to_string_pretty(&result).unwrap(),
                    )
                    .expect("write crunch.json");
                    eprintln!(
                        "crunch.json landed ({} top-level keys)",
                        result.as_object().unwrap().len()
                    );
                    return;
                }
                "failed" => panic!("crunch failed: {} (progress {})", v["error"], v["progress"]),
                _ => {}
            }
        }
        panic!("timed out waiting for job {id}");
    }
}
