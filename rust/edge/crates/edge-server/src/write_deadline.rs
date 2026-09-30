use std::future::Future;
use std::{
    io,
    pin::Pin,
    task::{Context, Poll},
    time::Duration,
};
use tokio::{
    io::{AsyncRead, AsyncWrite, ReadBuf},
    net::UnixStream,
    time::{Sleep, sleep},
};

/// Bounds a pending socket write, including a stalled event reader. Time spent
/// waiting for the next Core event is not a socket-write timeout.
pub(crate) struct WriteDeadline {
    socket: UnixStream,
    timeout: Duration,
    pending: Option<Pin<Box<Sleep>>>,
}
impl WriteDeadline {
    pub fn new(socket: UnixStream, timeout: Duration) -> Self {
        Self {
            socket,
            timeout,
            pending: None,
        }
    }
    fn bound<T>(
        &mut self,
        cx: &mut Context<'_>,
        result: Poll<io::Result<T>>,
    ) -> Poll<io::Result<T>> {
        match result {
            Poll::Ready(value) => {
                self.pending = None;
                Poll::Ready(value)
            }
            Poll::Pending => {
                let timer = self
                    .pending
                    .get_or_insert_with(|| Box::pin(sleep(self.timeout)));
                if timer.as_mut().poll(cx).is_ready() {
                    Poll::Ready(Err(io::Error::from(io::ErrorKind::TimedOut)))
                } else {
                    Poll::Pending
                }
            }
        }
    }
}
impl AsyncRead for WriteDeadline {
    fn poll_read(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &mut ReadBuf<'_>,
    ) -> Poll<io::Result<()>> {
        Pin::new(&mut self.socket).poll_read(cx, buf)
    }
}
impl AsyncWrite for WriteDeadline {
    fn poll_write(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &[u8],
    ) -> Poll<io::Result<usize>> {
        let result = Pin::new(&mut self.socket).poll_write(cx, buf);
        self.bound(cx, result)
    }
    fn poll_flush(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        let result = Pin::new(&mut self.socket).poll_flush(cx);
        self.bound(cx, result)
    }
    fn poll_shutdown(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        let result = Pin::new(&mut self.socket).poll_shutdown(cx);
        self.bound(cx, result)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::io::AsyncWriteExt;
    #[tokio::test(flavor = "current_thread")]
    async fn stalled_socket_write_returns_within_configured_bound() {
        let (socket, _reader) = UnixStream::pair().unwrap();
        let mut writer = WriteDeadline::new(socket, Duration::from_millis(20));
        let result = tokio::time::timeout(
            Duration::from_secs(1),
            writer.write_all(&vec![0; 2 * 1024 * 1024]),
        )
        .await
        .unwrap();
        assert_eq!(result.unwrap_err().kind(), io::ErrorKind::TimedOut);
    }
}
