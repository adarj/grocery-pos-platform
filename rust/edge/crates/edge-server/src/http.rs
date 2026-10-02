use crate::control::{self, ControlError, ControlHandle, Epoch, Reply};
use crate::{ControlOperation, ControlPlane, ControlReply, PeerCredentials, ServerLimits};
use bytes::Bytes;
use edge_core::{AdmissionDecision, AdmissionRejection, CoreCommand, CoreFatalError, EventPoll};
use edge_protocol::{
    CommandId, CommandPayloadDecoder, CommandResponse, DeviceId, EdgeEvent, ErrorCode,
    HealthResponse, JsonDecodeError, JsonDecodeLimits, ProtocolError, ProtocolErrorResponse,
    RequestId, decode_command_strict, encode_json_bounded,
};
use http_body_util::{BodyExt, Full, Limited, combinators::UnsyncBoxBody};
use hyper::{
    Method, Request, Response, StatusCode,
    body::{Body, Frame, Incoming},
    service::service_fn,
};
use hyper_util::rt::{TokioIo, TokioTimer};
use std::{
    fmt,
    future::Future,
    pin::Pin,
    sync::Arc,
    task::{Context, Poll},
};
use tokio::{
    net::UnixListener,
    sync::{mpsc, watch},
    task::JoinSet,
};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ServerError {
    InvalidLimits,
    Listener,
    ControlThread,
    FatalEpoch,
}

impl fmt::Display for ServerError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("Edge transport stopped")
    }
}

impl std::error::Error for ServerError {}
#[derive(Clone, Copy, Debug)]
struct ConnectionClosed;

impl fmt::Display for ConnectionClosed {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("Edge connection closed")
    }
}

impl std::error::Error for ConnectionClosed {}
type ResponseBody = UnsyncBoxBody<Bytes, ConnectionClosed>;

/// Consume a privileged pre-opened filesystem listener. This function never
/// creates, unlinks, chmods, or changes ownership of the socket pathname.
/// Factory runs on the dedicated Core thread and may return !Send Core state.
pub async fn serve<P, D, F, T, S>(
    listener: std::os::unix::net::UnixListener,
    expected_uid: u32,
    credentials: impl PeerCredentials,
    limits: ServerLimits,
    factory: F,
    shutdown: S,
) -> Result<(), ServerError>
where
    P: CoreCommand,
    D: CommandPayloadDecoder<Payload = P> + 'static,
    F: FnOnce() -> Result<T, CoreFatalError> + Send + 'static,
    T: ControlPlane<P> + 'static,
    S: Future<Output = ()>,
{
    if !limits.valid() {
        return Err(ServerError::InvalidLimits);
    }
    if listener
        .local_addr()
        .map_err(|_| ServerError::Listener)?
        .as_pathname()
        .is_none()
    {
        return Err(ServerError::Listener);
    }
    listener
        .set_nonblocking(true)
        .map_err(|_| ServerError::Listener)?;
    let listener = UnixListener::from_std(listener).map_err(|_| ServerError::Listener)?;
    let (control, thread) =
        control::spawn(factory, &limits).map_err(|_| ServerError::ControlThread)?;
    let credentials = Arc::new(credentials);
    let limits = Arc::new(limits);
    #[cfg(feature = "qualification")]
    let lose_response = Arc::new(std::sync::atomic::AtomicBool::new(
        limits.lose_first_accepted_response,
    ));
    let mut connections = JoinSet::new();
    let mut epoch = control.epoch.clone();
    tokio::pin!(shutdown);
    let result = loop {
        tokio::select! {
            _=&mut shutdown=>break Ok(()),
            changed=epoch.changed()=> {if changed.is_err() || *epoch.borrow()!=Epoch::Running {break Err(ServerError::FatalEpoch);}},
            Some(_)=connections.join_next(),if !connections.is_empty()=>{},
            accepted=listener.accept()=> {
                let (socket,_)=match accepted {Ok(v)=>v,Err(_)=>break Err(ServerError::Listener)};
                // Credentials precede service construction and every HTTP parser.
                if credentials.uid(&socket)!=Some(expected_uid) {drop(socket);continue;}
                if connections.len()==limits.max_connections {drop(socket);continue;}
                let limits=limits.clone(); let control=control.clone();
                #[cfg(feature="qualification")]
                let lose_response=lose_response.clone();
                connections.spawn(async move {
                    let (close_stream,mut stream_closed)=watch::channel(false);
                    let _close_stream_guard=close_stream.clone();
                    let svc_control=control.clone(); let svc_limits=limits.clone();
                    let service=service_fn(move |request| handle::<P,D>(request,svc_control.clone(),svc_limits.clone(),close_stream.clone(),
                        #[cfg(feature="qualification")]
                        lose_response.clone(),
                    ));
                    let mut builder=hyper::server::conn::http1::Builder::new();
                    builder.keep_alive(false)
                        .half_close(true).max_buf_size(limits.header_bytes).max_headers(limits.max_headers)
                        .header_read_timeout(limits.header_timeout).timer(TokioTimer::new()).pipeline_flush(false);
                    let connection=builder.serve_connection(TokioIo::new(crate::write_deadline::WriteDeadline::new(socket,limits.response_timeout)),service);
                    tokio::pin!(connection);
                    let mut epoch=control.epoch.clone();
                    tokio::select! {
                        _=&mut connection=>{},
                        _=epoch.changed()=>{},
                        _=stream_closed.changed()=>{},
                    }
                });
            }
        }
    };
    connections.abort_all();
    while connections.join_next().await.is_some() {}
    control.shutdown();
    let joined = tokio::task::spawn_blocking(move || thread.join()).await;
    if !matches!(joined, Ok(Ok(()))) {
        return Err(ServerError::ControlThread);
    }
    result
}

fn json<T: serde::Serialize>(
    status: StatusCode,
    value: &T,
    limit: usize,
) -> Result<Response<ResponseBody>, ConnectionClosed> {
    let bytes = encode_json_bounded(value, limit).map_err(|_| ConnectionClosed)?;
    Ok(Response::builder()
        .status(status)
        .header("content-type", "application/json")
        .header("connection", "close")
        .body(
            Full::new(Bytes::from(bytes))
                .map_err(|never| match never {})
                .boxed_unsync(),
        )
        .expect("authored response"))
}

fn error(
    status: StatusCode,
    code: &'static str,
    request_id: Option<RequestId>,
    limit: usize,
) -> Result<Response<ResponseBody>, ConnectionClosed> {
    json(
        status,
        &ProtocolErrorResponse {
            request_id,
            error: ProtocolError {
                code: ErrorCode::new(code).expect("authored code"),
                message: None,
            },
        },
        limit,
    )
}

fn rejection(value: AdmissionRejection) -> (StatusCode, &'static str) {
    use AdmissionRejection::*;
    match value {
        AgentInstanceConflict => (StatusCode::CONFLICT, "edge.agent_instance_conflict"),
        SemanticConflict => (StatusCode::CONFLICT, "edge.semantic_conflict"),
        BindingInstanceConflict => (StatusCode::CONFLICT, "edge.binding_instance_conflict"),
        UnknownDevice => (StatusCode::NOT_FOUND, "edge.unknown_device"),
        SubmissionExpired => (StatusCode::UNPROCESSABLE_ENTITY, "edge.submission_expired"),
        SubmissionHorizonExceeded => (
            StatusCode::UNPROCESSABLE_ENTITY,
            "edge.submission_horizon_exceeded",
        ),
        TimeoutTooLarge => (StatusCode::UNPROCESSABLE_ENTITY, "edge.timeout_too_large"),
        CapabilityUnavailable => (
            StatusCode::UNPROCESSABLE_ENTITY,
            "edge.capability_unavailable",
        ),
        CommandCacheFull => (StatusCode::SERVICE_UNAVAILABLE, "edge.command_cache_full"),
        ExecutorQueueFull => (StatusCode::SERVICE_UNAVAILABLE, "edge.executor_queue_full"),
        ExecutorUnavailable => (StatusCode::SERVICE_UNAVAILABLE, "edge.executor_unavailable"),
    }
}

fn segment(path: &str, prefix: &str) -> Option<String> {
    let rest = path.strip_prefix(prefix)?;
    if rest.is_empty() || rest.contains('/') {
        return None;
    }
    let mut decoded = Vec::with_capacity(rest.len());
    let mut bytes = rest.bytes();
    while let Some(b) = bytes.next() {
        if b == b'%' {
            let a = (bytes.next()? as char).to_digit(16)?;
            let c = (bytes.next()? as char).to_digit(16)?;
            decoded.push((a * 16 + c) as u8);
        } else {
            decoded.push(b);
        }
    }
    String::from_utf8(decoded).ok()
}

async fn value<P>(
    control: &ControlHandle<P>,
    op: ControlOperation<P>,
    limit: usize,
) -> Result<Result<ControlReply, Response<ResponseBody>>, ConnectionClosed> {
    let request_id = match &op {
        ControlOperation::Submit(submission) => Some(submission.request_id.clone()),
        _ => None,
    };
    match control.request(op).await {
        Ok(Reply::Value(v)) => Ok(Ok(v)),
        Err(ControlError::Busy) => Ok(Err(error(
            StatusCode::SERVICE_UNAVAILABLE,
            "edge.control_plane_busy",
            request_id,
            limit,
        )?)),
        _ => Err(ConnectionClosed),
    }
}

async fn handle<P: CoreCommand, D: CommandPayloadDecoder<Payload = P>>(
    request: Request<Incoming>,
    control: ControlHandle<P>,
    limits: Arc<ServerLimits>,
    close_stream: watch::Sender<bool>,
    #[cfg(feature = "qualification")] lose_response: Arc<std::sync::atomic::AtomicBool>,
) -> Result<Response<ResponseBody>, ConnectionClosed> {
    let path = request.uri().path();
    let device = segment(path, "/v1/devices/");
    let command = segment(path, "/v1/commands/");
    let method = if path == "/v1/commands" {
        Method::POST
    } else if matches!(
        path,
        "/v1/health" | "/v1/status" | "/v1/devices" | "/v1/events"
    ) || device.is_some()
        || command.is_some()
    {
        Method::GET
    } else {
        return error(
            StatusCode::NOT_FOUND,
            "edge.unknown_route",
            None,
            limits.response_bytes,
        );
    };
    if request.method() != method {
        let mut response = error(
            StatusCode::METHOD_NOT_ALLOWED,
            "edge.method_not_allowed",
            None,
            limits.response_bytes,
        )?;
        response
            .headers_mut()
            .insert("allow", method.as_str().parse().expect("authored method"));
        return Ok(response);
    }
    if request.version() != hyper::Version::HTTP_11 || request.uri().query().is_some() {
        return error(
            StatusCode::BAD_REQUEST,
            "edge.invalid_request",
            None,
            limits.response_bytes,
        );
    }
    if request.headers().contains_key("content-encoding") {
        return error(
            StatusCode::UNSUPPORTED_MEDIA_TYPE,
            "edge.unsupported_encoding",
            None,
            limits.response_bytes,
        );
    }
    if method == Method::POST {
        let content_types = request.headers().get_all("content-type");
        let mut types = content_types.iter();
        let valid = types.next().and_then(|h| h.to_str().ok()).is_some_and(|s| {
            let mut fields = s.split(';');
            if !fields
                .next()
                .is_some_and(|t| t.trim().eq_ignore_ascii_case("application/json"))
            {
                return false;
            }
            let charset = match fields.next() {
                None => true,
                Some(parameter) => parameter.split_once('=').is_some_and(|(name, value)| {
                    let value = value.trim();
                    let value = value
                        .strip_prefix('"')
                        .and_then(|v| v.strip_suffix('"'))
                        .unwrap_or(value);
                    name.trim().eq_ignore_ascii_case("charset")
                        && value.eq_ignore_ascii_case("utf-8")
                }),
            };
            charset && fields.next().is_none()
        }) && types.next().is_none();
        if !valid {
            return error(
                StatusCode::UNSUPPORTED_MEDIA_TYPE,
                "edge.unsupported_media_type",
                None,
                limits.response_bytes,
            );
        }
        let collected = tokio::time::timeout(
            limits.body_timeout,
            Limited::new(
                request.into_body(),
                limits
                    .body_bytes
                    .min(JsonDecodeLimits::COMMAND_REQUEST.max_input_bytes),
            )
            .collect(),
        )
        .await;
        let bytes = match collected {
            Err(_) => {
                return error(
                    StatusCode::REQUEST_TIMEOUT,
                    "edge.body_timeout",
                    None,
                    limits.response_bytes,
                );
            }
            Ok(Err(e)) => {
                let large = e.is::<http_body_util::LengthLimitError>();
                return error(
                    if large {
                        StatusCode::PAYLOAD_TOO_LARGE
                    } else {
                        StatusCode::BAD_REQUEST
                    },
                    if large {
                        "edge.body_too_large"
                    } else {
                        "edge.invalid_framing"
                    },
                    None,
                    limits.response_bytes,
                );
            }
            Ok(Ok(body)) => body.to_bytes(),
        };
        let submission = match decode_command_strict::<D>(&bytes, JsonDecodeLimits::default()) {
            Ok(v) => v,
            Err(e) => {
                let semantic = matches!(
                    e,
                    JsonDecodeError::UnknownCommandKind | JsonDecodeError::PayloadSemanticViolation
                );
                return error(
                    if e == JsonDecodeError::InputTooLarge {
                        StatusCode::PAYLOAD_TOO_LARGE
                    } else if semantic {
                        StatusCode::UNPROCESSABLE_ENTITY
                    } else {
                        StatusCode::BAD_REQUEST
                    },
                    "edge.invalid_command",
                    None,
                    limits.response_bytes,
                );
            }
        };
        let request_id = submission.request_id.clone();
        let reply = match value(
            &control,
            ControlOperation::Submit(submission),
            limits.response_bytes,
        )
        .await?
        {
            Ok(v) => v,
            Err(response) => return Ok(response),
        };
        return match reply {
            ControlReply::Admission(AdmissionDecision::Accepted(command)) => {
                #[cfg(feature = "qualification")]
                if lose_response.swap(false, std::sync::atomic::Ordering::AcqRel) {
                    return Err(ConnectionClosed);
                }
                json(
                    StatusCode::ACCEPTED,
                    &CommandResponse {
                        request_id,
                        command,
                    },
                    limits.response_bytes,
                )
            }
            ControlReply::Admission(AdmissionDecision::Deduplicated(command)) => json(
                StatusCode::OK,
                &CommandResponse {
                    request_id,
                    command,
                },
                limits.response_bytes,
            ),
            ControlReply::Admission(AdmissionDecision::Rejected(reason)) => {
                let (status, code) = rejection(reason);
                error(status, code, Some(request_id), limits.response_bytes)
            }
            _ => Err(ConnectionClosed),
        };
    }
    if path == "/v1/events" {
        return match control.open().await {
            Ok(Reply::Open(lease, snapshot)) => {
                let guard = LeaseGuard {
                    control: control.clone(),
                    lease,
                };
                let first = event_bytes(&EdgeEvent::Snapshot(snapshot), limits.event_bytes)?;
                let (sender, receiver) = mpsc::channel(1);
                sender
                    .try_send(Ok(Frame::data(first)))
                    .map_err(|_| ConnectionClosed)?;
                let task = tokio::spawn(stream_events(guard, sender, limits, close_stream));
                Ok(Response::builder()
                    .header("content-type", "application/x-ndjson")
                    .header("connection", "close")
                    .body(EventBody { receiver, task }.boxed_unsync())
                    .expect("authored response"))
            }
            Ok(Reply::Refused) => error(
                StatusCode::SERVICE_UNAVAILABLE,
                "edge.event_subscription_unavailable",
                None,
                limits.response_bytes,
            ),
            Err(ControlError::Busy) => error(
                StatusCode::SERVICE_UNAVAILABLE,
                "edge.control_plane_busy",
                None,
                limits.response_bytes,
            ),
            _ => Err(ConnectionClosed),
        };
    }
    let operation = if let Some(id) = device {
        match DeviceId::new(id) {
            Ok(id) => ControlOperation::Device(id),
            Err(_) => {
                return error(
                    StatusCode::BAD_REQUEST,
                    "edge.invalid_identifier",
                    None,
                    limits.response_bytes,
                );
            }
        }
    } else if let Some(id) = command {
        match CommandId::new(id) {
            Ok(id) => ControlOperation::Command(id),
            Err(_) => {
                return error(
                    StatusCode::BAD_REQUEST,
                    "edge.invalid_identifier",
                    None,
                    limits.response_bytes,
                );
            }
        }
    } else if path == "/v1/devices" {
        ControlOperation::Devices
    } else {
        ControlOperation::Status
    };
    let reply = match value(&control, operation, limits.response_bytes).await? {
        Ok(v) => v,
        Err(response) => return Ok(response),
    };
    match reply {
        ControlReply::Status(status) if path == "/v1/health" => json(
            StatusCode::OK,
            &HealthResponse {
                agent_instance_id: status.agent_instance_id,
                protocol_version: status.protocol_version,
            },
            limits.response_bytes,
        ),
        ControlReply::Status(status) => json(StatusCode::OK, &status, limits.response_bytes),
        ControlReply::Devices(devices) => json(StatusCode::OK, &devices, limits.response_bytes),
        ControlReply::Device(Some(device)) => json(StatusCode::OK, &device, limits.response_bytes),
        ControlReply::Command(Some(command)) => {
            json(StatusCode::OK, &command, limits.response_bytes)
        }
        ControlReply::Device(None) | ControlReply::Command(None) => error(
            StatusCode::NOT_FOUND,
            "edge.not_found",
            None,
            limits.response_bytes,
        ),
        _ => Err(ConnectionClosed),
    }
}

fn event_bytes(event: &EdgeEvent, limit: usize) -> Result<Bytes, ConnectionClosed> {
    let mut bytes = encode_json_bounded(event, limit).map_err(|_| ConnectionClosed)?;
    bytes.push(b'\n');
    Ok(Bytes::from(bytes))
}

struct LeaseGuard<P> {
    control: ControlHandle<P>,
    lease: u64,
}
impl<P> Drop for LeaseGuard<P> {
    fn drop(&mut self) {
        self.control.close(self.lease);
    }
}

struct EventBody {
    receiver: mpsc::Receiver<Result<Frame<Bytes>, ConnectionClosed>>,
    task: tokio::task::JoinHandle<()>,
}

impl Drop for EventBody {
    fn drop(&mut self) {
        self.task.abort();
    }
}

impl Body for EventBody {
    type Data = Bytes;
    type Error = ConnectionClosed;
    fn poll_frame(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
    ) -> Poll<Option<Result<Frame<Bytes>, ConnectionClosed>>> {
        self.receiver.poll_recv(cx)
    }
}

async fn stream_events<P: CoreCommand>(
    guard: LeaseGuard<P>,
    sender: mpsc::Sender<Result<Frame<Bytes>, ConnectionClosed>>,
    limits: Arc<ServerLimits>,
    close: watch::Sender<bool>,
) {
    let mut lease_state = guard.control.lease_state.clone();
    let work = async {
        loop {
            // Acquire the only handoff slot BEFORE draining Core. Socket pressure
            // therefore accumulates in Core's authoritative continuity queue.
            let permit = sender.reserve().await.map_err(|_| ConnectionClosed)?;
            let event = loop {
                let notified = guard.control.wake.notified();
                tokio::pin!(notified);
                // Register before polling Core. notify_waiters reaches this
                // future even if publication races the Empty reply/await, and
                // a retiring lease's waiter cannot consume the wake exclusively.
                notified.as_mut().enable();
                match guard.control.poll(guard.lease).await {
                    Ok(Reply::Event(EventPoll::Event(event))) => break event,
                    Ok(Reply::Event(EventPoll::Empty)) => notified.await,
                    _ => return Err::<(), _>(ConnectionClosed),
                }
            };
            let bytes = event_bytes(&event, limits.event_bytes)?;
            #[cfg(feature = "qualification")]
            {
                let size = limits.event_chunk_bytes.max(1);
                let mut chunks = bytes.chunks(size);
                if let Some(first) = chunks.next() {
                    permit.send(Ok(Frame::data(Bytes::copy_from_slice(first))));
                }
                for chunk in chunks {
                    sender
                        .send(Ok(Frame::data(Bytes::copy_from_slice(chunk))))
                        .await
                        .map_err(|_| ConnectionClosed)?;
                }
            }

            #[cfg(not(feature = "qualification"))]
            permit.send(Ok(Frame::data(bytes)));
        }
    };
    let closed = async {
        loop {
            let (lease, active) = *lease_state.borrow_and_update();
            if lease != guard.lease || !active {
                break;
            }
            if lease_state.changed().await.is_err() {
                break;
            }
        }
    };
    tokio::pin!(work);
    tokio::select! {_=&mut work=>{},_=closed=>{}}
    close.send_replace(true);
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{
        LinuxPeerCredentials,
        control::tests::{Payload, plane},
    };
    use edge_protocol::{CommandKind, CommandPayloadDecodeError, StrictJsonFragment};
    use std::sync::atomic::{AtomicU64, AtomicUsize, Ordering};
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    static NEXT: AtomicU64 = AtomicU64::new(0);
    struct Decoder;
    impl CommandPayloadDecoder for Decoder {
        type Payload = Payload;
        fn decode_payload(
            _: &CommandKind,
            payload: StrictJsonFragment<'_>,
        ) -> Result<Payload, CommandPayloadDecodeError> {
            payload.decode::<()>()?;
            Ok(Payload)
        }
    }

    async fn server(
        limits: ServerLimits,
        uid: u32,
    ) -> (
        std::path::PathBuf,
        Arc<AtomicUsize>,
        Arc<AtomicU64>,
        tokio::sync::oneshot::Sender<()>,
        tokio::task::JoinHandle<Result<(), ServerError>>,
    ) {
        let socket = std::env::temp_dir().join(format!(
            "edge-http-{}-{}.sock",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        let listener = std::os::unix::net::UnixListener::bind(&socket).unwrap();
        let clock = Arc::new(AtomicU64::new(100));
        let requests = Arc::new(AtomicUsize::new(0));
        let c = clock.clone();
        let r = requests.clone();
        let (stop, receive) = tokio::sync::oneshot::channel();
        let task = tokio::spawn(serve::<Payload, Decoder, _, _, _>(
            listener,
            uid,
            LinuxPeerCredentials,
            limits,
            move || Ok(plane(c, r, Arc::new(AtomicUsize::new(0)))),
            async {
                let _ = receive.await;
            },
        ));
        (socket, requests, clock, stop, task)
    }

    async fn request(path: &std::path::Path, bytes: &[u8]) -> Vec<u8> {
        let mut socket = tokio::net::UnixStream::connect(path).await.unwrap();
        socket.write_all(bytes).await.unwrap();
        let mut out = vec![];
        let result = tokio::time::timeout(Duration::from_secs(2), socket.read_to_end(&mut out))
            .await
            .unwrap();
        if let Err(error) = result {
            assert_eq!(error.kind(), std::io::ErrorKind::ConnectionReset);
        }
        out
    }
    use std::time::Duration;
    #[tokio::test(flavor = "current_thread")]
    async fn retiring_stream_waiter_cannot_steal_replacement_stream_wakeup() {
        let (observed, heartbeat) = std::sync::mpsc::channel();
        let limits = ServerLimits {
            heartbeat_interval: Duration::from_secs(1),
            ..ServerLimits::default()
        };
        let (control, thread) = control::spawn(
            move || {
                Ok(plane(
                    Arc::new(AtomicU64::new(100)),
                    Arc::new(AtomicUsize::new(0)),
                    Arc::new(AtomicUsize::new(0)),
                )
                .observe_heartbeats(observed))
            },
            &limits,
        )
        .unwrap();
        let old = match control.open().await.unwrap() {
            Reply::Open(lease, _) => lease,
            _ => panic!("initial subscription"),
        };
        // A retiring producer may still have a registered Notified future until
        // Tokio next schedules its lease-closure branch. Keep that waiter alive
        // while the real Core closes its lease and opens the replacement.
        let retiring = control.wake.notified();
        tokio::pin!(retiring);
        assert!(
            std::future::poll_fn(|cx| Poll::Ready(retiring.as_mut().poll(cx)))
                .await
                .is_pending()
        );
        control.close(old);
        let lease = loop {
            match control.open().await.unwrap() {
                Reply::Open(lease, _) => break lease,
                Reply::Refused => tokio::task::yield_now().await,
                _ => panic!("replacement subscription"),
            }
        };
        let (sender, mut receiver) = mpsc::channel(1);
        let (closed, _) = watch::channel(false);
        let producer = tokio::spawn(stream_events(
            LeaseGuard {
                control: control.clone(),
                lease,
            },
            sender,
            Arc::new(limits),
            closed,
        ));
        // Wait for an actual Core heartbeat, rather than synthesizing an event
        // or relying on a notification as the event itself.
        tokio::task::spawn_blocking(move || {
            heartbeat.recv_timeout(Duration::from_secs(2)).unwrap()
        })
        .await
        .unwrap();
        let frame = tokio::time::timeout(Duration::from_millis(200), receiver.recv()).await;
        producer.abort();
        let _ = producer.await;
        control.shutdown();
        thread.join().unwrap();
        assert!(
            matches!(frame, Ok(Some(Ok(_)))),
            "retiring waiter stole the current stream's event wakeup"
        );
    }

    #[tokio::test(flavor = "current_thread")]
    async fn mailbox_saturation_maps_to_503_without_another_core_request() {
        let requests = Arc::new(AtomicUsize::new(0));
        let count = requests.clone();
        let (release, gate) = std::sync::mpsc::channel();
        let (started, receive) = std::sync::mpsc::channel();
        let (control, thread) = control::spawn(
            move || {
                Ok(plane(
                    Arc::new(AtomicU64::new(100)),
                    count,
                    Arc::new(AtomicUsize::new(0)),
                )
                .gated(gate, started))
            },
            &ServerLimits {
                control_mailbox_capacity: 1,
                ..ServerLimits::default()
            },
        )
        .unwrap();
        let first = control.clone();
        let first = tokio::spawn(async move { first.request(ControlOperation::Status).await });
        tokio::time::sleep(Duration::from_millis(10)).await;
        receive.recv_timeout(Duration::from_secs(1)).unwrap();
        let second = control.clone();
        let second = tokio::spawn(async move { second.request(ControlOperation::Status).await });
        tokio::time::sleep(Duration::from_millis(10)).await;
        let response = match value(&control, ControlOperation::Status, 256 * 1024)
            .await
            .unwrap()
        {
            Err(response) => response,
            Ok(_) => panic!("busy control plane accepted extra work"),
        };
        assert_eq!(response.status(), StatusCode::SERVICE_UNAVAILABLE);
        assert_eq!(requests.load(Ordering::Relaxed), 1);
        release.send(()).unwrap();
        first.await.unwrap().unwrap();
        second.await.unwrap().unwrap();
        assert_eq!(requests.load(Ordering::Relaxed), 2);
        control.shutdown();
        thread.join().unwrap();
    }

    #[tokio::test(flavor = "current_thread")]
    async fn wrong_peer_is_closed_before_http_or_core_and_real_same_uid_passes() {
        let uid = rustix::process::getuid().as_raw();
        let (path, requests, _, stop, task) = server(ServerLimits::default(), uid + 1).await;
        let out = request(&path, b"GET /v1/health HTTP/1.1\r\nHost: local\r\n\r\n").await;
        assert!(out.is_empty());
        assert_eq!(requests.load(Ordering::Relaxed), 0);
        stop.send(()).unwrap();
        assert_eq!(task.await.unwrap(), Ok(()));
        std::fs::remove_file(path).unwrap();
        let (path, requests, _, stop, task) = server(ServerLimits::default(), uid).await;
        let out = request(&path, b"GET /v1/health HTTP/1.1\r\nHost: local\r\n\r\n").await;
        assert!(out.starts_with(b"HTTP/1.1 200"));
        assert_eq!(requests.load(Ordering::Relaxed), 1);
        stop.send(()).unwrap();
        task.await.unwrap().unwrap();
        std::fs::remove_file(path).unwrap();
    }

    #[tokio::test(flavor = "current_thread")]
    async fn connection_limit_header_deadline_and_body_deadline_are_independent_of_core() {
        let limits = ServerLimits {
            max_connections: 1,
            header_timeout: Duration::from_millis(100),
            body_timeout: Duration::from_millis(50),
            ..ServerLimits::default()
        };
        let (path, requests, _, stop, task) =
            server(limits, rustix::process::getuid().as_raw()).await;
        let mut held = tokio::net::UnixStream::connect(&path).await.unwrap();
        held.write_all(b"GET /v1").await.unwrap();
        tokio::time::sleep(Duration::from_millis(20)).await;
        let refused = request(&path, b"GET /v1/health HTTP/1.1\r\nHost: local\r\n\r\n").await;
        assert!(refused.is_empty());
        let mut out = vec![];
        tokio::time::timeout(Duration::from_secs(1), held.read_to_end(&mut out))
            .await
            .unwrap()
            .unwrap();
        assert!(out.is_empty());
        tokio::time::sleep(Duration::from_millis(10)).await;
        let timeout=request(&path,b"POST /v1/commands HTTP/1.1\r\nHost: local\r\nContent-Type: application/json\r\nContent-Length: 10\r\n\r\n{").await;
        assert!(timeout.starts_with(b"HTTP/1.1 408"));
        assert_eq!(requests.load(Ordering::Relaxed), 0);
        stop.send(()).unwrap();
        task.await.unwrap().unwrap();
        std::fs::remove_file(path).unwrap();
    }

    #[tokio::test(flavor = "current_thread")]
    async fn core_fatal_stops_listener_instead_of_serving_recoverable_500() {
        let (path, _, clock, _stop, task) =
            server(ServerLimits::default(), rustix::process::getuid().as_raw()).await;
        assert!(
            request(&path, b"GET /v1/health HTTP/1.1\r\nHost: local\r\n\r\n")
                .await
                .starts_with(b"HTTP/1.1 200")
        );
        clock.store(99, Ordering::Relaxed);
        assert_eq!(
            tokio::time::timeout(Duration::from_secs(1), task)
                .await
                .unwrap()
                .unwrap(),
            Err(ServerError::FatalEpoch)
        );
        std::fs::remove_file(path).unwrap();
    }

    #[tokio::test(flavor = "current_thread")]
    async fn qualification_default_16_connections_bound_before_route_work() {
        let limits = ServerLimits::default();
        assert_eq!(limits.max_connections, 16);
        assert_eq!(limits.header_bytes, 16 * 1024);
        assert_eq!(limits.max_headers, 32);
        assert_eq!(limits.body_bytes, 256 * 1024);
        assert_eq!(limits.response_bytes, 256 * 1024);
        assert_eq!(limits.event_bytes, 64 * 1024);
        let (path, requests, _, stop, task) =
            server(limits, rustix::process::getuid().as_raw()).await;
        let mut held = Vec::new();
        for _ in 0..16 {
            let mut stream = tokio::net::UnixStream::connect(&path).await.unwrap();
            stream.write_all(b"POST /v1/commands HTTP/1.1\r\nHost: local\r\nContent-Type: application/json\r\nContent-Length: 2\r\n\r\n").await.unwrap();
            held.push(stream);
        }
        // Yield to the accept loop; no timer deadline is used as readiness.
        tokio::task::yield_now().await;
        let refused = request(&path, b"GET /v1/health HTTP/1.1\r\nHost: local\r\n\r\n").await;
        assert!(refused.is_empty());
        assert_eq!(requests.load(Ordering::Relaxed), 0);
        stop.send(()).unwrap();
        tokio::time::timeout(Duration::from_secs(2), task)
            .await
            .unwrap()
            .unwrap()
            .unwrap();
        drop(held);
        std::fs::remove_file(path).unwrap();
    }
}
