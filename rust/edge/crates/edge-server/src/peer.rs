use tokio::net::UnixStream;

/// Injectable credential observation, never peer-supplied request metadata.
/// Production composition uses LinuxPeerCredentials; qualification can model denial.
pub trait PeerCredentials: Send + Sync + 'static {
    fn uid(&self, socket: &UnixStream) -> Option<u32>;
}

#[derive(Clone, Copy, Debug)]
pub struct LinuxPeerCredentials;

impl PeerCredentials for LinuxPeerCredentials {
    fn uid(&self, socket: &UnixStream) -> Option<u32> {
        rustix::net::sockopt::socket_peercred(socket)
            .ok()
            .map(|cred| cred.uid.as_raw())
    }
}
