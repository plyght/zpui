pub fn backoff(attempt: u32) -> u64 {
    100 * 2u64.pow(attempt.min(6))
}
