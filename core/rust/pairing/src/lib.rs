// SPDX-License-Identifier: GPL-3.0-or-later
//! Narrow ephemeral OPAQUE bridge.
//!
//! Provides in-memory PAKE state machines for 6-digit PIN pairing between Android
//! and macOS without persistent storage, network access, or logging.

use opaque_ke::*;
use rand::rngs::OsRng;
use std::{
    collections::HashMap,
    sync::{Mutex, OnceLock},
    time::{Duration, Instant},
};
use zeroize::{Zeroize, Zeroizing};

/// Standard OPAQUE cipher suite: Ristretto255 group, Triple-DH key exchange with SHA-512,
/// and Argon2id key derivation.
struct Suite;
impl CipherSuite for Suite {
    type OprfCs = Ristretto255;
    type KeyExchange = TripleDh<Ristretto255, sha2::Sha512>;
    type Ksf = argon2::Argon2<'static>;
}

/// Server (macOS) state holding ephemeral registration and active login session.
struct Server {
    setup: ServerSetup<Suite>,
    record: ServerRegistration<Suite>,
    id: Vec<u8>,
    login: Option<ServerLogin<Suite>>,
    context: Vec<u8>,
    attempts: u8,
}

/// Active session state variants.
enum State {
    Server(Server),
    Client(ClientLogin<Suite>),
}

/// In-memory table entry with activity timestamp.
struct Entry {
    state: State,
    used: Instant,
}

/// Defensive timeout for idle session handles.
const STATE_TTL: Duration = Duration::from_secs(300);

/// Prunes expired handles from the session table.
fn prune(states: &mut HashMap<u64, Entry>, now: Instant) {
    states.retain(|_, entry| now.saturating_duration_since(entry.used) < STATE_TTL);
}

/// Process-local thread-safe table for ephemeral pairing sessions.
static STATES: OnceLock<Mutex<(u64, HashMap<u64, Entry>)>> = OnceLock::new();

/// Key stretching function configured with Argon2id: 64 MiB memory, t=3 passes, p=1 lane.
fn ksf() -> argon2::Argon2<'static> {
    argon2::Argon2::new(
        argon2::Algorithm::Argon2id,
        argon2::Version::V0x13,
        argon2::Params::new(65536, 3, 1, None).unwrap(),
    )
}

/// Static protocol endpoint identifiers.
fn identifiers() -> Identifiers<'static> {
    Identifiers {
        client: Some(b"android"),
        server: Some(b"macos"),
    }
}

/// Packs multiple byte slices with uint32 big-endian length prefixes.
pub fn fields(values: &[&[u8]]) -> Vec<u8> {
    values
        .iter()
        .flat_map(|v| (v.len() as u32).to_be_bytes().into_iter().chain(v.iter().copied()))
        .collect()
}

/// Parses uint32 length-prefixed fields from input buffer.
pub fn parse(input: &[u8]) -> Result<Vec<&[u8]>, ()> {
    let mut f = Vec::new();
    let mut rest = input;
    if rest.len() > 4096 {
        return Err(());
    }
    while !rest.is_empty() {
        if rest.len() < 4 || f.len() >= 8 {
            return Err(());
        }
        let n = u32::from_be_bytes(rest[..4].try_into().map_err(|_| ())?) as usize;
        rest = &rest[4..];
        if n > rest.len() {
            return Err(());
        }
        f.push(&rest[..n]);
        rest = &rest[n..];
    }
    Ok(f)
}

/// Decodes uint64 session handle.
fn handle(bytes: &[u8]) -> Result<u64, ()> {
    Ok(u64::from_be_bytes(bytes.try_into().map_err(|_| ())?))
}

/// Dispatches operations 1..6 on in-memory OPAQUE state machines.
pub fn command(op: u32, input: &[u8]) -> Result<Vec<u8>, ()> {
    let f = parse(input)?;
    let mut lock = STATES
        .get_or_init(|| Mutex::new((0, HashMap::new())))
        .lock()
        .map_err(|_| ())?;
    let now = Instant::now();
    prune(&mut lock.1, now);
    let mut rng = OsRng;
    match op {
        // Op 1: Server setup & registration with 6-digit PIN and rendezvous ID
        1 => {
            if f.len() != 2
                || f[1].len() != 16
                || f[0].len() != 6
                || !f[0].iter().all(u8::is_ascii_digit)
                || lock.1.len() >= 64
            {
                return Err(());
            }
            let setup = ServerSetup::<Suite>::new(&mut rng);
            let reg = ClientRegistration::<Suite>::start(&mut rng, f[0]).map_err(|_| ())?;
            let response = ServerRegistration::start(&setup, reg.message, f[1]).map_err(|_| ())?;
            let finished = reg
                .state
                .finish(
                    &mut rng,
                    f[0],
                    response.message,
                    ClientRegistrationFinishParameters::new(identifiers(), Some(&ksf())),
                )
                .map_err(|_| ())?;
            let server = Server {
                setup,
                record: ServerRegistration::finish(finished.message),
                id: f[1].to_vec(),
                login: None,
                context: Vec::new(),
                attempts: 0,
            };
            lock.0 = lock.0.checked_add(1).ok_or(())?;
            let id = lock.0;
            lock.1.insert(id, Entry { state: State::Server(server), used: now });
            Ok(id.to_be_bytes().to_vec())
        }
        // Op 2: Client login start with 6-digit PIN (outputs clientHandle and CredentialRequest)
        2 => {
            if f.len() != 1 || f[0].len() != 6 || !f[0].iter().all(u8::is_ascii_digit) || lock.1.len() >= 64 {
                return Err(());
            }
            let start = ClientLogin::<Suite>::start(&mut rng, f[0]).map_err(|_| ())?;
            lock.0 = lock.0.checked_add(1).ok_or(())?;
            let id = lock.0;
            let out = fields(&[&id.to_be_bytes(), &start.message.serialize()]);
            lock.1.insert(id, Entry { state: State::Client(start.state), used: now });
            Ok(out)
        }
        // Op 3: Server login start (processes CredentialRequest, produces CredentialResponse)
        3 => {
            if f.len() != 3 {
                return Err(());
            }
            let id = handle(f[0])?;
            let entry = lock.1.get_mut(&id).ok_or(())?;
            entry.used = now;
            let State::Server(s) = &mut entry.state else {
                return Err(());
            };
            if s.attempts >= 5 {
                return Err(());
            }
            s.attempts += 1;
            s.login = None;
            let req = CredentialRequest::deserialize(f[1]).map_err(|_| ())?;
            let start = ServerLogin::start(
                &mut rng,
                &s.setup,
                Some(s.record.clone()),
                req,
                &s.id,
                ServerLoginParameters {
                    context: Some(f[2]),
                    identifiers: identifiers(),
                },
            )
            .map_err(|_| ())?;
            let out = start.message.serialize().to_vec();
            s.login = Some(start.state);
            s.context = f[2].to_vec();
            Ok(out)
        }
        // Op 4: Client login finish (processes CredentialResponse, outputs CredentialFinalization and sessionKey)
        4 => {
            if f.len() != 4 {
                return Err(());
            }
            let id = handle(f[0])?;
            if !matches!(lock.1.get(&id).map(|e| &e.state), Some(State::Client(_))) {
                return Err(());
            }
            let State::Client(s) = lock.1.remove(&id).ok_or(())?.state else {
                return Err(());
            };
            let response = CredentialResponse::deserialize(f[2]).map_err(|_| ())?;
            let finish = s
                .finish(
                    &mut rng,
                    f[1],
                    response,
                    ClientLoginFinishParameters::new(Some(f[3]), identifiers(), Some(&ksf())),
                )
                .map_err(|_| ())?;
            Ok(fields(&[&finish.message.serialize(), &finish.session_key]))
        }
        // Op 5: Server login finish (processes CredentialFinalization, outputs shared sessionKey)
        5 => {
            if f.len() != 2 {
                return Err(());
            }
            let id = handle(f[0])?;
            let entry = lock.1.get_mut(&id).ok_or(())?;
            entry.used = now;
            let State::Server(s) = &mut entry.state else {
                return Err(());
            };
            let finalization = CredentialFinalization::deserialize(f[1]).map_err(|_| ())?;
            let login = s.login.take().ok_or(())?;
            let finish = login
                .finish(
                    finalization,
                    ServerLoginParameters {
                        context: Some(&s.context),
                        identifiers: identifiers(),
                    },
                )
                .map_err(|_| ())?;
            Ok(finish.session_key.to_vec())
        }
        // Op 6: Release session handle from memory
        6 => {
            if f.len() != 1 {
                return Err(());
            }
            lock.1.remove(&handle(f[0])?);
            Ok(vec![1])
        }
        _ => Err(()),
    }
}

/// C ABI entry point.
///
/// Caller owns input and output buffers. Returns bytes written on success, or -1 on failure.
#[no_mangle]
pub unsafe extern "C" fn anice_pake(
    op: u32,
    input: *const u8,
    len: usize,
    out: *mut u8,
    capacity: usize,
) -> isize {
    if input.is_null() || out.is_null() || len > 4096 || capacity < 1 {
        return -1;
    }
    let result = std::panic::catch_unwind(|| {
        let input = Zeroizing::new(std::slice::from_raw_parts(input, len).to_vec());
        let mut result = command(op, &input)?;
        if result.len() > capacity {
            result.zeroize();
            return Err(());
        }
        std::ptr::copy_nonoverlapping(result.as_ptr(), out, result.len());
        let n = result.len();
        result.zeroize();
        Ok(n)
    });
    match result {
        Ok(Ok(n)) => n as isize,
        _ => -1,
    }
}

/// JNI entry point for Android.
#[cfg(target_os = "android")]
#[no_mangle]
pub extern "system" fn Java_io_github_anisharyal09_anice_infrastructure_pairing_NativePake_call(
    mut env: jni::JNIEnv,
    _class: jni::objects::JClass,
    op: jni::sys::jint,
    input: jni::objects::JByteArray,
) -> jni::sys::jbyteArray {
    let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        if env.get_array_length(&input).map_err(|_| ())? > 4096 {
            return Err(());
        }
        let bytes = Zeroizing::new(env.convert_byte_array(input).map_err(|_| ())?);
        let result = Zeroizing::new(command(op as u32, &bytes)?);
        env.byte_array_from_slice(&result).map_err(|_| ())
    }));
    match result {
        Ok(Ok(arr)) => arr.into_raw(),
        _ => {
            let _ = env.throw_new("java/lang/IllegalStateException", "PAKE bridge failure");
            std::ptr::null_mut()
        }
    }
}

