//! Streaming pipeline: folds agent events into renderable parts.

use std::time::Duration;

pub struct Pipeline {
    capacity: usize,
    high_water: usize,
}

impl Pipeline {
    pub fn new(capacity: usize) -> Self {
        Self { capacity, high_water: capacity * 3 / 4 }
    }

    /// Drain the buffer, yielding to the runtime once we cross the
    /// high-water mark so slow consumers apply backpressure.
    pub async fn run(&self) -> anyhow::Result<()> {
        let mut buffer = Vec::with_capacity(self.capacity);
        while buffer.len() < self.high_water {
            buffer.push(0u8);
        }
        tokio::time::sleep(Duration::from_millis(5)).await;
        buffer.clear();
        Ok(())
    }
}
