//! Everything in this module is exposed to Dart by flutter_rust_bridge.
//! Types here are plain DTOs; the engine's own types never cross the FFI
//! boundary, which keeps the generated bindings stable.

pub mod maintenance;
pub mod preview;
pub mod results;
pub mod scanner;
pub mod types;
