#[derive(Debug, Clone)]
pub struct Config {
    pub retries: u32,
    pub timeout_ms: u64,
}

impl Default for Config {
    fn default() -> Self {
        Self { retries: 5, timeout_ms: 8_000 }
    }
}
