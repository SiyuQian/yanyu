/// Parsed HTTP `Content-Range` metadata for a byte-range response.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct ContentRange {
    pub start: u64,
    pub end: u64,
    /// The complete representation length, or `None` when the server reports `*`.
    pub total: Option<u64>,
}

/// Parses a single HTTP byte `Content-Range` value.
///
/// Invalid syntax, integer overflow, reversed offsets, and an end offset beyond
/// the reported representation length are rejected.
#[uniffi::export]
pub fn parse_content_range(value: String) -> Option<ContentRange> {
    let mut sections = value.split_whitespace();
    let unit = sections.next()?;
    let range_and_total = sections.next()?;
    if sections.next().is_some() || !unit.eq_ignore_ascii_case("bytes") {
        return None;
    }

    let (range, total) = range_and_total.split_once('/')?;
    let (start, end) = range.split_once('-')?;
    let start = start.parse::<u64>().ok()?;
    let end = end.parse::<u64>().ok()?;
    if end < start {
        return None;
    }

    let total = if total == "*" {
        None
    } else {
        let total = total.parse::<u64>().ok()?;
        if end >= total {
            return None;
        }
        Some(total)
    };

    Some(ContentRange { start, end, total })
}

/// Checks that a resumed byte-range response starts at the local partial's
/// current offset and contains exactly the rest of a known-size file.
#[uniffi::export]
pub fn validate_partial_content_range(
    value: String,
    expected_offset: u64,
    expected_size: u64,
) -> bool {
    parse_content_range(value).is_some_and(|range| {
        range.start == expected_offset
            && range.total == Some(expected_size)
            && range.end.checked_add(1) == Some(expected_size)
    })
}
