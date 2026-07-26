use std::cmp::Ordering;

/// Compare archive paths using ASCII-aware natural ordering.
///
/// Numeric runs are compared by value without parsing them into a fixed-size
/// integer, so arbitrarily long page numbers remain safe and deterministic.
#[must_use]
pub fn natural_cmp(left: &str, right: &str) -> Ordering {
    let left_bytes = left.as_bytes();
    let right_bytes = right.as_bytes();
    let mut left_index = 0;
    let mut right_index = 0;

    while left_index < left_bytes.len() && right_index < right_bytes.len() {
        let left_is_digit = left_bytes[left_index].is_ascii_digit();
        let right_is_digit = right_bytes[right_index].is_ascii_digit();

        if left_is_digit && right_is_digit {
            let left_end = digit_run_end(left_bytes, left_index);
            let right_end = digit_run_end(right_bytes, right_index);
            let ordering = compare_digit_runs(
                &left_bytes[left_index..left_end],
                &right_bytes[right_index..right_end],
            );
            if ordering != Ordering::Equal {
                return ordering;
            }
            left_index = left_end;
            right_index = right_end;
            continue;
        }

        let left_folded = left_bytes[left_index].to_ascii_lowercase();
        let right_folded = right_bytes[right_index].to_ascii_lowercase();
        match left_folded.cmp(&right_folded) {
            Ordering::Equal => {
                left_index += 1;
                right_index += 1;
            }
            ordering => return ordering,
        }
    }

    match (
        left_index == left_bytes.len(),
        right_index == right_bytes.len(),
    ) {
        (true, true) | (false, false) => Ordering::Equal,
        (true, false) => Ordering::Less,
        (false, true) => Ordering::Greater,
    }
}

fn digit_run_end(bytes: &[u8], start: usize) -> usize {
    let mut end = start;
    while end < bytes.len() && bytes[end].is_ascii_digit() {
        end += 1;
    }
    end
}

fn compare_digit_runs(left: &[u8], right: &[u8]) -> Ordering {
    let left_significant = trim_leading_zeroes(left);
    let right_significant = trim_leading_zeroes(right);

    left_significant
        .len()
        .cmp(&right_significant.len())
        .then_with(|| left_significant.cmp(right_significant))
}

fn trim_leading_zeroes(bytes: &[u8]) -> &[u8] {
    let first_nonzero = bytes
        .iter()
        .position(|byte| *byte != b'0')
        .unwrap_or(bytes.len());
    &bytes[first_nonzero..]
}

#[cfg(test)]
mod tests {
    use super::natural_cmp;

    #[test]
    fn sorts_page_numbers_naturally() {
        let mut paths = vec![
            "chapter/page10.jpg",
            "chapter/page2.jpg",
            "chapter/page1.jpg",
            "chapter/page20.jpg",
            "chapter/page11.jpg",
        ];

        paths.sort_by(|left, right| natural_cmp(left, right));

        assert_eq!(
            paths,
            vec![
                "chapter/page1.jpg",
                "chapter/page2.jpg",
                "chapter/page10.jpg",
                "chapter/page11.jpg",
                "chapter/page20.jpg",
            ]
        );
    }

    #[test]
    fn numeric_runs_do_not_overflow() {
        let short = "page9999999999999999999999999999999.png";
        let long = "page10000000000000000000000000000000.png";
        assert!(natural_cmp(short, long).is_lt());
    }

    #[test]
    fn case_and_leading_zero_variants_are_mupdf_equivalent() {
        assert!(natural_cmp("Page1.JPG", "page1.jpg").is_eq());
        assert!(natural_cmp("page1.jpg", "page01.jpg").is_eq());
    }
}
