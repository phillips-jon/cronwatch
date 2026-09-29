//! The crate's error.

use std::fmt;
use std::sync::Arc;

use crate::store::BoxError;

/// What went wrong outside a job: an option or schedule the SDK would refuse
/// (with the SDK's message, word for word), a store that failed, or a job
/// whose stored definition cannot be evaluated. Cheap to clone, so a check
/// shared by several callers hands each the same error.
#[derive(Clone, Debug)]
pub enum Error {
    /// An option, a name, a schedule or a run id the SDK refuses.
    Invalid(String),
    /// The store failed.
    Store(Arc<dyn std::error::Error + Send + Sync + 'static>),
    /// Something else, with its message: a stored definition that cannot be
    /// evaluated, a check that panicked, a state that kept changing.
    Other(String),
}

impl Error {
    pub(crate) fn store(err: BoxError) -> Error {
        Error::Store(Arc::from(err))
    }
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Error::Invalid(m) | Error::Other(m) => f.write_str(m),
            Error::Store(e) => fmt::Display::fmt(e, f),
        }
    }
}

impl std::error::Error for Error {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Error::Store(e) => Some(&**e),
            _ => None,
        }
    }
}

impl From<BoxError> for Error {
    fn from(err: BoxError) -> Self {
        Error::store(err)
    }
}
