use yanyu_core::{parse_content_range, validate_partial_content_range, ContentRange};

#[test]
fn parses_satisfied_and_unsatisfied_total_lengths() {
    assert_eq!(
        parse_content_range(" BYTES 65-99/100 ".into()),
        Some(ContentRange {
            start: 65,
            end: 99,
            total: Some(100),
        })
    );
    assert_eq!(
        parse_content_range("bytes 5-9/*".into()),
        Some(ContentRange {
            start: 5,
            end: 9,
            total: None,
        })
    );
}

#[test]
fn rejects_malformed_or_impossible_ranges() {
    for value in [
        "items 0-1/2",
        "bytes 0/2",
        "bytes 2-1/3",
        "bytes 0-3/3",
        "bytes 1-2/2",
        "bytes 0-1/*tail",
        "bytes 18446744073709551616-18446744073709551616/18446744073709551617",
    ] {
        assert_eq!(parse_content_range(value.into()), None, "{value}");
    }
}

#[test]
fn validates_resumed_ranges_against_offset_and_full_size() {
    assert!(validate_partial_content_range(
        "bytes 65-99/100".into(),
        65,
        100
    ));

    for (value, offset, size) in [
        ("bytes 64-99/100", 65, 100),
        ("bytes 65-98/100", 65, 100),
        ("bytes 65-99/101", 65, 100),
        ("bytes 65-99/*", 65, 100),
        ("invalid", 65, 100),
    ] {
        assert!(
            !validate_partial_content_range(value.into(), offset, size),
            "{value}"
        );
    }
}
