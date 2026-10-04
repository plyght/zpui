use aurora::stream::Pipeline;

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let pipeline = Pipeline::new(64);
    pipeline.run().await?;
    Ok(())
}
