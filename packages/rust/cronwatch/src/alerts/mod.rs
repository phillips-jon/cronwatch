//! The SDK's alert channels, request for request: Slack, Discord and a
//! signed webhook; the email providers Resend, Postmark, SendGrid, Mailgun
//! and SES (signed with SigV4, no AWS SDK); Twilio for SMS; and the trackers
//! Sentry, Honeybadger, Datadog, Rollbar, Bugsnag and New Relic. Each is made
//! from an options struct and returns a [`Channel`](crate::Channel) for
//! [`ClientBuilder::alert`](crate::ClientBuilder::alert):
//!
//! ```no_run
//! # fn main() -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
//! # let _rt = tokio::runtime::Builder::new_current_thread().build()?;
//! # let _guard = _rt.enter();
//! use cronwatch::alerts::{self, SlackOptions};
//!
//! let slack = alerts::slack(SlackOptions {
//!     webhook_url: std::env::var("SLACK_WEBHOOK_URL")?,
//!     ..Default::default()
//! })?;
//! let cw = cronwatch::Client::builder().alert(slack).build()?;
//! # Ok(())
//! # }
//! ```
//!
//! Every request is the SDK's (the same URL, headers and body bytes, so a
//! provider sees the same alert whichever port sent it) and made the way the
//! SDK makes it: one ten second deadline for the whole request, a redirect
//! refused rather than followed (its 3xx is a failure, so credentials never go
//! where it points), at most 1 MiB of an answer read, TLS verified, and an
//! error that names the provider and the URL's origin only, with every secret
//! the channel holds cut out of any answer it quotes. Ids are deterministic
//! (the first 32 hex characters of SHA-256 over job, type and time), so
//! Resend's idempotency key, Sentry's event id and Rollbar's UUID let a
//! provider drop an alert it already took.
//!
//! Each options struct has a `transport`: `None` for the default
//! [`ReqwestTransport`], or a [`Transport`] of the app's own (a proxy, a
//! test's recorder).
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
    twilio::{MAX_SEGMENTS, TwilioOptions, twilio},
    webhook::{WebhookOptions, signature, webhook},
};

/// For the conformance replay.
#[cfg(all(test, feature = "alerts"))]
pub(crate) mod testing {
    pub(crate) use super::email::compose_email;
    pub(crate) use super::twilio::{sms_body, sms_segments};
}
