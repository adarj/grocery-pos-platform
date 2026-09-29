use std::cell::Cell;
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::sync::Once;

thread_local! {
    static IN_ADAPTER: Cell<bool> = const { Cell::new(false) };
}

static INSTALL_HOOK: Once = Once::new();

/// catch_unwind alone does not suppress Rust's panic hook. Install one wrapper
/// before execution: adapter boundaries discard diagnostics; all other panics
/// still invoke the prior hook and are not caught as command failures. This is
/// a process-wide hook with thread-local scope, not an execution scheduler.
/// First installation belongs to serial process bootstrap, before other threads
/// can panic: take_hook/set_hook is not an atomic hook replacement. The future
/// daemon must install its ordinary hook BEFORE this wrapper and must not
/// replace it afterward. No panic payload is formatted or logged here.
pub(crate) fn install_privacy_hook() {
    INSTALL_HOOK.call_once(|| {
        let previous = std::panic::take_hook();
        std::panic::set_hook(Box::new(move |info| {
            if !IN_ADAPTER.with(Cell::get) {
                previous(info);
            }
        }));
    });
}

struct Boundary(bool);

impl Drop for Boundary {
    fn drop(&mut self) {
        IN_ADAPTER.with(|flag| flag.set(self.0));
    }
}

/// Scope contains adapter-owned code only. Core/queue invariants stay outside.
pub(crate) fn adapter_call<T>(call: impl FnOnce() -> T) -> Result<T, ()> {
    let _boundary = Boundary(IN_ADAPTER.with(|flag| flag.replace(true)));
    match catch_unwind(AssertUnwindSafe(call)) {
        Ok(value) => Ok(value),
        Err(payload) => {
            // A panic payload with a panicking destructor is uncontainable:
            // propagate that panic rather than disguising control-plane failure.
            // The privacy boundary remains active during disposal.
            drop(payload);
            Err(())
        }
    }
}

/// Destruction establishes the no-future-I/O guarantee. A destructor panic is
/// not an ordinary operation failure: cleanup may be incomplete. Abort before
/// publishing terminal evidence or reusing this epoch. Do not inspect or drop
/// the panic payload; its own destructor is also untrusted.
pub(crate) fn adapter_drop<T>(value: T) {
    let _boundary = Boundary(IN_ADAPTER.with(|flag| flag.replace(true)));
    match catch_unwind(AssertUnwindSafe(|| drop(value))) {
        Ok(()) => {}
        Err(_payload) => std::process::abort(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{Arc, Barrier};

    #[test]
    fn privacy_scope_is_nested_and_thread_local() {
        const NAME: &str = "panic_boundary::tests::privacy_scope_is_nested_and_thread_local";
        if std::env::var_os("M824_SCOPE_PROBE_CHILD").is_some() {
            std::panic::set_hook(Box::new(|info| eprintln!("application hook: {info}")));
            install_privacy_hook();
            install_privacy_hook();
            let barrier = Arc::new(Barrier::new(2));
            let ordinary_barrier = Arc::clone(&barrier);
            let ordinary = std::thread::spawn(move || {
                ordinary_barrier.wait();
                let panic = catch_unwind(|| panic!("ORDINARY_THREAD_PANIC"));
                ordinary_barrier.wait();
                assert!(panic.is_err());
            });
            assert_eq!(
                adapter_call(|| {
                    assert_eq!(
                        adapter_call(|| panic!("NESTED_ADAPTER_PRIVATE_SENTINEL")),
                        Err(())
                    );
                    // The inner boundary must restore the outer scope. The
                    // ordinary thread panics while this thread is still scoped.
                    barrier.wait();
                    barrier.wait();
                    panic!("OUTER_ADAPTER_PRIVATE_SENTINEL");
                }),
                Err(())
            );
            ordinary.join().unwrap();
            assert!(catch_unwind(|| panic!("ORDINARY_AFTER_SCOPE")).is_err());
            return;
        }
        let output = std::process::Command::new(std::env::current_exe().unwrap())
            .args(["--exact", NAME, "--nocapture"])
            .env("M824_SCOPE_PROBE_CHILD", "1")
            .output()
            .unwrap();
        assert!(output.status.success());
        let stderr = String::from_utf8(output.stderr).unwrap();
        assert!(!stderr.contains("PRIVATE_SENTINEL"));
        assert!(stderr.contains("ORDINARY_THREAD_PANIC"));
        assert!(stderr.contains("ORDINARY_AFTER_SCOPE"));
        assert_eq!(stderr.matches("application hook:").count(), 2);
    }
}
