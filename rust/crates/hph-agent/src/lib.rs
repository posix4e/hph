//! Client library for hph.
//!
//! A worker's whole obligation is to produce signatures. Everything here builds
//! and signs work actions; nothing needs gas, a funded account, or the ability to
//! send a transaction.

pub mod eip712;
