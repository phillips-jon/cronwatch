//! Doors for the cargo-fuzz targets in `packages/rust/fuzz` into the parts
//! that have no public one. Built only under cargo-fuzz, which passes
//! `--cfg fuzzing`; not part of the API.

/// A pattern as a stored `matches /source/flags` rule hands it to the
/// JavaScript regular expression engine: read, then run over `text`, as a
/// test and as a replacement, each within the step budget.
pub fn regexp(source: &str, flags: &str, text: &str) {
    if let Ok(re) = crate::jsre::Regexp::new(source, flags) {
        let _ = re.try_is_match(text);
        let _ = re.try_replace_units(&crate::js::units(text), |m| m.group(1).unwrap_or_default().to_vec());
    }
}

/// A `Host` header and an origin as the dashboard reads them: the request's
/// own origin, whether it is loopback (the development sign-in link), and
/// the text read as a configured or forwarded origin.
pub fn origin(host: &[u8], tls: bool, text: &str) {
    use crate::web::origin::{bare_origin, configured_origin, is_loopback_origin, request_origin};
    let own = request_origin(tls, host);
    let _ = is_loopback_origin(&own);
    if let Some(bare) = bare_origin(text) {
        // A bare origin reads back as itself.
        assert_eq!(bare_origin(&bare).as_deref(), Some(bare.as_str()), "{text:?}");
        let _ = is_loopback_origin(&bare);
    }
    let _ = configured_origin(text);
}
