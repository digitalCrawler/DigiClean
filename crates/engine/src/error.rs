use std::io;
use std::path::PathBuf;

#[derive(Debug, thiserror::Error)]
pub enum EngineError {
    #[error("operation cancelled")]
    Cancelled,

    #[error("invalid configuration: {0}")]
    InvalidConfig(String),

    #[error("{}: {source}", path.display())]
    Io {
        path: PathBuf,
        #[source]
        source: io::Error,
    },

    #[error("cache error: {0}")]
    Cache(String),

    #[error("recovery bin error: {0}")]
    Recovery(String),

    #[error("{0}")]
    Other(String),
}

impl EngineError {
    pub fn io(path: impl Into<PathBuf>, source: io::Error) -> Self {
        EngineError::Io {
            path: path.into(),
            source,
        }
    }
}

pub type Result<T, E = EngineError> = std::result::Result<T, E>;
