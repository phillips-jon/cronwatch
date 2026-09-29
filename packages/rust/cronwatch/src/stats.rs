//! Percentile and median (stats.ts).

fn sorted(values: &[f64]) -> Vec<f64> {
    let mut out = values.to_vec();
    out.sort_by(f64::total_cmp);
    out
}

/// stats.ts `percentile`: the nearest-rank value, with the rank worked out in
/// the same floating point steps as JavaScript's, so a Rust and a Node
/// process pick the same run. `None` for no values.
pub(crate) fn percentile(values: &[f64], p: f64) -> Option<f64> {
    if values.is_empty() {
        return None;
    }
    let sorted = sorted(values);
    let n = sorted.len() as f64;
    let index = ((n - 1.0).min(((p / 100.0) * n).ceil() - 1.0).max(0.0)) as usize;
    Some(sorted[index])
}

/// stats.ts `median`: the middle value, or the mean of the two in the middle.
pub(crate) fn median(values: &[f64]) -> Option<f64> {
    if values.is_empty() {
        return None;
    }
    let sorted = sorted(values);
    let mid = sorted.len() / 2;
    Some(if sorted.len() % 2 == 0 { (sorted[mid - 1] + sorted[mid]) / 2.0 } else { sorted[mid] })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn percentiles_and_medians() {
        assert_eq!(percentile(&[], 50.0), None);
        assert_eq!(percentile(&[5.0, 1.0, 3.0], 50.0), Some(3.0));
        assert_eq!(percentile(&[1.0, 2.0, 3.0, 4.0], 95.0), Some(4.0));
        assert_eq!(percentile(&[1.0, 2.0], 0.0), Some(1.0));
        assert_eq!(median(&[4.0, 1.0, 3.0, 2.0]), Some(2.5));
        assert_eq!(median(&[3.0]), Some(3.0));
    }
}
