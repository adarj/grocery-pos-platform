#![cfg(feature = "qualification")]
use std::{
    io::{Read, Write},
    os::unix::net::UnixStream,
    path::PathBuf,
    process::{Command, Stdio},
    sync::atomic::{AtomicU64, Ordering},
    time::{Duration, Instant},
};
static NEXT: AtomicU64 = AtomicU64::new(0);
struct Fixture {
    child: std::process::Child,
    dir: PathBuf,
    socket: PathBuf,
}
impl Fixture {
    fn new(mode: &str) -> Self {
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
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .unwrap();
        let f = Self { child, dir, socket };
        let deadline = Instant::now() + Duration::from_secs(3);
        while !f.socket.exists() {
            assert!(Instant::now() < deadline);
            std::thread::sleep(Duration::from_millis(5));
        }
        f
    }
    fn connect(&self) -> UnixStream {
        let stream = UnixStream::connect(&self.socket).unwrap();
        stream
            .set_read_timeout(Some(Duration::from_secs(3)))
            .unwrap();
        stream
    }
    fn request(&self, request: &[u8]) -> Vec<u8> {
        let mut stream = self.connect();
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
}
impl Drop for Fixture {
    fn drop(&mut self) {
        if let Some(stdin) = &mut self.child.stdin {
            let _ = stdin.write_all(b"\n");
        }
        let start = Instant::now();
        while self.child.try_wait().unwrap().is_none() {
            if start.elapsed() > Duration::from_secs(3) {
                let _ = self.child.kill();
                panic!("fixture shutdown exceeded bound");
            }
            std::thread::sleep(Duration::from_millis(5));
        }
        let _ = std::fs::remove_dir_all(&self.dir);
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
    let mut stream = f.connect();
    stream.write_all(&get("/v1/events")).unwrap();
    let mut buffer = [0; 2048];
    let n = stream.read(&mut buffer).unwrap();
    let mut bytes = buffer[..n].to_vec();
    while !String::from_utf8_lossy(&bytes).contains("snapshot") {
        let n = stream.read(&mut buffer).unwrap();
        assert!(n > 0);
        bytes.extend_from_slice(&buffer[..n]);
    }
    assert_eq!(status(&f.request(&get("/v1/events"))), 503);
    drop(stream);
    let deadline = Instant::now() + Duration::from_secs(2);
    loop {
        let mut new = f.connect();
        new.write_all(&get("/v1/events")).unwrap();
        let n = new.read(&mut buffer).unwrap();
        if status(&buffer[..n]) == 200 {
            break;
        }
        assert!(Instant::now() < deadline);
        std::thread::sleep(Duration::from_millis(20));
    }
}
