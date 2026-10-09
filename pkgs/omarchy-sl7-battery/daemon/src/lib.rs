//! sl7-batteryd: battery history, rate model and auto power saver for the Surface
//! Laptop 7. See the package README for the protocol.

pub mod app;
pub mod auto;
pub mod config;
pub mod monitor;
pub mod rates;
pub mod ring;
pub mod sig;
pub mod sleeps;
pub mod sys;
pub mod upower;
pub mod util;
