#[cfg(target_os = "android")]
use anyhow::Context;
use anyhow::Result;
use anyhow::anyhow;
use codex_config::types::McpServerEnvVar;
use reqwest::ClientBuilder;
use reqwest::header::HeaderMap;
use reqwest::header::HeaderName;
use reqwest::header::HeaderValue;
use std::collections::HashMap;
use std::env;
use std::ffi::OsString;

pub(crate) fn create_env_for_mcp_server(
    extra_env: Option<HashMap<OsString, OsString>>,
    env_vars: &[McpServerEnvVar],
) -> Result<HashMap<OsString, OsString>> {
    let additional_env_vars = local_stdio_env_var_names(env_vars)?;
    let mut child_env = DEFAULT_ENV_VARS
        .iter()
        .copied()
        .chain(ANDROID_ENV_VARS.iter().copied())
        .chain(additional_env_vars)
        .filter_map(|var| env::var_os(var).map(|value| (OsString::from(var), value)))
        .chain(extra_env.unwrap_or_default())
        .collect();
    append_trusted_android_preload(&mut child_env);
    Ok(child_env)
}

#[cfg(target_os = "android")]
fn append_trusted_android_preload(child_env: &mut HashMap<OsString, OsString>) {
    child_env.remove(std::ffi::OsStr::new("LD_PRELOAD"));
    if let Some(value) = trusted_android_preload(
        env::var_os("LD_PRELOAD"),
        env::var_os("HAPPY_CODEX_TERMUX_PRELOAD"),
        env::var_os("PREFIX"),
    ) {
        child_env.insert(OsString::from("LD_PRELOAD"), value);
    }
}

#[cfg(not(target_os = "android"))]
fn append_trusted_android_preload(_child_env: &mut HashMap<OsString, OsString>) {}

#[cfg(any(target_os = "android", test))]
fn trusted_android_preload(
    actual: Option<OsString>,
    expected: Option<OsString>,
    prefix: Option<OsString>,
) -> Option<OsString> {
    match (actual, expected, prefix) {
        (Some(actual), Some(expected), Some(prefix))
            if actual == expected
                && std::path::Path::new(&actual)
                    == std::path::Path::new(&prefix).join("lib/libtermux-exec.so") =>
        {
            Some(actual)
        }
        _ => None,
    }
}

pub(crate) fn create_env_overlay_for_remote_mcp_server(
    extra_env: Option<HashMap<OsString, OsString>>,
    env_vars: &[McpServerEnvVar],
) -> HashMap<OsString, OsString> {
    // Remote stdio should inherit PATH/HOME/etc. from the executor side, not
    // from the orchestrator process. Only forward variables explicitly named
    // by the MCP config plus literal env overrides from that config.
    env_vars
        .iter()
        .filter(|var| !var.is_remote_source())
        .filter_map(|var| env::var_os(var.name()).map(|value| (OsString::from(var.name()), value)))
        .chain(extra_env.unwrap_or_default())
        .collect()
}

pub(crate) fn remote_mcp_env_var_names(env_vars: &[McpServerEnvVar]) -> Vec<String> {
    env_vars
        .iter()
        .filter(|var| var.is_remote_source())
        .map(|var| var.name().to_string())
        .collect()
}

fn local_stdio_env_var_names(env_vars: &[McpServerEnvVar]) -> Result<impl Iterator<Item = &str>> {
    if let Some(remote_var) = env_vars.iter().find(|var| var.is_remote_source()) {
        return Err(anyhow!(
            "env_vars entry `{}` uses source `remote`, which requires remote MCP stdio",
            remote_var.name()
        ));
    }
    Ok(env_vars.iter().map(McpServerEnvVar::name))
}

pub(crate) fn build_default_headers(
    http_headers: Option<HashMap<String, String>>,
    env_http_headers: Option<HashMap<String, String>>,
) -> Result<HeaderMap> {
    let mut headers = HeaderMap::new();

    if let Some(static_headers) = http_headers {
        for (name, value) in static_headers {
            let header_name = match HeaderName::from_bytes(name.as_bytes()) {
                Ok(name) => name,
                Err(err) => {
                    tracing::warn!("invalid HTTP header name `{name}`: {err}");
                    continue;
                }
            };
            let header_value = match HeaderValue::from_str(value.as_str()) {
                Ok(value) => value,
                Err(err) => {
                    tracing::warn!("invalid HTTP header value for `{name}`: {err}");
                    continue;
                }
            };
            headers.insert(header_name, header_value);
        }
    }

    if let Some(env_headers) = env_http_headers {
        for (name, env_var) in env_headers {
            if let Ok(value) = env::var(&env_var) {
                if value.trim().is_empty() {
                    continue;
                }

                let header_name = match HeaderName::from_bytes(name.as_bytes()) {
                    Ok(name) => name,
                    Err(err) => {
                        tracing::warn!("invalid HTTP header name `{name}`: {err}");
                        continue;
                    }
                };

                let header_value = match HeaderValue::from_str(value.as_str()) {
                    Ok(value) => value,
                    Err(err) => {
                        tracing::warn!(
                            "invalid HTTP header value read from {env_var} for `{name}`: {err}"
                        );
                        continue;
                    }
                };
                headers.insert(header_name, header_value);
            }
        }
    }

    Ok(headers)
}

pub(crate) fn apply_default_headers(
    builder: ClientBuilder,
    default_headers: &HeaderMap,
) -> ClientBuilder {
    if default_headers.is_empty() {
        builder
    } else {
        builder.default_headers(default_headers.clone())
    }
}

/// Android command-line processes do not have the Java context expected by
/// rustls-platform-verifier. Explicit roots keep remote MCP TLS independent of
/// Android framework initialization.
#[cfg(target_os = "android")]
pub(crate) fn apply_platform_tls(builder: ClientBuilder) -> Result<ClientBuilder> {
    Ok(builder.tls_certs_only(webpki_root_certificates()?))
}

#[cfg(not(target_os = "android"))]
pub(crate) fn apply_platform_tls(builder: ClientBuilder) -> Result<ClientBuilder> {
    Ok(builder)
}

#[cfg(target_os = "android")]
fn webpki_root_certificates() -> Result<Vec<reqwest::Certificate>> {
    webpki_root_certs::TLS_SERVER_ROOT_CERTS
        .iter()
        .map(|der| {
            reqwest::Certificate::from_der(der.as_ref()).context("invalid embedded TLS root")
        })
        .collect()
}

#[cfg(unix)]
pub(crate) const DEFAULT_ENV_VARS: &[&str] = &[
    "HOME",
    "LOGNAME",
    "PATH",
    "SHELL",
    "USER",
    "__CF_USER_TEXT_ENCODING",
    "LANG",
    "LC_ALL",
    "TERM",
    "TMPDIR",
    "TZ",
];

/// Termux helpers need these values in addition to the normal Unix allowlist.
/// PREFIX locates the Termux tree. LD_PRELOAD is handled separately and only
/// forwarded when it matches the value pinned by the Happy helper.
#[cfg(target_os = "android")]
pub(crate) const ANDROID_ENV_VARS: &[&str] = &[
    "PREFIX",
    "TERMUX_VERSION",
    "NPM_CONFIG_PREFIX",
    "XDG_RUNTIME_DIR",
    "XDG_DATA_HOME",
    "XDG_CACHE_HOME",
    "XDG_CONFIG_HOME",
];

#[cfg(not(target_os = "android"))]
pub(crate) const ANDROID_ENV_VARS: &[&str] = &[];

#[cfg(windows)]
pub(crate) const DEFAULT_ENV_VARS: &[&str] =
    codex_protocol::shell_environment::WINDOWS_CORE_ENV_VARS;

#[cfg(test)]
mod tests {
    use super::*;
    use pretty_assertions::assert_eq;

    use serial_test::serial;
    use std::ffi::OsStr;

    struct EnvVarGuard {
        key: String,
        original: Option<OsString>,
    }

    impl EnvVarGuard {
        fn set(key: &str, value: impl AsRef<OsStr>) -> Self {
            let original = std::env::var_os(key);
            unsafe {
                std::env::set_var(key, value.as_ref());
            }
            Self {
                key: key.to_string(),
                original,
            }
        }
    }

    impl Drop for EnvVarGuard {
        fn drop(&mut self) {
            if let Some(value) = &self.original {
                unsafe {
                    std::env::set_var(&self.key, value);
                }
            } else {
                unsafe {
                    std::env::remove_var(&self.key);
                }
            }
        }
    }

    #[tokio::test]
    async fn create_env_honors_overrides() {
        let value = "custom".to_string();
        let expected = OsString::from(&value);
        let env = create_env_for_mcp_server(
            Some(HashMap::from([(OsString::from("TZ"), expected.clone())])),
            &[],
        )
        .expect("local MCP env should build");
        assert_eq!(env.get(OsStr::new("TZ")), Some(&expected));
    }

    #[test]
    fn trusted_android_preload_requires_an_exact_helper_pin() {
        let prefix = OsString::from("/data/data/com.termux/files/usr");
        let preload = OsString::from("/data/data/com.termux/files/usr/lib/libtermux-exec.so");

        assert_eq!(
            trusted_android_preload(
                Some(preload.clone()),
                Some(preload.clone()),
                Some(prefix.clone()),
            ),
            Some(preload.clone())
        );
        assert_eq!(
            trusted_android_preload(
                Some(preload.clone()),
                Some(OsString::from("/tmp/other.so")),
                Some(prefix),
            ),
            None
        );
        assert_eq!(
            trusted_android_preload(
                Some(preload),
                Some(OsString::from(
                    "/data/data/com.termux/files/usr/lib/libtermux-exec.so",
                )),
                Some(OsString::from("/different/prefix")),
            ),
            None
        );
        assert_eq!(trusted_android_preload(None, None, None), None);
    }

    #[test]
    #[serial(extra_rmcp_env)]
    fn create_env_includes_additional_whitelisted_variables() {
        let custom_var = "EXTRA_RMCP_ENV";
        let value = "from-env";
        let expected = OsString::from(value);
        let _guard = EnvVarGuard::set(custom_var, value);
        let env = create_env_for_mcp_server(/*extra_env*/ None, &[custom_var.into()])
            .expect("local MCP env should build");
        assert_eq!(env.get(OsStr::new(custom_var)), Some(&expected));
    }

    #[test]
    #[serial(extra_rmcp_env)]
    fn create_remote_env_overlay_only_forwards_explicit_variables() {
        let default_var = DEFAULT_ENV_VARS[0];
        let custom_var = "EXTRA_REMOTE_RMCP_ENV";
        let custom_value = OsString::from("from-env");
        let _default_guard = EnvVarGuard::set(default_var, "from-default");
        let _custom_guard = EnvVarGuard::set(custom_var, &custom_value);

        let env =
            create_env_overlay_for_remote_mcp_server(/*extra_env*/ None, &[custom_var.into()]);

        assert_eq!(
            env,
            HashMap::from([(OsString::from(custom_var), custom_value)])
        );
    }

    #[test]
    #[serial(extra_rmcp_env)]
    fn create_remote_env_overlay_does_not_copy_remote_source_variables() {
        let remote_var = "REMOTE_ONLY_RMCP_ENV";
        let local_var = "LOCAL_RMCP_ENV";
        let local_value = OsString::from("from-local-env");
        let _remote_guard = EnvVarGuard::set(remote_var, "should-not-be-copied");
        let _local_guard = EnvVarGuard::set(local_var, &local_value);

        let env = create_env_overlay_for_remote_mcp_server(
            /*extra_env*/ None,
            &[
                McpServerEnvVar::Config {
                    name: remote_var.to_string(),
                    source: Some("remote".to_string()),
                },
                McpServerEnvVar::Config {
                    name: local_var.to_string(),
                    source: Some("local".to_string()),
                },
            ],
        );

        assert_eq!(
            env,
            HashMap::from([(OsString::from(local_var), local_value)])
        );
    }

    #[test]
    fn remote_mcp_env_var_names_returns_remote_source_names() {
        let names = remote_mcp_env_var_names(&[
            "LEGACY".into(),
            McpServerEnvVar::Config {
                name: "LOCAL".to_string(),
                source: Some("local".to_string()),
            },
            McpServerEnvVar::Config {
                name: "REMOTE".to_string(),
                source: Some("remote".to_string()),
            },
        ]);

        assert_eq!(names, vec!["REMOTE".to_string()]);
    }

    #[test]
    fn create_local_env_rejects_remote_source_variables() {
        let err = create_env_for_mcp_server(
            /*extra_env*/ None,
            &[McpServerEnvVar::Config {
                name: "REMOTE".to_string(),
                source: Some("remote".to_string()),
            }],
        )
        .expect_err("remote source should require remote stdio");

        assert!(
            err.to_string().contains("requires remote MCP stdio"),
            "unexpected error: {err}"
        );
    }

    #[cfg(unix)]
    #[test]
    #[serial(extra_rmcp_env)]
    fn create_env_preserves_path_when_it_is_not_utf8() {
        use std::os::unix::ffi::OsStrExt;

        let raw_path = std::ffi::OsStr::from_bytes(b"/tmp/codex-\xFF/bin");
        let expected = raw_path.to_os_string();
        let _guard = EnvVarGuard::set("PATH", raw_path);

        let env =
            create_env_for_mcp_server(/*extra_env*/ None, &[]).expect("local MCP env should build");

        assert_eq!(env.get(OsStr::new("PATH")), Some(&expected));
    }
}
