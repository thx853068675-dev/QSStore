//! HDC Protocol Library
//!
//! Pure-Rust implementation of the HarmonyOS Device Connector (HDC) protocol.
//! Provides serialization, deserialization, and protocol constants.

pub mod config;
pub mod encrypt;
pub mod serializer;

pub use config::*;
pub use serializer::*;
