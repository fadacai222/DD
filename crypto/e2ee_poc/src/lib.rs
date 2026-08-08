#![forbid(unsafe_code)]

//! Isolated P0 E2EE feasibility checks for DD.
//!
//! This crate is intentionally not wired into the application. It validates
//! vodozemac's Olm/Double-Ratchet behavior and persistence before DD freezes a
//! production encrypted-message format or FFI/WASM boundary.

#[cfg(test)]
mod tests {
    use vodozemac::olm::{
        Account, AccountPickle, OlmMessage, Session, SessionConfig, SessionPickle,
    };

    const PICKLE_KEY: [u8; 32] = [0x42; 32];

    struct Pair {
        alice_account: Account,
        bob_account: Account,
        alice_session: Session,
        bob_session: Session,
    }

    fn establish_pair(initial_plaintext: &str) -> Pair {
        let alice_account = Account::new();
        let mut bob_account = Account::new();
        bob_account.generate_one_time_keys(1);

        let bob_identity_key = bob_account.curve25519_key();
        let bob_one_time_key = bob_account
            .one_time_keys()
            .into_values()
            .next()
            .expect("Bob must have a generated one-time key");
        bob_account.mark_keys_as_published();

        let mut alice_session = alice_account
            .create_outbound_session(
                SessionConfig::version_1(),
                bob_identity_key,
                bob_one_time_key,
            )
            .expect("Alice should create an outbound session");
        let first_message = alice_session
            .encrypt(initial_plaintext)
            .expect("Alice should encrypt the pre-key message");
        let OlmMessage::PreKey(pre_key_message) = first_message else {
            panic!("the first outbound message must be a pre-key message");
        };

        let inbound = bob_account
            .create_inbound_session(
                SessionConfig::version_1(),
                alice_account.curve25519_key(),
                &pre_key_message,
            )
            .expect("Bob should create an inbound session");
        assert_eq!(inbound.plaintext, initial_plaintext.as_bytes());
        assert_eq!(bob_account.stored_one_time_key_count(), 0);

        Pair {
            alice_account,
            bob_account,
            alice_session,
            bob_session: inbound.session,
        }
    }

    #[test]
    fn asynchronous_prekey_handshake_and_bidirectional_ratchet_work() {
        let mut pair = establish_pair("hello from alice");

        let reply = pair
            .bob_session
            .encrypt("hello from bob")
            .expect("Bob should encrypt a reply");
        assert_eq!(
            pair.alice_session
                .decrypt(&reply)
                .expect("Alice should decrypt Bob's reply"),
            b"hello from bob"
        );

        for index in 0..1000 {
            let plaintext = format!("alice-{index}");
            let encrypted = pair
                .alice_session
                .encrypt(&plaintext)
                .expect("Alice should encrypt ratcheted message");
            assert_eq!(
                pair.bob_session
                    .decrypt(&encrypted)
                    .expect("Bob should decrypt ratcheted message"),
                plaintext.as_bytes()
            );

            let plaintext = format!("bob-{index}");
            let encrypted = pair
                .bob_session
                .encrypt(&plaintext)
                .expect("Bob should encrypt ratcheted message");
            assert_eq!(
                pair.alice_session
                    .decrypt(&encrypted)
                    .expect("Alice should decrypt ratcheted message"),
                plaintext.as_bytes()
            );
        }
    }

    #[test]
    fn out_of_order_delivery_is_supported_and_duplicate_ciphertext_is_rejected() {
        let mut pair = establish_pair("bootstrap");
        let reply = pair
            .bob_session
            .encrypt("activate receiving chain")
            .expect("Bob should encrypt");
        pair.alice_session
            .decrypt(&reply)
            .expect("Alice should decrypt");

        let messages: Vec<(String, OlmMessage)> = (0..6)
            .map(|index| {
                let plaintext = format!("out-of-order-{index}");
                let message = pair
                    .bob_session
                    .encrypt(&plaintext)
                    .expect("Bob should encrypt");
                (plaintext, message)
            })
            .collect();

        for index in [5usize, 2, 4, 0, 3, 1] {
            assert_eq!(
                pair.alice_session
                    .decrypt(&messages[index].1)
                    .expect("out-of-order message should decrypt"),
                messages[index].0.as_bytes()
            );
        }

        let serialized = serde_json::to_string(&messages[3].1).expect("serialize Olm message");
        let duplicate: OlmMessage =
            serde_json::from_str(&serialized).expect("deserialize Olm message");
        assert!(
            pair.alice_session.decrypt(&duplicate).is_err(),
            "a consumed ciphertext must not decrypt twice"
        );
    }

    #[test]
    fn encrypted_account_and_session_pickles_resume_without_changing_session_id() {
        let mut pair = establish_pair("bootstrap");
        let reply = pair
            .bob_session
            .encrypt("before persistence")
            .expect("Bob should encrypt");
        pair.alice_session
            .decrypt(&reply)
            .expect("Alice should decrypt");

        let alice_account_pickle = pair.alice_account.pickle().encrypt(&PICKLE_KEY);
        let bob_account_pickle = pair.bob_account.pickle().encrypt(&PICKLE_KEY);
        let alice_session_id = pair.alice_session.session_id();
        let bob_session_id = pair.bob_session.session_id();
        let alice_session_pickle = pair.alice_session.pickle().encrypt(&PICKLE_KEY);
        let bob_session_pickle = pair.bob_session.pickle().encrypt(&PICKLE_KEY);

        let restored_alice_account = Account::from_pickle(
            AccountPickle::from_encrypted(&alice_account_pickle, &PICKLE_KEY)
                .expect("restore Alice account pickle"),
        );
        let restored_bob_account = Account::from_pickle(
            AccountPickle::from_encrypted(&bob_account_pickle, &PICKLE_KEY)
                .expect("restore Bob account pickle"),
        );
        assert_eq!(
            restored_alice_account.curve25519_key(),
            pair.alice_account.curve25519_key()
        );
        assert_eq!(
            restored_bob_account.curve25519_key(),
            pair.bob_account.curve25519_key()
        );

        let mut restored_alice_session = Session::from_pickle(
            SessionPickle::from_encrypted(&alice_session_pickle, &PICKLE_KEY)
                .expect("restore Alice session pickle"),
        );
        let mut restored_bob_session = Session::from_pickle(
            SessionPickle::from_encrypted(&bob_session_pickle, &PICKLE_KEY)
                .expect("restore Bob session pickle"),
        );
        assert_eq!(restored_alice_session.session_id(), alice_session_id);
        assert_eq!(restored_bob_session.session_id(), bob_session_id);

        let message = restored_alice_session
            .encrypt("after persistence")
            .expect("Alice should encrypt after restore");
        assert_eq!(
            restored_bob_session
                .decrypt(&message)
                .expect("Bob should decrypt after restore"),
            b"after persistence"
        );
    }

    #[test]
    fn wrong_pickle_key_cannot_restore_account_or_session() {
        let pair = establish_pair("bootstrap");
        let account_pickle = pair.alice_account.pickle().encrypt(&PICKLE_KEY);
        let session_pickle = pair.alice_session.pickle().encrypt(&PICKLE_KEY);
        let wrong_key = [0x24; 32];

        assert!(AccountPickle::from_encrypted(&account_pickle, &wrong_key).is_err());
        assert!(SessionPickle::from_encrypted(&session_pickle, &wrong_key).is_err());
    }
}
