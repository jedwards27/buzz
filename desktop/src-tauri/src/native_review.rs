use serde::Serialize;
use url::Url;

const ENABLE_ENV: &str = "BUZZ_NATIVE_REVIEW";
const RELAY_ENV: &str = "BUZZ_RELAY_URL";
const PUBKEY_ENV: &str = "BUZZ_REVIEW_PUBKEY";
const PROBE_ENV: &str = "BUZZ_NATIVE_REVIEW_PROBE_URL";

#[derive(Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct NativeReviewBootstrap {
    relay_url: String,
    pubkey: String,
    probe_url: String,
}

fn is_loopback_url(value: &str, schemes: &[&str]) -> bool {
    Url::parse(value).is_ok_and(|url| {
        schemes.contains(&url.scheme())
            && url
                .host_str()
                .is_some_and(|host| matches!(host, "localhost" | "127.0.0.1" | "::1"))
    })
}

fn bootstrap_from_values(
    enabled: Option<&str>,
    relay_url: Option<String>,
    pubkey: Option<String>,
    probe_url: Option<String>,
) -> Result<NativeReviewBootstrap, String> {
    if enabled != Some("1") {
        return Err("native review runtime is not enabled".into());
    }
    let relay_url = relay_url.ok_or_else(|| format!("missing {RELAY_ENV}"))?;
    let pubkey = pubkey.ok_or_else(|| format!("missing {PUBKEY_ENV}"))?;
    let probe_url = probe_url.ok_or_else(|| format!("missing {PROBE_ENV}"))?;
    if !is_loopback_url(&relay_url, &["ws", "http"]) {
        return Err(format!("{RELAY_ENV} must be a loopback ws/http URL"));
    }
    if pubkey.len() != 64 || !pubkey.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        return Err(format!("{PUBKEY_ENV} must be a 64-character hex pubkey"));
    }
    if !is_loopback_url(&probe_url, &["http"]) {
        return Err(format!("{PROBE_ENV} must be a loopback http URL"));
    }
    Ok(NativeReviewBootstrap {
        relay_url,
        pubkey,
        probe_url,
    })
}

#[tauri::command]
pub fn get_native_review_bootstrap() -> Result<NativeReviewBootstrap, String> {
    bootstrap_from_values(
        std::env::var(ENABLE_ENV).ok().as_deref(),
        std::env::var(RELAY_ENV).ok(),
        std::env::var(PUBKEY_ENV).ok(),
        std::env::var(PROBE_ENV).ok(),
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    fn valid_bootstrap(enabled: Option<&str>) -> Result<NativeReviewBootstrap, String> {
        bootstrap_from_values(
            enabled,
            Some("ws://127.0.0.1:3030".into()),
            Some("ab".repeat(32)),
            Some("http://localhost:8765/snapshot?token=secret".into()),
        )
    }

    #[test]
    fn bootstrap_is_unavailable_without_explicit_runtime_marker() {
        assert_eq!(
            valid_bootstrap(None).unwrap_err(),
            "native review runtime is not enabled"
        );
    }

    #[test]
    fn bootstrap_accepts_complete_loopback_configuration() {
        assert_eq!(
            valid_bootstrap(Some("1")).unwrap(),
            NativeReviewBootstrap {
                relay_url: "ws://127.0.0.1:3030".into(),
                pubkey: "ab".repeat(32),
                probe_url: "http://localhost:8765/snapshot?token=secret".into(),
            }
        );
    }

    #[test]
    fn bootstrap_rejects_non_loopback_and_malformed_values() {
        let invalid_relay = bootstrap_from_values(
            Some("1"),
            Some("wss://relay.example".into()),
            Some("ab".repeat(32)),
            Some("http://localhost:8765".into()),
        );
        assert!(invalid_relay.unwrap_err().contains(RELAY_ENV));

        let invalid_pubkey = bootstrap_from_values(
            Some("1"),
            Some("ws://localhost:3030".into()),
            Some("not-a-pubkey".into()),
            Some("http://localhost:8765".into()),
        );
        assert!(invalid_pubkey.unwrap_err().contains(PUBKEY_ENV));

        let invalid_probe = bootstrap_from_values(
            Some("1"),
            Some("ws://localhost:3030".into()),
            Some("ab".repeat(32)),
            Some("https://example.com/collect".into()),
        );
        assert!(invalid_probe.unwrap_err().contains(PROBE_ENV));
    }
}
