//! Twilio SMS (`alerts/twilio.ts`). API reference:
//! <https://www.twilio.com/docs/messaging/api/message-resource>. POST
//! `https://api.twilio.com/2010-04-01/Accounts/<AccountSid>/Messages.json`,
//! form encoded, with basic auth. One recipient per request.

use std::sync::Arc;

use super::post::{Transport, cut};
use super::shared::{LinkFn, basic_auth, encode_uri_component, form, invalid, link_for, send, triage, trimmed};
use crate::deliver::{Channel, ChannelContext};
use crate::error::Error;
use crate::js;
use crate::panics::panic_text;
use crate::store::{BoxError, BoxFuture};
use crate::types::{Alert, AlertType};

/// Configures [`twilio`].
#[derive(Clone, Default)]
pub struct TwilioOptions {
    /// The account SID, `AC...`. It is in the URL whichever credentials sign
    /// the request.
    pub account_sid: String,
    /// The account's auth token. Or give `api_key_sid` and `api_key_secret`
    /// instead.
    pub auth_token: String,
    /// An API key SID, `SK...`, with `api_key_secret`, in place of the auth
    /// token.
    pub api_key_sid: String,
    pub api_key_secret: String,
    /// A Twilio number in E.164 form, `+15005550006`. Or give
    /// `messaging_service_sid`.
    pub from: String,
    /// A messaging service SID, `MG...`, in place of `from`.
    pub messaging_service_sid: String,
    /// One number in E.164 form, or several; each gets its own message.
    pub to: Vec<String>,
    /// Also texts when a job recovers. Off by default: a text is for what
    /// needs a person.
    pub recovered: bool,
    /// How many SMS segments a message may use, 1 to [`MAX_SEGMENTS`].
    /// `None` for 3.
    pub segments: Option<u32>,
    /// A link back to the job in your dashboard, kept whole at the end of the
    /// text.
    pub link: Option<LinkFn>,
    /// Sends the requests; `None` for the default [`ReqwestTransport`](super::ReqwestTransport).
    pub transport: Option<Arc<dyn Transport>>,
}

/// The most segments a message may use, which keeps it inside Twilio's 1600
/// character Body limit.
pub const MAX_SEGMENTS: u32 = 10;

/// The longest Body Twilio takes.
const MAX_SMS_BODY: usize = 1600;

struct Twilio {
    o: TwilioOptions,
    password: String,
    to: Vec<String>,
    url: String,
    authorization: String,
    budget: f64,
}

/// Texts alerts through Twilio, to every number at once. The alert counts as
/// delivered when any number took it; each number that refused it is
/// reported through the channel context (the client's error handler). It
/// fails only when every number did.
pub fn twilio(options: TwilioOptions) -> Result<Arc<dyn Channel>, Error> {
    // A pasted credential often carries a stray space or newline, which the Authorization header would refuse or send.
    let account_sid = trimmed(&options.account_sid);
    if account_sid.is_empty() {
        return Err(invalid("alerts::twilio needs an account_sid"));
    }
    let key_sid = trimmed(&options.api_key_sid);
    let (user, password) = if key_sid.is_empty() {
        (account_sid.clone(), trimmed(&options.auth_token))
    } else {
        (key_sid, trimmed(&options.api_key_secret))
    };
    if password.is_empty() {
        return Err(invalid("alerts::twilio needs an auth_token, or an api_key_sid and api_key_secret"));
    }
    if options.from.is_empty() && options.messaging_service_sid.is_empty() {
        return Err(invalid("alerts::twilio needs a from number or a messaging_service_sid"));
    }
    let to: Vec<String> =
        options.to.iter().map(|n| js::trim(n)).filter(|n| !n.is_empty()).map(str::to_string).collect();
    if to.is_empty() {
        return Err(invalid("alerts::twilio needs at least one to number"));
    }
    let url =
        format!("https://api.twilio.com/2010-04-01/Accounts/{}/Messages.json", encode_uri_component(&account_sid));
    let authorization = basic_auth(&user, &password);
    let budget = options.segments.map_or(f64::NAN, f64::from);
    Ok(Arc::new(Twilio { o: options, password, to, url, authorization, budget }))
}

impl Channel for Twilio {
    fn name(&self) -> &str {
        "twilio"
    }

    fn send<'a>(&'a self, alert: &'a Alert, cx: &'a ChannelContext) -> BoxFuture<'a, Result<(), BoxError>> {
        Box::pin(async move {
            let o = &self.o;
            if alert.alert_type == AlertType::Recovered && !o.recovered {
                return Ok(());
            }
            let body = sms_body(alert, &link_for(&o.link, alert), self.budget);
            // Every number at once, a task each; dropping this future (the
            // channel's timeout) aborts them all.
            let mut tasks = tokio::task::JoinSet::new();
            let mut ids = std::collections::HashMap::new();
            for (i, number) in self.to.iter().enumerate() {
                let mut pairs = vec![("To", number.clone())];
                if o.messaging_service_sid.is_empty() {
                    pairs.push(("From", o.from.clone()));
                } else {
                    pairs.push(("MessagingServiceSid", o.messaging_service_sid.clone()));
                }
                pairs.push(("Body", body.clone()));
                let form = form(&pairs.iter().map(|(k, v)| (*k, v.as_str())).collect::<Vec<_>>());
                let (transport, url, authorization, password) =
                    (o.transport.clone(), self.url.clone(), self.authorization.clone(), self.password.clone());
                let handle = tasks.spawn(async move {
                    let headers = [
                        ("content-type", "application/x-www-form-urlencoded".to_string()),
                        ("authorization", authorization),
                    ];
                    (i, send(&transport, "Twilio", &url, &headers, form, &[&password]).await.map_err(|e| e.to_string()))
                });
                ids.insert(handle.id(), i);
            }
            let mut errors: Vec<Option<String>> = vec![None; self.to.len()];
            while let Some(joined) = tasks.join_next().await {
                match joined {
                    Ok((i, result)) => errors[i] = result.err(),
                    // A panic (in an app's transport, say) is that number's
                    // failure, as the client makes a channel's.
                    Err(e) => {
                        if let Some(&i) = ids.get(&e.id()) {
                            errors[i] = Some(if e.is_panic() {
                                format!("panicked: {}", panic_text(&*e.into_panic()))
                            } else {
                                "cancelled".to_string()
                            });
                        }
                    }
                }
            }
            let failed: Vec<usize> = (0..self.to.len()).filter(|&i| errors[i].is_some()).collect();
            if failed.is_empty() {
                return Ok(());
            }
            let n = self.to.len();
            if failed.len() == n {
                let message = errors[failed[0]].clone().unwrap_or_default();
                if n > 1 {
                    return Err(super::post::fail(format!("{message} ({} of {n} numbers failed)", failed.len())));
                }
                return Err(super::post::fail(message));
            }
            // Delivered to someone: counted as sent, so a retry never texts the numbers that took it again.
            for i in failed.iter().copied() {
                cx.report_error(format!(
                    "{} (to {}; {} of {n} numbers took the alert)",
                    errors[i].as_deref().unwrap_or(""),
                    mask_number(&self.to[i]),
                    n - failed.len()
                ));
            }
            Ok(())
        })
    }
}

/// A number with all but its last four digits hidden, for an error message.
fn mask_number(number: &str) -> String {
    let n = js::len16(number);
    if n <= 4 {
        return number.to_string();
    }
    format!("{}{}", "*".repeat((n - 4).min(8)), js::tail16(number, 4))
}

// The GSM 03.38 alphabet: a message in it takes 153 characters a segment
// (when split), anything else is UCS-2 at 67. The extension table costs two.
const GSM: &str = "@£$¥èéùìòÇ\nØø\rÅåΔ_ΦΓΛΩΠΨΣΘΞÆæßÉ !\"#¤%&'()*+,-./0123456789:;<=>?¡ABCDEFGHIJKLMNOPQRSTUVWXYZÄÖÑÜ§¿abcdefghijklmnopqrstuvwxyzäöñüà";
const GSM_EXTENDED: &str = "^{}\\[~]|€\u{0c}";

/// How many segments text takes. A character is never split across two: an
/// extension character (two septets) or a surrogate pair (two UCS-2 units)
/// that would straddle a boundary starts the next segment, as phones pack
/// them.
pub(crate) fn sms_segments(text: &str) -> usize {
    let gsm: Option<Vec<usize>> = text
        .chars()
        .map(|c| {
            if GSM.contains(c) {
                Some(1)
            } else if GSM_EXTENDED.contains(c) {
                Some(2)
            } else {
                None
            }
        })
        .collect();
    let (sizes, single, per) = match gsm {
        Some(sizes) => (sizes, 160, 153),
        None => (text.chars().map(char::len_utf16).collect(), 70, 67),
    };
    if sizes.iter().sum::<usize>() <= single {
        return 1;
    }
    let (mut count, mut used) = (1, 0);
    for u in sizes {
        if used + u > per {
            count += 1;
            used = 0;
        }
        used += u;
    }
    count
}

/// Whether text fits within `segments` SMS segments and Twilio's Body limit.
fn fits(text: &str, segments: usize) -> bool {
    js::len16(text) <= MAX_SMS_BODY && sms_segments(text) <= segments
}

/// A segment count clamped to 1 to [`MAX_SEGMENTS`]; 3 for anything not a
/// number.
fn segment_budget(segments: f64) -> usize {
    if !segments.is_finite() {
        return 3;
    }
    segments.floor().clamp(1.0, f64::from(MAX_SEGMENTS)) as usize
}

/// The title, then as many lines of the message (and the triage) as fit,
/// then the link. The link is kept whole; the text before it is cut to make
/// room.
pub(crate) fn sms_body(a: &Alert, link: &str, segments: f64) -> String {
    let budget = segment_budget(segments);
    let tail = if link.is_empty() { String::new() } else { format!("\n{link}") };
    let mut lines = vec![a.title.clone()];
    lines.extend(a.message.split('\n').filter(|l| !js::trim(l).is_empty()).map(str::to_string));
    if !triage(a).is_empty() {
        lines.push(format!("Triage: {}", triage(a)));
    }
    let mut text = String::new();
    let join = |text: &str, line: &str| if text.is_empty() { line.to_string() } else { format!("{text}\n{line}") };
    for line in &lines {
        let next = join(&text, line);
        if fits(&format!("{next}{tail}"), budget) {
            text = next;
            continue;
        }
        // Part of this line, cut on a code point and marked.
        let chars: Vec<char> = line.chars().collect();
        let (mut lo, mut hi) = (0, chars.len());
        while lo < hi {
            let mid = (lo + hi).div_ceil(2);
            let part: String = chars[..mid].iter().collect();
            if fits(&format!("{}{tail}", join(&text, &format!("{part}..."))), budget) {
                lo = mid;
            } else {
                hi = mid - 1;
            }
        }
        if lo > 0 {
            let part: String = chars[..lo].iter().collect();
            text = join(&text, &format!("{part}..."));
        }
        break;
    }
    // Only a link too long for any budget gets here too long; Twilio would refuse it whole.
    cut(&format!("{text}{tail}"), MAX_SMS_BODY)
}
