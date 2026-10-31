//! The slice of `argparse` the ported validators relied on: long options that
//! take one value, spelled `--name VALUE` or `--name=VALUE`.

use crate::support::terminal::ToolError;

pub struct Flags;

impl Flags {
    pub fn matches(token: &str, name: &str) -> bool {
        token == name || token.starts_with(&format!("{name}="))
    }

    /// Returns the value for `token`, consuming the following token when the
    /// value was not written inline. `index` points at `token` on entry and at
    /// the consumed value on exit.
    pub fn value(
        token: &str,
        name: &str,
        arguments: &[String],
        index: &mut usize,
    ) -> Result<String, ToolError> {
        if token == name {
            *index += 1;
            let value = arguments.get(*index).ok_or_else(|| {
                ToolError::message(format!("argument {name}: expected one argument"))
            })?;
            return Ok(value.clone());
        }
        // `--name=value`: skip the name and the separator.
        Ok(token
            .char_indices()
            .nth(name.chars().count() + 1)
            .map(|(offset, _)| token[offset..].to_string())
            .unwrap_or_default())
    }
}

#[cfg(test)]
mod tests {
    use super::Flags;

    #[test]
    fn matches_accepts_both_spellings() {
        assert!(Flags::matches("--vendor", "--vendor"));
        assert!(Flags::matches("--vendor=/tmp", "--vendor"));
        assert!(!Flags::matches("--vendorx", "--vendor"));
    }

    #[test]
    fn value_consumes_the_following_token() {
        let arguments = ["--vendor".to_string(), "/tmp/x".to_string()];
        let mut index = 0;
        let value = Flags::value(&arguments[0], "--vendor", &arguments, &mut index).unwrap();
        assert_eq!(value, "/tmp/x");
        assert_eq!(index, 1);
    }

    #[test]
    fn inline_value_does_not_advance() {
        let arguments = ["--vendor=/tmp/y".to_string()];
        let mut index = 0;
        let value = Flags::value(&arguments[0], "--vendor", &arguments, &mut index).unwrap();
        assert_eq!(value, "/tmp/y");
        assert_eq!(index, 0);
    }

    #[test]
    fn missing_value_is_an_error() {
        let arguments = ["--vendor".to_string()];
        let mut index = 0;
        assert!(Flags::value(&arguments[0], "--vendor", &arguments, &mut index).is_err());
    }
}
