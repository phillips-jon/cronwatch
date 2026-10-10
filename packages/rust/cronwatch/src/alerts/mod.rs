//! The SDK's alert channels, request for request: Slack, Discord, and a
//! signed webhook; the email providers Resend, Postmark, SendGrid, Mailgun,
//! and SES (signed with SigV4, no AWS SDK); Twilio for SMS; and the trackers
//! Sentry, Honeybadger, Datadog, Rollbar, Bugsnag, and New Relic. Each is made
//! from an options struct and returns a [`Channel`](crate::Channel) for
//! [`ClientBuilder::alert`](crate::ClientBuilder::alert):
//!
//! ```no_run
//! # fn main() -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
//! # let _rt = tokio::runtime::Builder::new_current_thread().build()?;
//! # let _guard = _rt.enter();
//! use cronwatch::alerts::{self, SlackOptions};
//!
//! let slack = alerts::slack(SlackOptions::new().webhook_url(std::env::var("SLACK_WEBHOOK_URL")?))?;
//! let cw = cronwatch::Client::builder().alert(slack).build()?;
//! # Ok(())
//! # }
//! ```
//!
//! Every request is the SDK's (the same URL, headers, and body bytes, so a
//! provider sees the same alert whichever port sent it) and made the way the
//! SDK makes it: one ten second deadline for the whole request, a redirect
//! refused rather than followed (its 3xx is a failure, so credentials never go
//! where it points), at most 1 MiB of an answer read, TLS verified, and an
//! error that names the provider and the URL's origin only, with every secret
//! the channel holds cut out of any answer it quotes. Ids are deterministic
//! (the first 32 hex characters of SHA-256 over job, type, and time), so
//! Resend's idempotency key, Sentry's event id, and Rollbar's UUID let a
//! provider drop an alert it already took.
//!
//! Each options struct is `#[non_exhaustive]`, so a release can add an
//! option without breaking an app's build: start from `new()` and set what
//! you need with its builder methods, one per field, named after it. Each
//! has a `transport`: `None` for the default [`ReqwestTransport`], or a
//! [`Transport`] of the app's own (a proxy, a test's recorder).
//!
//! With only the `triage` feature, this module holds the transport alone.

pub mod post;

pub use post::{Request, ReqwestTransport, Response, ResponseBody, TimedOut, Transport};

#[cfg(feature = "alerts")]
mod bugsnag;
#[cfg(feature = "alerts")]
mod datadog;
#[cfg(feature = "alerts")]
mod discord;
#[cfg(feature = "alerts")]
mod email;
#[cfg(feature = "alerts")]
mod honeybadger;
#[cfg(feature = "alerts")]
mod mailgun;
#[cfg(feature = "alerts")]
mod newrelic;
#[cfg(feature = "alerts")]
mod postmark;
#[cfg(feature = "alerts")]
mod resend;
#[cfg(feature = "alerts")]
mod rollbar;
#[cfg(feature = "alerts")]
mod sendgrid;
#[cfg(feature = "alerts")]
mod sentry;
#[cfg(feature = "alerts")]
mod ses;
#[cfg(feature = "alerts")]
mod shared;
#[cfg(feature = "alerts")]
mod sigv4;
#[cfg(feature = "alerts")]
mod slack;
#[cfg(feature = "alerts")]
mod twilio;
#[cfg(feature = "alerts")]
mod webhook;

#[cfg(all(test, feature = "alerts"))]
mod hardening_tests;

#[cfg(feature = "alerts")]
pub use {
    bugsnag::{BugsnagOptions, bugsnag},
    datadog::{DatadogOptions, datadog},
    discord::{DiscordOptions, discord},
    email::EmailOptions,
    honeybadger::{HoneybadgerOptions, honeybadger},
    mailgun::{MailgunOptions, mailgun},
    newrelic::{NewRelicOptions, newrelic},
    postmark::{PostmarkOptions, postmark},
    resend::{ResendOptions, resend},
    rollbar::{RollbarOptions, rollbar},
    sendgrid::{SendgridOptions, sendgrid},
    sentry::{SentryOptions, sentry},
    ses::{SesOptions, ses},
    shared::LinkFn,
    slack::{SlackOptions, slack},
    twilio::{TwilioOptions, twilio},
    webhook::{WebhookOptions, signature, webhook},
};

/// The most SMS segments a Twilio message may use.
#[cfg(feature = "alerts")]
#[doc(hidden)]
#[deprecated(note = "internal, outside the 1.x promise; no longer public from 0.11")]
pub const MAX_SEGMENTS: u32 = twilio::SEGMENTS_MAX;

/// Builder methods for an options struct, one per field, named after it, and
/// `new()`, the defaults. The structs are `#[non_exhaustive]`, so a release
/// can add an option without breaking an app's build: an app starts from
/// `new()` (or `Default::default()`) and sets what it needs.
macro_rules! setters {
    ($ty:ident { $($kind:ident $field:ident $(: $t:ty)?),* $(,)? }) => {
        impl $ty {
            /// The options with every field at its default.
            pub fn new() -> Self {
                Self::default()
            }
            $($crate::alerts::setters!(@one $kind $field $(: $t)?);)*
        }
    };
    (@one text $field:ident) => {
        #[doc = concat!("Sets `", stringify!($field), "`.")]
        pub fn $field(mut self, value: impl Into<String>) -> Self {
            self.$field = value.into();
            self
        }
    };
    (@one texts $field:ident) => {
        #[doc = concat!("Sets `", stringify!($field), "`.")]
        pub fn $field<I, S>(mut self, values: I) -> Self
        where
            I: IntoIterator<Item = S>,
            S: Into<String>,
        {
            self.$field = values.into_iter().map(Into::into).collect();
            self
        }
    };
    (@one pairs $field:ident) => {
        #[doc = concat!("Sets `", stringify!($field), "`, in order.")]
        pub fn $field<I, K, V>(mut self, values: I) -> Self
        where
            I: IntoIterator<Item = (K, V)>,
            K: Into<String>,
            V: Into<String>,
        {
            self.$field = values.into_iter().map(|(k, v)| (k.into(), v.into())).collect();
            self
        }
    };
    (@one flag $field:ident) => {
        #[doc = concat!("Sets `", stringify!($field), "`.")]
        pub fn $field(mut self, value: bool) -> Self {
            self.$field = value;
            self
        }
    };
    (@one some $field:ident : $t:ty) => {
        #[doc = concat!("Sets `", stringify!($field), "`.")]
        pub fn $field(mut self, value: $t) -> Self {
            self.$field = Some(value);
            self
        }
    };
    (@one value $field:ident : $t:ty) => {
        #[doc = concat!("Sets `", stringify!($field), "`.")]
        pub fn $field(mut self, value: $t) -> Self {
            self.$field = value;
            self
        }
    };
    (@one link $field:ident) => {
        #[doc = concat!("Sets `", stringify!($field), "`: the link an alert carries.")]
        pub fn $field(mut self, f: impl Fn(&$crate::Alert) -> String + Send + Sync + 'static) -> Self {
            self.$field = Some(std::sync::Arc::new(f));
            self
        }
    };
    (@one clock $field:ident) => {
        #[doc = concat!("Sets `", stringify!($field), "`, a clock in epoch milliseconds, for tests.")]
        pub fn $field(mut self, f: impl Fn() -> i64 + Send + Sync + 'static) -> Self {
            self.$field = Some(std::sync::Arc::new(f));
            self
        }
    };
}
pub(crate) use setters;

/// `Debug` for options that hold credentials: the type's name only, so an
/// app's own configuration can derive `Debug` without printing them.
macro_rules! opaque_debug {
    ($($name:ty),* $(,)?) => {
        $(impl std::fmt::Debug for $name {
            fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
                f.debug_struct(stringify!($name)).finish_non_exhaustive()
            }
        })*
    };
}
#[cfg(feature = "triage")]
pub(crate) use opaque_debug;

#[cfg(feature = "alerts")]
opaque_debug!(
    BugsnagOptions,
    DatadogOptions,
    DiscordOptions,
    EmailOptions,
    HoneybadgerOptions,
    MailgunOptions,
    NewRelicOptions,
    PostmarkOptions,
    ResendOptions,
    RollbarOptions,
    SendgridOptions,
    SentryOptions,
    SesOptions,
    SlackOptions,
    TwilioOptions,
    WebhookOptions,
);

/// For the conformance replay.
#[cfg(all(test, feature = "alerts"))]
pub(crate) mod testing {
    pub(crate) use super::discord::embed_description;
    pub(crate) use super::email::compose_email;
    pub(crate) use super::twilio::{sms_body, sms_segments};
}
