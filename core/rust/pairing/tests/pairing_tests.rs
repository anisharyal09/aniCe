// SPDX-License-Identifier: GPL-3.0-or-later
//! Integration tests for the ephemeral PAKE bridge.

use anice_pairing::{anice_pake, command, fields, parse};

#[test]
fn test_pake_full_handshake() {
    let pin = b"123456";
    let rendezvous = [7u8; 16];
    let context = b"anice-auth-context";

    // 1. Server setup
    let s_init = fields(&[pin, &rendezvous]);
    let server_handle_bytes = command(1, &s_init).expect("server init");
    assert_eq!(server_handle_bytes.len(), 8);

    // 2. Client start
    let c_init = fields(&[pin]);
    let c_start_out = command(2, &c_init).expect("client start");
    let c_fields = parse(&c_start_out).expect("parse client start");
    assert_eq!(c_fields.len(), 2);
    let client_handle_bytes = c_fields[0];
    let cred_req = c_fields[1];

    // 3. Server start
    let s_start_in = fields(&[&server_handle_bytes, cred_req, context]);
    let cred_resp = command(3, &s_start_in).expect("server start");

    // 4. Client finish
    let c_finish_in = fields(&[client_handle_bytes, pin, &cred_resp, context]);
    let c_finish_out = command(4, &c_finish_in).expect("client finish");
    let c_fin_fields = parse(&c_finish_out).expect("parse client finish");
    assert_eq!(c_fin_fields.len(), 2);
    let cred_fin = c_fin_fields[0];
    let client_session_key = c_fin_fields[1];

    // 5. Server finish
    let s_finish_in = fields(&[&server_handle_bytes, cred_fin]);
    let server_session_key = command(5, &s_finish_in).expect("server finish");

    assert_eq!(client_session_key, server_session_key);
    assert!(!client_session_key.is_empty());

    // 6. Cleanup
    let cleanup = command(6, &fields(&[&server_handle_bytes])).expect("cleanup");
    assert_eq!(cleanup, vec![1]);
}

#[test]
fn test_pake_wrong_pin_fails() {
    let pin = b"123456";
    let wrong_pin = b"654321";
    let rendezvous = [8u8; 16];
    let context = b"anice-auth-context";

    let s_init = fields(&[pin, &rendezvous]);
    let server_handle_bytes = command(1, &s_init).expect("server init");

    let c_init = fields(&[wrong_pin]);
    let c_start_out = command(2, &c_init).expect("client start");
    let c_fields = parse(&c_start_out).expect("parse client start");
    let client_handle_bytes = c_fields[0];
    let cred_req = c_fields[1];

    let s_start_in = fields(&[&server_handle_bytes, cred_req, context]);
    let cred_resp = command(3, &s_start_in).expect("server start");

    let c_finish_in = fields(&[client_handle_bytes, wrong_pin, &cred_resp, context]);
    assert!(command(4, &c_finish_in).is_err());
}

#[test]
fn test_invalid_inputs_and_c_abi() {
    assert_eq!(unsafe { anice_pake(1, std::ptr::null(), 0, std::ptr::null_mut(), 0) }, -1);
    let mut buf = [0u8; 64];
    let dummy = [0u8; 4];
    assert_eq!(unsafe { anice_pake(99, dummy.as_ptr(), dummy.len(), buf.as_mut_ptr(), buf.len()) }, -1);

    let bad_pin = fields(&[b"12345", &[0u8; 16]]);
    assert!(command(1, &bad_pin).is_err());

    let non_digit_pin = fields(&[b"12345a", &[0u8; 16]]);
    assert!(command(1, &non_digit_pin).is_err());
}

#[test]
fn test_session_cleanup_and_missing_handle() {
    let missing = 999999u64.to_be_bytes();
    let _ = command(6, &fields(&[&missing]));
    assert!(command(3, &fields(&[&missing, &[1, 2, 3], &[4, 5, 6]])).is_err());
}
