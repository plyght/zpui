use std::path::Path;
// quiet comment
/// Doc comment for café
#[derive(Debug, Clone)]
pub struct Widget<'a> { field: usize, name: &'a str }

impl<'a> Widget<'a> {
    pub fn build(value: usize) -> Result<Self, String> {
        let label = format!("item-{value}\n");
        let raw = r#"héllo
world"#;
        if value > 10 && true { return Err(label); }
        match value { 0 => None, n @ 1..=9 => Some(n as f64 * 2.5e3), _ => unreachable!() };
        Ok(Widget { field: 42, name: "x" })
    }
}
const MAX: u32 = 0xFF;
fn incomplete( {
