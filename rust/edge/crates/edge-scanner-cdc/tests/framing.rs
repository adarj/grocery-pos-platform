use edge_scanner_cdc::framing::{Framer, FramingError, FramingState};
use edge_scanner_cdc::profile::{
    DS2208_CDC_PRODUCT_ID, DS2208_CDC_VENDOR_ID, MAX_INPUT_CHUNK_BYTES, MAX_PAYLOAD_BYTES,
    MAX_QUEUED_RECORDS, MAX_SYNC_PREFIX_BYTES,
};

// These helpers establish only parser alignment, never physical activation.
fn feed_bounded(parser: &mut Framer, bytes: &[u8]) -> Result<(), FramingError> {
    for chunk in bytes.chunks(MAX_INPUT_CHUNK_BYTES) {
        parser.feed(chunk)?;
    }
    Ok(())
}

fn assert_barcode_eq(actual: &str, expected: &str) {
    // The fixed diagnostic must not stringify an expression containing a
    // barcode literal or format either value, even when the comparison fails.
    assert!(
        actual.as_bytes() == expected.as_bytes(),
        "barcode payload mismatch"
    );
}

fn take_exact(parser: &mut Framer, expected: &str) {
    let record = parser.next_record().expect("one complete record");
    assert_barcode_eq(record.as_str(), expected);
}

fn assert_sticky_failure(parser: &mut Framer, cause: FramingError) {
    assert_eq!(parser.state(), FramingState::Failed);
    assert_eq!(parser.failure(), Some(cause));
    assert_eq!(parser.queued_records(), 0);
    assert!(parser.next_record().is_none());
    for bytes in [b"".as_slice(), b"\r\n", b"replacement\r\n"] {
        assert_eq!(parser.feed(bytes), Err(FramingError::InputAfterFailure));
        assert_eq!(parser.state(), FramingState::Failed);
        assert_eq!(parser.failure(), Some(cause));
        assert!(parser.next_record().is_none());
    }
}

#[test]
fn f01_aligned_complete_frame_is_one_exact_record() {
    let mut parser = Framer::at_record_boundary();
    assert_eq!(parser.state(), FramingState::Aligned);
    assert_eq!(parser.feed(b"049000001234\r\n"), Ok(()));
    let record = parser.next_record().expect("one complete record");
    assert_barcode_eq(record.as_str(), "049000001234");
    assert!(parser.next_record().is_none());
}

#[test]
fn unknown_alignment_discards_initial_suffix_before_accepting_a_record() {
    let mut parser = Framer::new();
    assert_eq!(parser.state(), FramingState::Unsynchronized);
    assert_eq!(parser.feed(b"unverified-suffix\r\nverified\r\n"), Ok(()));
    assert_eq!(parser.state(), FramingState::Aligned);
    let record = parser.next_record().expect("only the aligned record");
    assert_barcode_eq(record.as_str(), "verified");
    assert!(parser.next_record().is_none());
}

#[test]
fn f07_failure_discards_previously_queued_records_and_is_sticky() {
    let mut parser = Framer::at_record_boundary();
    assert_eq!(parser.feed(b"queued\r\npartial"), Ok(()));
    assert_eq!(parser.queued_records(), 1);
    assert_eq!(parser.feed(b"\r\n\r\n"), Err(FramingError::EmptyRecord));
    assert_eq!(parser.state(), FramingState::Failed);
    assert_eq!(parser.queued_records(), 0);
    assert!(parser.next_record().is_none());
    assert_eq!(
        parser.feed(b"new\r\n"),
        Err(FramingError::InputAfterFailure)
    );
}

#[test]
fn reference_profile_and_documented_bounds_are_explicit() {
    assert_eq!(DS2208_CDC_VENDOR_ID, 0x05e0);
    assert_eq!(DS2208_CDC_PRODUCT_ID, 0x1701);
    assert_ne!(DS2208_CDC_PRODUCT_ID, 0x1200);
    assert_eq!(MAX_PAYLOAD_BYTES, 4096);
    assert_eq!(MAX_PAYLOAD_BYTES, edge_protocol::MAX_BARCODE_BYTES);
    assert_eq!(MAX_QUEUED_RECORDS, 16);
    assert_eq!(MAX_INPUT_CHUNK_BYTES, 4098);
    assert_eq!(MAX_SYNC_PREFIX_BYTES, 4098);
}

#[test]
fn f02_fragmented_record_emits_only_after_delimiter() {
    let mut parser = Framer::at_record_boundary();
    for chunk in [b"04".as_slice(), b"900", b"0001234"] {
        assert_eq!(parser.feed(chunk), Ok(()));
        assert!(parser.next_record().is_none());
    }
    assert_eq!(parser.feed(b"\r\n"), Ok(()));
    take_exact(&mut parser, "049000001234");
    assert!(parser.next_record().is_none());
}

#[test]
fn f03_pending_cr_is_explicit_and_not_a_payload_byte() {
    let mut parser = Framer::at_record_boundary();
    assert_eq!(parser.feed(b"value\r"), Ok(()));
    assert!(parser.next_record().is_none());
    assert_eq!(parser.feed(b""), Ok(()));
    assert!(parser.next_record().is_none());
    assert_eq!(parser.feed(b"\n"), Ok(()));
    take_exact(&mut parser, "value");
}

#[test]
fn every_byte_split_including_utf8_codepoints_and_delimiter_is_equivalent() {
    let input = "0é🦓 value\r\n".as_bytes();
    for split in 0..=input.len() {
        let mut parser = Framer::at_record_boundary();
        assert_eq!(parser.feed(&input[..split]), Ok(()));
        if split < input.len() {
            assert!(parser.next_record().is_none());
        }
        assert_eq!(parser.feed(&input[split..]), Ok(()));
        take_exact(&mut parser, "0é🦓 value");
        assert!(parser.next_record().is_none());
    }
}

#[test]
fn f04_multiple_records_and_chunk_patterns_preserve_order() {
    let input = "first\r\nsecond🦓\r\nthird\r\n".as_bytes();
    for size in 1..=input.len() {
        let mut parser = Framer::at_record_boundary();
        for chunk in input.chunks(size) {
            assert_eq!(parser.feed(chunk), Ok(()));
        }
        assert_eq!(parser.queued_records(), 3);
        for expected in ["first", "second🦓", "third"] {
            take_exact(&mut parser, expected);
        }
        assert!(parser.next_record().is_none());
    }
}

#[test]
fn all_partitions_of_two_short_frames_are_equivalent() {
    let bytes = b"a\r\nb\r\n";
    for boundaries in 0..(1 << (bytes.len() - 1)) {
        let mut parser = Framer::at_record_boundary();
        let mut start = 0;
        for end in 1..=bytes.len() {
            if end == bytes.len() || boundaries & (1 << (end - 1)) != 0 {
                assert_eq!(parser.feed(&bytes[start..end]), Ok(()));
                start = end;
            }
        }
        take_exact(&mut parser, "a");
        take_exact(&mut parser, "b");
        assert!(parser.next_record().is_none());
    }
}

#[test]
fn f05_identical_intentional_records_are_not_deduplicated() {
    let mut parser = Framer::at_record_boundary();
    assert_eq!(parser.feed(b"049000001234\r\n049000001234\r\n"), Ok(()));
    assert_eq!(parser.queued_records(), 2);
    take_exact(&mut parser, "049000001234");
    assert_eq!(parser.queued_records(), 1);
    take_exact(&mut parser, "049000001234");
    assert!(parser.next_record().is_none());
}

#[test]
fn f06_leading_zeros_spaces_case_controls_and_nul_are_preserved() {
    let payload = " 000042 aBc\t\0\u{1f}é ";
    let mut parser = Framer::at_record_boundary();
    assert_eq!(parser.feed(format!("{payload}\r\n").as_bytes()), Ok(()));
    take_exact(&mut parser, payload);
}

#[test]
fn one_byte_payload_is_valid() {
    let mut parser = Framer::at_record_boundary();
    assert_eq!(parser.feed(b"0\r\n"), Ok(()));
    take_exact(&mut parser, "0");
}

#[test]
fn maximum_ascii_payload_and_pending_cr_fit_exactly() {
    let payload = "x".repeat(MAX_PAYLOAD_BYTES);
    let mut parser = Framer::at_record_boundary();
    assert_eq!(parser.feed(payload.as_bytes()), Ok(()));
    assert_eq!(parser.feed(b"\r"), Ok(()));
    assert!(parser.next_record().is_none());
    assert_eq!(parser.feed(b"\n"), Ok(()));
    take_exact(&mut parser, &payload);
    assert_eq!(parser.feed(format!("{payload}\r\n").as_bytes()), Ok(()));
    take_exact(&mut parser, &payload);
}

#[test]
fn malformed_byte_after_pending_cr_at_payload_limit_clears_queued_records() {
    let payload = "x".repeat(MAX_PAYLOAD_BYTES);
    for next in [b'x', b'\r', 0, 0xff] {
        let mut parser = Framer::at_record_boundary();
        assert_eq!(parser.feed(b"queued\r\n"), Ok(()));
        assert_eq!(parser.feed(payload.as_bytes()), Ok(()));
        assert_eq!(parser.feed(b"\r"), Ok(()));
        assert_eq!(parser.queued_records(), 1);
        assert_eq!(parser.state(), FramingState::Aligned);
        assert_eq!(parser.feed(&[next]), Err(FramingError::CrNotFollowedByLf));
        assert_sticky_failure(&mut parser, FramingError::CrNotFollowedByLf);
    }
}

#[test]
fn maximum_multibyte_payload_is_measured_in_encoded_bytes() {
    let payload = "🦓".repeat(MAX_PAYLOAD_BYTES / 4);
    assert_eq!(payload.len(), MAX_PAYLOAD_BYTES);
    let mut parser = Framer::at_record_boundary();
    assert_eq!(
        feed_bounded(&mut parser, format!("{payload}\r\n").as_bytes()),
        Ok(())
    );
    take_exact(&mut parser, &payload);
}

#[test]
fn f07_empty_record_fails_even_after_valid_queued_records() {
    let mut parser = Framer::at_record_boundary();
    assert_eq!(
        parser.feed(b"valid\r\n\r\n"),
        Err(FramingError::EmptyRecord)
    );
    assert_sticky_failure(&mut parser, FramingError::EmptyRecord);
}

#[test]
fn f08_invalid_and_truncated_utf8_fail_only_when_record_completes() {
    for payload in [
        b"\xff".as_slice(),
        b"\xc0\x80",
        b"\xe2\x82",
        b"\xed\xa0\x80",
    ] {
        let mut parser = Framer::at_record_boundary();
        assert_eq!(parser.feed(payload), Ok(()));
        assert!(parser.next_record().is_none());
        assert_eq!(parser.feed(b"\r\n"), Err(FramingError::InvalidUtf8));
        assert_sticky_failure(&mut parser, FramingError::InvalidUtf8);
    }
}

#[test]
fn f09_payload_limit_plus_one_fails_before_delimiter() {
    let mut parser = Framer::at_record_boundary();
    assert_eq!(parser.feed(b"queued\r\n"), Ok(()));
    assert_eq!(parser.feed(&vec![b'x'; MAX_PAYLOAD_BYTES]), Ok(()));
    assert_eq!(parser.queued_records(), 1);
    assert_eq!(parser.feed(b"x"), Err(FramingError::PayloadTooLong));
    assert_sticky_failure(&mut parser, FramingError::PayloadTooLong);
}

#[test]
fn f09_oversized_delimited_payload_and_multibyte_overflow_fail() {
    for payload in ["x".repeat(4097), format!("{}é", "é".repeat(2048))] {
        let mut parser = Framer::at_record_boundary();
        assert_eq!(
            feed_bounded(&mut parser, format!("{payload}\r\n").as_bytes()),
            Err(FramingError::PayloadTooLong)
        );
        assert_sticky_failure(&mut parser, FramingError::PayloadTooLong);
    }
}

#[test]
fn f10_bare_lf_is_not_a_record_boundary() {
    let mut parser = Framer::at_record_boundary();
    assert_eq!(parser.feed(b"secret\n"), Err(FramingError::BareLf));
    assert_sticky_failure(&mut parser, FramingError::BareLf);
}

#[test]
fn f10_cr_followed_by_non_lf_never_resynchronizes() {
    for next in [b'x', b'\r', 0, 0xff] {
        let mut parser = Framer::at_record_boundary();
        assert_eq!(parser.feed(b"secret\r"), Ok(()));
        assert_eq!(parser.feed(&[next]), Err(FramingError::CrNotFollowedByLf));
        assert_sticky_failure(&mut parser, FramingError::CrNotFollowedByLf);
    }
}

#[test]
fn f11_queue_reuse_preserves_fifo_with_distinct_records_at_capacity() {
    let mut parser = Framer::at_record_boundary();
    for index in 0..MAX_QUEUED_RECORDS {
        assert_eq!(
            parser.feed(format!("record-{index}\r\n").as_bytes()),
            Ok(())
        );
    }
    assert_eq!(parser.queued_records(), 16);
    for index in 0..(2 * MAX_QUEUED_RECORDS) {
        take_exact(&mut parser, &format!("record-{index}"));
        assert_eq!(parser.queued_records(), 15);
        let next = index + MAX_QUEUED_RECORDS;
        assert_eq!(parser.feed(format!("record-{next}\r\n").as_bytes()), Ok(()));
        assert_eq!(parser.queued_records(), 16);
    }
    for index in (2 * MAX_QUEUED_RECORDS)..(3 * MAX_QUEUED_RECORDS) {
        take_exact(&mut parser, &format!("record-{index}"));
    }
    assert!(parser.next_record().is_none());
}

#[test]
fn f11_queue_limit_plus_one_fails_and_clears_all_undelivered_records() {
    let mut parser = Framer::at_record_boundary();
    assert_eq!(
        parser.feed(b"value\r\n".repeat(17).as_slice()),
        Err(FramingError::QueueCapacityExceeded)
    );
    assert_sticky_failure(&mut parser, FramingError::QueueCapacityExceeded);
}

#[test]
fn maximum_size_records_also_obey_the_queue_limit() {
    let frame = format!("{}\r\n", "x".repeat(MAX_PAYLOAD_BYTES));
    let mut parser = Framer::at_record_boundary();
    for _ in 0..MAX_QUEUED_RECORDS {
        assert_eq!(parser.feed(frame.as_bytes()), Ok(()));
    }
    assert_eq!(
        parser.feed(frame.as_bytes()),
        Err(FramingError::QueueCapacityExceeded)
    );
    assert_sticky_failure(&mut parser, FramingError::QueueCapacityExceeded);
}

#[test]
fn malformed_data_after_queued_records_clears_them_for_every_error_class() {
    for (bytes, cause) in [
        (b"\r\n".as_slice(), FramingError::EmptyRecord),
        (b"\xff\r\n", FramingError::InvalidUtf8),
        (b"x\n", FramingError::BareLf),
        (b"x\rx", FramingError::CrNotFollowedByLf),
    ] {
        let mut parser = Framer::at_record_boundary();
        assert_eq!(parser.feed(b"old-queued-secret\r\n"), Ok(()));
        assert_eq!(parser.feed(bytes), Err(cause));
        assert_sticky_failure(&mut parser, cause);
    }
    let mut parser = Framer::at_record_boundary();
    assert_eq!(parser.feed(b"old-queued-secret\r\n"), Ok(()));
    assert_eq!(
        parser.feed(&vec![b'x'; 4097]),
        Err(FramingError::PayloadTooLong)
    );
    assert_sticky_failure(&mut parser, FramingError::PayloadTooLong);
}

#[test]
fn oversized_input_chunk_fails_before_consuming_any_of_its_records() {
    for mut parser in [Framer::new(), Framer::at_record_boundary()] {
        let input = b"x\r\n".repeat(MAX_INPUT_CHUNK_BYTES / 3 + 1);
        assert!(input.len() > MAX_INPUT_CHUNK_BYTES);
        assert_eq!(parser.feed(&input), Err(FramingError::InputChunkTooLarge));
        assert_sticky_failure(&mut parser, FramingError::InputChunkTooLarge);
    }
    let mut parser = Framer::at_record_boundary();
    assert_eq!(parser.feed(b"queued\r\npartial"), Ok(()));
    assert_eq!(
        parser.feed(&vec![b'x'; MAX_INPUT_CHUNK_BYTES + 1]),
        Err(FramingError::InputChunkTooLarge)
    );
    assert_sticky_failure(&mut parser, FramingError::InputChunkTooLarge);
}

#[test]
fn two_2048_byte_records_succeed_only_with_legal_feed_sizes() {
    let first = "a".repeat(2048);
    let second = "b".repeat(2048);
    let stream = format!("{first}\r\n{second}\r\n");
    assert_eq!(stream.len(), 4100);
    assert!(stream.len() > MAX_INPUT_CHUNK_BYTES);

    let mut oversized = Framer::at_record_boundary();
    assert_eq!(
        oversized.feed(stream.as_bytes()),
        Err(FramingError::InputChunkTooLarge)
    );
    assert_sticky_failure(&mut oversized, FramingError::InputChunkTooLarge);

    let mut parser = Framer::at_record_boundary();
    let (prefix, suffix) = stream.as_bytes().split_at(MAX_INPUT_CHUNK_BYTES);
    assert_eq!(parser.feed(prefix), Ok(()));
    assert_eq!(parser.queued_records(), 1);
    assert_eq!(parser.feed(suffix), Ok(()));
    assert_eq!(parser.queued_records(), 2);
    take_exact(&mut parser, &first);
    take_exact(&mut parser, &second);
    assert!(parser.next_record().is_none());
}

#[test]
fn unknown_alignment_never_emits_an_unverified_initial_complete_record() {
    let input = b"untrusted\r\ntrusted\r\n";
    for split in 0..=input.len() {
        let mut parser = Framer::new();
        assert_eq!(parser.feed(&input[..split]), Ok(()));
        assert_eq!(parser.feed(&input[split..]), Ok(()));
        take_exact(&mut parser, "trusted");
        assert!(parser.next_record().is_none());
    }
}

#[test]
fn unknown_alignment_keeps_discarding_across_chunks_and_empty_input() {
    let mut parser = Framer::default();
    for chunk in [b"suffix".as_slice(), b"", b"\r", b""] {
        assert_eq!(parser.feed(chunk), Ok(()));
        assert_eq!(parser.state(), FramingState::Unsynchronized);
        assert!(parser.next_record().is_none());
    }
    assert_eq!(parser.feed(b"\n"), Ok(()));
    assert_eq!(parser.state(), FramingState::Aligned);
    assert!(parser.next_record().is_none());
    assert_eq!(parser.feed(b"verified\r\n"), Ok(()));
    take_exact(&mut parser, "verified");
}

#[test]
fn discarded_prefix_may_be_non_utf8_or_empty_but_is_never_a_record() {
    for prefix in [b"\xff\xfe\r\n".as_slice(), b"\r\n"] {
        let mut parser = Framer::new();
        assert_eq!(parser.feed(prefix), Ok(()));
        assert_eq!(parser.state(), FramingState::Aligned);
        assert!(parser.next_record().is_none());
        assert_eq!(parser.feed(b"valid\r\n"), Ok(()));
        take_exact(&mut parser, "valid");
    }
}

#[test]
fn synchronization_bound_includes_delimiter_and_accepts_exact_limit() {
    let mut parser = Framer::new();
    let prefix = format!("{}\r\n", "x".repeat(MAX_SYNC_PREFIX_BYTES - 2));
    assert_eq!(prefix.len(), MAX_SYNC_PREFIX_BYTES);
    assert_eq!(parser.feed(prefix.as_bytes()), Ok(()));
    assert_eq!(parser.state(), FramingState::Aligned);
    assert!(parser.next_record().is_none());
    assert_eq!(parser.feed(b"valid\r\n"), Ok(()));
    take_exact(&mut parser, "valid");
}

#[test]
fn synchronization_limit_plus_one_fails_even_if_last_byte_would_align() {
    let mut parser = Framer::new();
    let prefix = format!("{}\r\n", "x".repeat(MAX_SYNC_PREFIX_BYTES - 1));
    assert_eq!(prefix.len(), MAX_SYNC_PREFIX_BYTES + 1);
    assert_eq!(
        feed_bounded(&mut parser, prefix.as_bytes()),
        Err(FramingError::SynchronizationFailed)
    );
    assert_sticky_failure(&mut parser, FramingError::SynchronizationFailed);
}

#[test]
fn synchronization_without_delimiter_is_bounded_across_many_feeds() {
    let mut parser = Framer::new();
    for _ in 0..MAX_SYNC_PREFIX_BYTES {
        assert_eq!(parser.feed(b"x"), Ok(()));
    }
    assert_eq!(parser.state(), FramingState::Unsynchronized);
    assert_eq!(parser.feed(b"x"), Err(FramingError::SynchronizationFailed));
    assert_sticky_failure(&mut parser, FramingError::SynchronizationFailed);
}

#[test]
fn unexpected_delimiter_input_during_synchronization_fails_closed() {
    for prefix in [b"suffix\n".as_slice(), b"suffix\rx", b"suffix\r\r"] {
        let mut parser = Framer::new();
        for byte in &prefix[..prefix.len() - 1] {
            assert_eq!(parser.feed(&[*byte]), Ok(()));
        }
        assert_eq!(
            parser.feed(&prefix[prefix.len() - 1..]),
            Err(FramingError::SynchronizationFailed)
        );
        assert_sticky_failure(&mut parser, FramingError::SynchronizationFailed);
    }
}

#[test]
fn dropping_or_replacing_parser_never_retains_old_partial_or_queued_data() {
    let mut parser = Framer::at_record_boundary();
    assert_eq!(parser.feed(b"queued-old\r\npartial-old\r"), Ok(()));
    drop(parser);
    let mut parser = Framer::new();
    assert_eq!(parser.feed(b"suffix-old\r\nnew\r\n"), Ok(()));
    take_exact(&mut parser, "new");
    assert!(parser.next_record().is_none());

    assert_eq!(parser.feed(b"new-partial"), Ok(()));
    parser = Framer::at_record_boundary(); // External boundary proof is a test premise.
    assert_eq!(parser.feed(b"replacement\r\n"), Ok(()));
    take_exact(&mut parser, "replacement");
    assert!(parser.next_record().is_none());
}

#[test]
fn already_delivered_value_survives_later_failure_but_queued_values_do_not() {
    let mut parser = Framer::at_record_boundary();
    assert_eq!(parser.feed(b"delivered\r\nqueued\r\n"), Ok(()));
    let delivered = parser.next_record().expect("delivered record");
    assert_eq!(parser.feed(b"\n"), Err(FramingError::BareLf));
    assert_sticky_failure(&mut parser, FramingError::BareLf);
    assert_barcode_eq(delivered.as_str(), "delivered");
}

#[test]
fn barcode_comparison_failure_has_only_the_fixed_authored_diagnostic() {
    let failure = std::panic::catch_unwind(|| {
        assert_barcode_eq("private-actual-value", "private-expected-value");
    })
    .expect_err("unequal barcode values must fail the comparison");
    let message = failure
        .downcast_ref::<&str>()
        .copied()
        .or_else(|| failure.downcast_ref::<String>().map(String::as_str));
    assert!(
        message == Some("barcode payload mismatch"),
        "barcode comparison failure diagnostic changed"
    );
}

#[test]
fn parser_records_and_real_error_chains_never_format_barcode_bytes() {
    use std::error::Error;

    let secret = "PRIVATE-BARCODE-042424242";
    let mut parser = Framer::at_record_boundary();
    assert_eq!(
        parser.feed(format!("{secret}\r\n{secret}").as_bytes()),
        Ok(())
    );
    let diagnostics = format!("{parser:?}");
    assert!(!diagnostics.contains(secret));
    // A derived Debug on the partial Vec would expose decimal byte values
    // even though the literal UTF-8 text would not appear in the output.
    assert!(!diagnostics.contains(&format!("{:?}", secret.as_bytes())));
    let record = parser.next_record().expect("private record");
    assert!(!format!("{record:?}").contains(secret));
    let error = parser
        .feed(b"\xff\r\n")
        .expect_err("malformed secret record");
    assert_eq!(error, FramingError::InvalidUtf8);
    assert!(!format!("{error}: {error:?}; {parser:?}").contains(secret));
    assert!(error.source().is_none());
    assert_sticky_failure(&mut parser, error);

    let mut parser = Framer::new();
    assert_eq!(parser.feed(secret.as_bytes()), Ok(()));
    assert!(!format!("{parser:?}").contains(secret));
    let error = parser.feed(b"\n").expect_err("synchronization failure");
    assert!(!format!("{error}: {error:?}; {parser:?}").contains(secret));
    assert!(error.source().is_none());
}
