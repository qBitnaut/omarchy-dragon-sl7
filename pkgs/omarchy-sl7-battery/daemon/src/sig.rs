//! SIGTERM/SIGINT through a self-pipe, so the daemon can flush before it exits. This is the
//! only module that uses unsafe code.
#![allow(unsafe_code)]

use std::fs::File;
use std::os::fd::FromRawFd;
use std::sync::atomic::{AtomicI32, Ordering};

static WRITE_FD: AtomicI32 = AtomicI32::new(-1);

extern "C" fn handler(_sig: libc::c_int) {
    let fd = WRITE_FD.load(Ordering::Relaxed);
    if fd >= 0 {
        let b = 1u8;
        // write(2) is async-signal-safe.
        let _ = unsafe { libc::write(fd, &b as *const u8 as *const libc::c_void, 1) };
    }
}

/// Installs the handlers and returns the read end of the pipe.
pub fn install() -> Option<File> {
    let mut fds = [0 as libc::c_int; 2];
    unsafe {
        if libc::pipe(fds.as_mut_ptr()) != 0 {
            return None;
        }
        WRITE_FD.store(fds[1], Ordering::Relaxed);
        let h = handler as extern "C" fn(libc::c_int) as usize as libc::sighandler_t;
        libc::signal(libc::SIGTERM, h);
        libc::signal(libc::SIGINT, h);
        Some(File::from_raw_fd(fds[0]))
    }
}
