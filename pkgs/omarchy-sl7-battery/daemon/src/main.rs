//! sl7-batteryd: user service. Samples the battery every 20 s while awake, keeps the
//! history, runs the auto power saver and serves the Quickshell plugin on
//! $XDG_RUNTIME_DIR/sl7-batteryd.sock.

use std::io::{BufRead, BufReader, Read};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::PathBuf;
use std::sync::mpsc::{channel, Sender};
use std::time::{Duration, Instant};

use sl7_batteryd::app::{App, Event, Paths};
use sl7_batteryd::{monitor, sig};

const SAMPLE_EVERY: Duration = Duration::from_secs(20);
/// Writes are a few dirty 24-byte slots, so flush every minute: a crash costs at most that.
const FLUSH_EVERY: Duration = Duration::from_secs(60);
const MAX_LINE: u64 = 64 * 1024;

fn socket_path() -> PathBuf {
    if let Ok(p) = std::env::var("SL7_BATTERYD_SOCKET") {
        if !p.is_empty() {
            return PathBuf::from(p);
        }
    }
    let rt = std::env::var("XDG_RUNTIME_DIR").unwrap_or_else(|_| "/tmp".to_string());
    PathBuf::from(rt).join("sl7-batteryd.sock")
}

fn serve_client(id: u64, stream: UnixStream, tx: Sender<Event>) {
    let writer = match stream.try_clone() {
        Ok(w) => w,
        Err(_) => return,
    };
    if tx.send(Event::Connected(id, writer)).is_err() {
        return;
    }
    let mut reader = BufReader::new(stream);
    loop {
        let mut line = String::new();
        let n = match reader.by_ref().take(MAX_LINE).read_line(&mut line) {
            Ok(n) => n,
            Err(_) => break,
        };
        if n == 0 || !line.ends_with('\n') {
            break;
        }
        let trimmed = line.trim();
        if !trimmed.is_empty() && tx.send(Event::Line(id, trimmed.to_string())).is_err() {
            return;
        }
    }
    let _ = tx.send(Event::Disconnected(id));
}

fn main() {
    let arg = std::env::args().nth(1).unwrap_or_default();
    if arg == "--version" {
        println!("sl7-batteryd {}", env!("CARGO_PKG_VERSION"));
        return;
    }
    if arg == "--help" || arg == "-h" {
        println!("usage: sl7-batteryd [--version]\nA user service; see the omarchy-sl7-battery README.");
        return;
    }

    let sock = socket_path();
    if sock.exists() {
        if UnixStream::connect(&sock).is_ok() {
            eprintln!("sl7-batteryd: already running on {}", sock.display());
            std::process::exit(1);
        }
        let _ = std::fs::remove_file(&sock);
    }
    let listener = match UnixListener::bind(&sock) {
        Ok(l) => l,
        Err(e) => {
            eprintln!("sl7-batteryd: cannot bind {}: {}", sock.display(), e);
            std::process::exit(1);
        }
    };
    let _ = std::fs::set_permissions(&sock, std::fs::Permissions::from_mode(0o600));

    let (tx, rx) = channel::<Event>();

    {
        let tx = tx.clone();
        std::thread::spawn(move || {
            let mut next_id = 1u64;
            for conn in listener.incoming() {
                if let Ok(stream) = conn {
                    let id = next_id;
                    next_id += 1;
                    let tx = tx.clone();
                    std::thread::spawn(move || serve_client(id, stream, tx));
                }
            }
        });
    }
    if let Some(mut pipe) = sig::install() {
        let tx = tx.clone();
        std::thread::spawn(move || {
            let mut b = [0u8; 1];
            if pipe.read(&mut b).is_ok() {
                let _ = tx.send(Event::Shutdown);
            }
        });
    }
    monitor::start_all(&tx);

    let mut app = App::new(Paths::from_env());
    app.sample(true);

    let mut next_sample = Instant::now() + SAMPLE_EVERY;
    let mut next_flush = Instant::now() + FLUSH_EVERY;
    let mut resample_at: Option<Instant> = None;
    loop {
        let now = Instant::now();
        let mut deadline = next_sample.min(next_flush);
        if let Some(r) = resample_at {
            deadline = deadline.min(r);
        }
        let wait = deadline.saturating_duration_since(now);
        match rx.recv_timeout(wait) {
            Ok(Event::Connected(id, stream)) => app.connected(id, stream),
            Ok(Event::Line(id, line)) => app.handle_line(id, &line),
            Ok(Event::Disconnected(id)) => app.disconnected(id),
            Ok(Event::Sleep(down)) => {
                app.on_sleep(down);
                next_sample = Instant::now() + SAMPLE_EVERY;
            }
            Ok(Event::Profile(p)) => app.on_profile(p),
            Ok(Event::Power) => {
                // A burst of signals becomes one sample a second later.
                if resample_at.is_none() {
                    resample_at = Some(Instant::now() + Duration::from_secs(1));
                }
            }
            Ok(Event::Shutdown) => break,
            Err(std::sync::mpsc::RecvTimeoutError::Timeout) => {}
            Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => break,
        }
        let now = Instant::now();
        if let Some(r) = resample_at {
            if now >= r {
                resample_at = None;
                app.sample(false);
            }
        }
        if now >= next_sample {
            app.sample(false);
            next_sample = Instant::now() + SAMPLE_EVERY;
        }
        if now >= next_flush {
            app.flush();
            next_flush = Instant::now() + FLUSH_EVERY;
        }
    }
    app.flush();
    let _ = std::fs::remove_file(&sock);
}
