#![cfg(feature = "qualification")]
use std::{
    io::{ErrorKind, Read, Write},
    os::unix::net::UnixStream,
    path::PathBuf,
    process::{Command, Stdio},
    sync::atomic::{AtomicU64, Ordering},
    thread::JoinHandle,
    time::{Duration, Instant},
};
static NEXT: AtomicU64 = AtomicU64::new(0);
const STARTUP_TIMEOUT: Duration = Duration::from_secs(3);
const DIAGNOSTIC_BYTES: usize = 2048;

fn capture(mut reader: impl Read + Send + 'static) -> JoinHandle<Vec<u8>> {
    std::thread::spawn(move || {
        let mut retained = Vec::new();
        let mut buffer = [0; 512];
        loop {
            match reader.read(&mut buffer) {
                Ok(0) => break,
                Ok(n) => {
                    let keep = n.min(DIAGNOSTIC_BYTES - retained.len());
                    retained.extend_from_slice(&buffer[..keep]);
                    // Continue draining once full, so child output cannot deadlock.
                }
                Err(error) if error.kind() == ErrorKind::Interrupted => continue,
                Err(_) => break,
            }
        }
        retained
    })
}

fn safe_diagnostics(bytes: &[u8]) -> String {
    // Never print raw child output, paths, credentials or panic payloads.
    let allowed = [
        "fixture startup exit requested",
        "fixture control epoch stopped",
    ];
    let lines = bytes
        .split(|byte| *byte == b'\n')
        .filter_map(|line| {
            allowed
                .iter()
                .find(|value| value.as_bytes() == line)
                .copied()
        })
        .collect::<Vec<_>>();
    if lines.is_empty() {
        format!(
            "{} diagnostic bytes retained; contents withheld",
            bytes.len()
        )
    } else {
        lines.join("; ")
    }
}

struct Fixture {
    child: std::process::Child,
    dir: PathBuf,
    socket: PathBuf,
    diagnostics: Vec<JoinHandle<Vec<u8>>>,
}

impl Fixture {
    fn new(mode: &str) -> Self {
        Self::spawn(mode)
            .ready(STARTUP_TIMEOUT, |_| {})
            .unwrap_or_else(|reason| panic!("fixture startup readiness probe: {reason}"))
    }

    fn spawn(mode: &str) -> Self {
        let dir = std::env::temp_dir().join(format!(
            "edge-uds-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        std::fs::create_dir(&dir).unwrap();
        let socket = dir.join("edge.sock");
        let child = Command::new(env!("CARGO_BIN_EXE_edge-qualification-fixture"))
            .args([
                socket.to_str().unwrap(),
                dir.join("metrics").to_str().unwrap(),
                "fixture-agent",
                mode,
            ])
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap_or_else(|error| {
                let _ = std::fs::remove_dir_all(&dir);
                panic!("fixture spawn: {:?}", error.kind())
            });
        // Own the child before capture/readiness can fail, so Drop covers startup.
        let mut f = Self {
            child,
            dir,
            socket,
            diagnostics: Vec::new(),
        };
        f.diagnostics.push(capture(f.child.stdout.take().unwrap()));
        f.diagnostics.push(capture(f.child.stderr.take().unwrap()));
        f
    }

    fn ready(mut self, timeout: Duration, on_retry: impl FnMut(ErrorKind)) -> Result<Self, String> {
        if let Err(reason) = self.wait_for_readiness(timeout, on_retry) {
            self.stop(true);
            let diagnostics = self.finish_diagnostics();
            return Err(format!("{reason}; {diagnostics}"));
        }
        Ok(self)
    }

    fn wait_for_readiness(
        &mut self,
        timeout: Duration,
        mut on_retry: impl FnMut(ErrorKind),
    ) -> Result<(), String> {
        let deadline = Instant::now() + timeout;
        loop {
            self.check_child()?;
            let remaining = Self::remaining(deadline)?;
            match UnixStream::connect(&self.socket) {
                Ok(mut stream) => {
                    stream
                        .set_write_timeout(Some(remaining))
                        .map_err(|error| Self::io_failure("probe write timeout", error))?;
                    // An unknown route returns an authored 404 before Core work.
                    // Do not use an event subscription or mutate fixture counters.
                    stream
                        .write_all(&get("/fixture-startup-probe"))
                        .map_err(|error| Self::io_failure("probe write", error))?;
                    let mut response = Vec::new();
                    let mut buffer = [0; 512];
                    loop {
                        self.check_child()?;
                        stream
                            .set_read_timeout(Some(Self::remaining(deadline)?))
                            .map_err(|error| Self::io_failure("probe read timeout", error))?;
                        let n = stream
                            .read(&mut buffer)
                            .map_err(|error| Self::io_failure("probe read", error))?;
                        if n == 0 {
                            break;
                        }
                        if response.len() + n > 1024 {
                            return Err("oversized startup probe response".into());
                        }
                        response.extend_from_slice(&buffer[..n]);
                    }
                    if !response.starts_with(b"HTTP/1.1 404 ")
                        || !response
                            .windows(b"\"edge.unknown_route\"".len())
                            .any(|part| part == b"\"edge.unknown_route\"")
                    {
                        return Err("unexpected startup probe response".into());
                    }
                    // EOF plus drop completes the one-request connection before
                    // returning; no live startup socket/subscription is retained.
                    drop(stream);
                    self.check_child()?;
                    Self::remaining(deadline)?;
                    return Ok(());
                }
                Err(error)
                    if matches!(
                        error.kind(),
                        ErrorKind::NotFound | ErrorKind::ConnectionRefused
                    ) =>
                {
                    on_retry(error.kind());
                    std::thread::sleep(remaining.min(Duration::from_millis(5)));
                }
                Err(error) => return Err(Self::io_failure("probe connect", error)),
            }
        }
    }

    fn check_child(&mut self) -> Result<(), String> {
        match self
            .child
            .try_wait()
            .map_err(|error| Self::io_failure("child observation", error))?
        {
            Some(status) => Err(format!("child exited before readiness: {status}")),
            None => Ok(()),
        }
    }

    fn remaining(deadline: Instant) -> Result<Duration, String> {
        deadline
            .checked_duration_since(Instant::now())
            .filter(|remaining| !remaining.is_zero())
            .ok_or_else(|| "startup deadline exceeded".into())
    }

    fn io_failure(stage: &str, error: std::io::Error) -> String {
        format!("{stage}: {:?}, OS {:?}", error.kind(), error.raw_os_error())
    }

    fn connect(&self) -> UnixStream {
        self.connect_at("ordinary request connection")
    }

    fn connect_at(&self, stage: &str) -> UnixStream {
        let stream = UnixStream::connect(&self.socket).unwrap_or_else(|error| {
            panic!(
                "fixture {stage}: {:?}, OS {:?}",
                error.kind(),
                error.raw_os_error()
            )
        });
        stream
            .set_read_timeout(Some(Duration::from_secs(3)))
            .unwrap();
        stream
    }

    fn request(&self, request: &[u8]) -> Vec<u8> {
        self.request_at(request, "ordinary request connection")
    }

    fn request_at(&self, request: &[u8], stage: &str) -> Vec<u8> {
        let mut stream = self.connect_at(stage);
        stream.write_all(request).unwrap();
        let mut response = Vec::new();
        if let Err(error) = stream.read_to_end(&mut response) {
            assert!(
                error.kind() == std::io::ErrorKind::ConnectionReset && !response.is_empty(),
                "bounded connection rejection"
            );
        }
        response
    }

    fn stop(&mut self, immediate: bool) -> bool {
        if let Some(mut stdin) = self.child.stdin.take()
            && !immediate
        {
            let _ = stdin.write_all(b"\n");
        }
        let deadline = Instant::now() + Duration::from_secs(3);
        loop {
            match self.child.try_wait() {
                Ok(Some(_)) => return false,
                Ok(None) if !immediate && Instant::now() < deadline => {
                    std::thread::sleep(Duration::from_millis(5));
                }
                _ => {
                    let _ = self.child.kill();
                    let _ = self.child.wait();
                    return !immediate;
                }
            }
        }
    }

    fn finish_diagnostics(&mut self) -> String {
        self.diagnostics
            .drain(..)
            .map(|reader| match reader.join() {
                Ok(bytes) => safe_diagnostics(&bytes),
                Err(_) => "diagnostic capture failed".into(),
            })
            .collect::<Vec<_>>()
            .join("; ")
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        let timed_out = self.stop(false);
        let diagnostics = self.finish_diagnostics();
        let _ = std::fs::remove_dir_all(&self.dir);
        if std::thread::panicking() {
            eprintln!("fixture failure diagnostics: {diagnostics}");
        } else if timed_out {
            panic!("fixture shutdown exceeded bound; {diagnostics}");
        }
    }
}

fn get(path: &str) -> Vec<u8> {
    format!("GET {path} HTTP/1.1\r\nHost: localhost\r\n\r\n").into_bytes()
}

fn post(body: &str, media: &str) -> Vec<u8> {
    format!("POST /v1/commands HTTP/1.1\r\nHost: localhost\r\nContent-Type: {media}\r\nContent-Length: {}\r\n\r\n{body}",body.len()).into_bytes()
}

fn command(id: &str, extra: &str) -> String {
    format!(
        r#"{{"request_id":"request-{id}","command_id":"{id}","expected_agent_instance_id":"fixture-agent","device_id":"fixture.device","expected_binding_instance_id":"fixture-binding-a","not_after_agent_uptime_ms":50000,"kind":"synthetic.signal","timeout_ms":10000,"payload":{{"scenario":"success","token":1}}{extra}}}"#
    )
}

fn status(response: &[u8]) -> u16 {
    std::str::from_utf8(response)
        .unwrap()
        .split_whitespace()
        .nth(1)
        .unwrap()
        .parse()
        .unwrap()
}

fn wait_for_path(path: &std::path::Path) {
    let deadline = Instant::now() + STARTUP_TIMEOUT;
    while !path.exists() {
        assert!(Instant::now() < deadline, "fixture-owned path deadline");
        std::thread::sleep(Duration::from_millis(5));
    }
}

#[test]
fn startup_readiness_waits_for_http_not_socket_path() {
    let mut f = Fixture::spawn("startup-paused");
    wait_for_path(&f.socket);
    assert_eq!(
        UnixStream::connect(&f.socket).err().unwrap().kind(),
        ErrorKind::ConnectionRefused
    );
    let mut release = f.child.stdin.take().unwrap();
    let (retry, retried) = std::sync::mpsc::sync_channel(1);
    let (finished, completion) = std::sync::mpsc::sync_channel(1);
    std::thread::scope(|scope| {
        let startup = scope.spawn(move || {
            let f = f
                .ready(STARTUP_TIMEOUT, |kind| {
                    let _ = retry.try_send(kind);
                })
                .unwrap();
            // The old path-existence rule gets here before listen and fails at
            // exactly the original event test's first client connection stage.
            let _stream = f.connect_at("initial event-stream connection");
            finished.send(()).unwrap();
            f
        });
        let observed_retry = retried.recv_timeout(Duration::from_secs(1));
        if observed_retry.is_err() {
            // Join first to preserve a labeled pre-fix connection failure.
            let _ = startup.join().unwrap();
            panic!("startup returned without observing the bound/not-listening endpoint");
        }
        assert_eq!(observed_retry.unwrap(), ErrorKind::ConnectionRefused);
        assert!(matches!(
            completion.try_recv(),
            Err(std::sync::mpsc::TryRecvError::Empty)
        ));
        release.write_all(b"\n\n").unwrap();
        let mut f = startup.join().unwrap();
        f.child.stdin = Some(release);
        assert_eq!(status(&f.request(&get("/v1/health"))), 200);
    });
}

#[test]
fn startup_child_exit_is_reported_and_reaped_without_deadline_wait() {
    let f = Fixture::spawn("startup-exit");
    let dir = f.dir.clone();
    let pid = f.child.id();
    let reason = f
        .ready(STARTUP_TIMEOUT, |_| {})
        .err()
        .expect("child must exit");
    assert!(reason.contains("child exited before readiness"), "{reason}");
    assert!(reason.contains("23"), "{reason}");
    assert!(
        reason.contains("fixture startup exit requested"),
        "{reason}"
    );
    assert!(!dir.exists(), "startup exit left fixture state");
    assert!(
        !std::path::Path::new(&format!("/proc/{pid}")).exists(),
        "startup child not reaped"
    );
}

#[test]
fn startup_deadline_kills_reaps_and_removes_unready_fixture() {
    let f = Fixture::spawn("startup-paused");
    wait_for_path(&f.socket);
    let dir = f.dir.clone();
    let pid = f.child.id();
    let reason = f
        .ready(Duration::from_millis(100), |_| {})
        .err()
        .expect("never released");
    assert!(reason.contains("startup deadline exceeded"), "{reason}");
    assert!(!dir.exists(), "startup timeout left fixture state");
    assert!(
        !std::path::Path::new(&format!("/proc/{pid}")).exists(),
        "startup child not reaped"
    );
}

#[test]
fn startup_listening_without_http_is_not_ready_and_is_cleaned_up() {
    let mut f = Fixture::spawn("startup-paused");
    wait_for_path(&f.socket);
    f.child.stdin.as_mut().unwrap().write_all(b"\n").unwrap();
    wait_for_path(&f.socket.with_extension("listening"));
    // Raw connect succeeds, but the second gate has not started Hyper.
    drop(UnixStream::connect(&f.socket).unwrap());
    let dir = f.dir.clone();
    let pid = f.child.id();
    let reason = f
        .ready(Duration::from_millis(100), |_| {})
        .err()
        .expect("listening alone is insufficient");
    assert!(reason.contains("probe read"), "{reason}");
    assert!(!dir.exists(), "HTTP readiness failure left fixture state");
    assert!(
        !std::path::Path::new(&format!("/proc/{pid}")).exists(),
        "startup child not reaped"
    );
}

#[test]
fn startup_probe_leaves_command_and_control_counters_untouched() {
    let f = Fixture::new("small");
    wait_for_path(&f.dir.join("metrics"));
    let metrics = std::fs::read_to_string(f.dir.join("metrics")).unwrap();
    assert_eq!(metrics.lines().take(3).collect::<Vec<_>>(), ["0", "0", "0"]);
    assert!(metrics.lines().any(|line| line == "requests_total=0"));
    assert!(metrics.lines().any(|line| line == "retained=0"));
    assert!(metrics.lines().any(|line| line == "command_high_water=0"));
    // Both small-mode connections must be usable after startup; the probe may
    // not leave a live connection consuming either slot or an event subscriber.
    let mut first = f.connect_at("initial event-stream connection");
    first.write_all(&get("/v1/events")).unwrap();
    let mut response = [0; 1024];
    let n = first.read(&mut response).unwrap();
    assert_eq!(status(&response[..n]), 200);
    assert_eq!(
        status(&f.request_at(&get("/v1/events"), "second-subscriber request")),
        503
    );
}

#[test]
fn post_readiness_connection_refusal_remains_a_hard_failure() {
    let mut f = Fixture::new("");
    f.child.kill().unwrap();
    f.child.wait().unwrap();
    assert!(
        f.socket.exists(),
        "dead child leaves its owned socket pathname"
    );
    assert_eq!(
        UnixStream::connect(&f.socket).err().unwrap().kind(),
        ErrorKind::ConnectionRefused
    );
    let failure = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        f.connect_at("post-disconnect replacement event-stream connection")
    }))
    .expect_err("strict connection must fail");
    let message = failure.downcast_ref::<String>().unwrap();
    assert!(message.contains("post-disconnect replacement event-stream connection"));
    assert!(message.contains("ConnectionRefused"));
}

#[test]
fn fixture_diagnostics_are_bounded_drained_and_redacted() {
    let hostile = b"synthetic-private-marker".repeat(1024);
    let retained = capture(std::io::Cursor::new(hostile)).join().unwrap();
    assert_eq!(retained.len(), DIAGNOSTIC_BYTES);
    assert!(!safe_diagnostics(&retained).contains("synthetic-private-marker"));
    assert_eq!(
        safe_diagnostics(b"fixture startup exit requested\n"),
        "fixture startup exit requested"
    );
}

#[test]
fn real_uds_routes_strict_codec_and_command_mapping() {
    let f = Fixture::new("");
    for path in [
        "/v1/health",
        "/v1/status",
        "/v1/devices",
        "/v1/devices/fixture.device",
    ] {
        assert_eq!(status(&f.request(&get(path))), 200);
    }
    for path in ["/ready", "/v1/devices/unknown", "/v1/commands/unknown"] {
        assert_eq!(status(&f.request(&get(path))), 404);
    }
    let wrong =
        f.request(b"POST /v1/status HTTP/1.1\r\nHost: localhost\r\nContent-Length: 0\r\n\r\n");
    assert_eq!(status(&wrong), 405);
    assert!(
        String::from_utf8(wrong)
            .unwrap()
            .to_ascii_lowercase()
            .contains("allow: get")
    );
    assert_eq!(status(&f.request(&post("{}", "text/plain"))), 415);
    assert_eq!(
        status(&f.request(&post("{}", "application/json; charset=latin1"))),
        415
    );
    assert_eq!(status(&f.request(&post("{}", "application/json"))), 400);
    assert_eq!(
        status(&f.request(&post(&command("c", ",\"unknown\":1"), "application/json"))),
        400
    );
    assert_eq!(
        status(&f.request(&post(
            &command("c", ",\"request_id\":\"duplicate\""),
            "application/json"
        ))),
        400
    );
    assert_eq!(
        status(&f.request(&post(&"x".repeat(256 * 1024 + 1), "application/json"))),
        413
    );
    assert_eq!(
        status(&f.request(&get(&format!("/v1/devices/{}", "a".repeat(257))))),
        400
    );
    assert_eq!(
        status(&f.request(&post(
            &command("semantic", "").replace("\"token\":1", "\"token\":0"),
            "application/json"
        ))),
        422
    );
    assert_eq!(
        status(&f.request(&post(
            &command("kind", "").replace("synthetic.signal", "synthetic.unknown"),
            "application/json"
        ))),
        422
    );
    assert_eq!(
        status(&f.request(&post(
            &command("payload", "").replace("\"token\":1", "\"token\":1,\"extra\":2"),
            "application/json"
        ))),
        400
    );
    let body = command("c", "");
    assert_eq!(
        status(&f.request(&post(&body, "application/json; charset=utf-8"))),
        202
    );
    assert_eq!(status(&f.request(&post(&body, "application/json"))), 200);
    assert_eq!(
        status(&f.request(&post(
            &body.replace("\"token\":1", "\"token\":2"),
            "application/json"
        ))),
        409
    );
    assert_eq!(
        status(&f.request(&post(
            &command("other", "").replace("fixture-binding-a", "wrong"),
            "application/json"
        ))),
        409
    );
    assert_eq!(
        status(&f.request(&post(
            &command("expired", "").replace("50000", "0"),
            "application/json"
        ))),
        422
    );
}

#[test]
fn queue_and_cache_capacity_reject_before_creating_another_record() {
    for (mode, code) in [
        ("small", "edge.executor_queue_full"),
        ("cache", "edge.command_cache_full"),
    ] {
        let f = Fixture::new(mode);
        let first =
            command("active", "").replace("\"scenario\":\"success\"", "\"scenario\":\"pending\"");
        assert_eq!(status(&f.request(&post(&first, "application/json"))), 202);
        std::thread::sleep(Duration::from_millis(50));
        if mode == "small" {
            assert_eq!(
                status(&f.request(&post(&command("waiting", ""), "application/json"))),
                202
            );
        }
        let rejected = f.request(&post(&command("refused", ""), "application/json"));
        assert_eq!(status(&rejected), 503);
        assert!(String::from_utf8(rejected).unwrap().contains(code));
        assert_eq!(status(&f.request(&get("/v1/commands/refused"))), 404);
    }
}

#[test]
fn headers_are_bounded_and_pipelining_is_not_served() {
    let f = Fixture::new("");
    assert_eq!(status(&f.request(b"POST /v1/commands HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nContent-Length: 2\r\nContent-Length: 3\r\n\r\n{}")), 400);
    assert_eq!(status(&f.request(b"POST /v1/commands HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nContent-Encoding: gzip\r\nContent-Length: 2\r\n\r\n{}")), 415);
    let oversized = format!(
        "GET /v1/health HTTP/1.1\r\nHost: localhost\r\nX-Large: {}\r\n\r\n",
        "a".repeat(17000)
    );
    assert_eq!(status(&f.request(oversized.as_bytes())), 431);
    let headers = (0..40)
        .map(|i| format!("X-{i}: value\r\n"))
        .collect::<String>();
    let many = format!("GET /v1/health HTTP/1.1\r\nHost: localhost\r\n{headers}\r\n");
    assert_eq!(status(&f.request(many.as_bytes())), 431);
    let mut pipelined = get("/v1/health");
    pipelined.extend(get("/v1/status"));
    let result = f.request(&pipelined);
    assert_eq!(
        String::from_utf8(result)
            .unwrap()
            .matches("HTTP/1.1")
            .count(),
        1
    );
}

#[test]
fn lost_response_keeps_one_record_and_one_physical_start() {
    let f = Fixture::new("lost");
    let body = command("lost", "");
    assert!(f.request(&post(&body, "application/json")).is_empty());
    let second = body.replace("request-lost", "another-request");
    assert_eq!(status(&f.request(&post(&second, "application/json"))), 200);
    std::thread::sleep(Duration::from_millis(100));
    let metrics = std::fs::read_to_string(f.dir.join("metrics")).unwrap();
    assert_eq!(metrics.lines().take(3).collect::<Vec<_>>(), ["2", "1", "1"]);
}

#[test]
fn event_stream_first_snapshot_second_subscriber_and_disconnect_cleanup() {
    let f = Fixture::new("");
    let mut stream = f.connect_at("initial event-stream connection");
    stream.write_all(&get("/v1/events")).unwrap();
    let mut buffer = [0; 2048];
    let n = stream.read(&mut buffer).unwrap();
    let mut bytes = buffer[..n].to_vec();
    while !String::from_utf8_lossy(&bytes).contains("snapshot") {
        let n = stream.read(&mut buffer).unwrap();
        assert!(n > 0);
        bytes.extend_from_slice(&buffer[..n]);
    }
    assert_eq!(
        status(&f.request_at(&get("/v1/events"), "second-subscriber request")),
        503
    );
    drop(stream);
    let deadline = Instant::now() + Duration::from_secs(2);
    loop {
        let mut new = f.connect_at("post-disconnect replacement event-stream connection");
        new.write_all(&get("/v1/events")).unwrap();
        let n = new.read(&mut buffer).unwrap();
        if status(&buffer[..n]) == 200 {
            break;
        }
        assert!(Instant::now() < deadline);
        std::thread::sleep(Duration::from_millis(20));
    }
}

#[test]
fn qualification_hostile_chunked_request_and_ambiguous_framing_are_bounded() {
    let f = Fixture::new("");
    let prefix = b"POST /v1/commands HTTP/1.1\r\nHost: local\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\n\r\n";
    let mut oversized = prefix.to_vec();
    oversized.extend_from_slice(b"40001\r\n"); // default 256 KiB + 1
    oversized.extend(std::iter::repeat_n(b' ', 256 * 1024 + 1));
    oversized.extend_from_slice(b"\r\n0\r\n\r\n");
    assert_eq!(status(&f.request(&oversized)), 413);
    let cl = format!(
        "POST /v1/commands HTTP/1.1\r\nHost: local\r\nContent-Type: application/json\r\nContent-Length: {}\r\n\r\n{}",
        256 * 1024 + 1,
        " ".repeat(256 * 1024 + 1)
    );
    assert_eq!(status(&f.request(cl.as_bytes())), 413);
    for body in [b"invalid\r\n".as_slice(), b"2\r\n{\r\n0\r\n\r\n".as_slice()] {
        let mut req = prefix.to_vec();
        req.extend_from_slice(body);
        assert_eq!(status(&f.request(&req)), 400);
    }
    // Truncated chunk: EOF on request half, still allow response half.
    let mut socket = f.connect();
    socket.write_all(prefix).unwrap();
    socket.write_all(b"20\r\n{}").unwrap();
    socket.shutdown(std::net::Shutdown::Write).unwrap();
    let mut response = Vec::new();
    socket.read_to_end(&mut response).unwrap();
    assert_eq!(status(&response), 400);
    // Hyper's HTTP/1 TE precedence is accepted here; it must serve exactly one
    // request, close, and never reinterpret suffix bytes as another command.
    let body = command("ambiguous", "");
    let te_cl = format!(
        "POST /v1/commands HTTP/1.1\r\nHost: local\r\nContent-Type: application/json\r\nContent-Length: 1\r\nTransfer-Encoding: chunked\r\n\r\n{:x}\r\n{}\r\n0\r\n\r\nGET /v1/status HTTP/1.1\r\nHost: local\r\n\r\n",
        body.len(),
        body
    );
    let result = f.request(te_cl.as_bytes());
    assert_eq!(status(&result), 202);
    assert_eq!(
        String::from_utf8(result)
            .unwrap()
            .matches("HTTP/1.1")
            .count(),
        1
    );
    assert_eq!(
        std::fs::read_to_string(f.dir.join("metrics"))
            .unwrap()
            .lines()
            .next(),
        Some("1")
    );
}

#[test]
fn qualification_opaque_path_ids_round_trip_without_route_confusion() {
    let f = Fixture::new("");
    let original = command("a/b%?#..", "");
    assert_eq!(
        status(&f.request(&post(&original, "application/json"))),
        202
    );
    assert_eq!(
        status(&f.request(&get("/v1/commands/a%2Fb%25%3F%23.."))),
        200
    );
    assert_eq!(status(&f.request(&get("/v1/commands/a/b"))), 404);
    assert_eq!(status(&f.request(&get("/v1/health?extra=1"))), 400);
    assert_eq!(status(&f.request(&get("/v1/health/"))), 404);
    assert_eq!(status(&f.request(&get("/v1/commands/%ff"))), 404);
}

#[test]
fn qualification_default_body_and_header_boundaries_are_exact() {
    let f = Fixture::new("");
    for (id, chunked) in [("exact-cl", false), ("exact-chunked", true)] {
        let mut body = command(id, "");
        body.push_str(&" ".repeat(256 * 1024 - body.len()));
        let request = if chunked {
            format!("POST /v1/commands HTTP/1.1\r\nHost: local\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\n\r\n{:x}\r\n{}\r\n0\r\n\r\n", body.len(), body).into_bytes()
        } else {
            post(&body, "application/json")
        };
        assert_eq!(status(&f.request(&request)), 202);
    }
    for (extra, expected) in [(31, 200), (32, 431)] {
        let headers = (0..extra)
            .map(|i| format!("X-{i}: value\r\n"))
            .collect::<String>();
        let request = format!("GET /v1/health HTTP/1.1\r\nHost: local\r\n{headers}\r\n");
        assert_eq!(status(&f.request(request.as_bytes())), expected);
    }
    let prefix = "GET /v1/health HTTP/1.1\r\nHost: local\r\nX-Large: ";
    for (length, expected) in [(16 * 1024, 200), (16 * 1024 + 1, 431)] {
        let request = format!("{prefix}{}\r\n\r\n", "x".repeat(length - prefix.len() - 4));
        assert_eq!(request.len(), length);
        assert_eq!(status(&f.request(request.as_bytes())), expected);
    }
}
