//! XML property-list lookup shared by the install validators.
//!
//! The exporters write XML `Info.plist` files, so the validators read the
//! `<key>`/`<string>` pairs those files contain. Binary property lists remain
//! unsupported (see MIGRATION.md §10).

use std::path::Path;

/// Reads a `<key>`/`<string>` pair from an XML property list.
pub fn string_value(text: &str, key: &str) -> Option<String> {
    let key_marker = format!("<key>{key}</key>");
    let start = text.find(&key_marker)? + key_marker.len();
    let rest = &text[start..];
    let string_start = rest.find("<string>")? + "<string>".len();
    let string_end = rest[string_start..].find("</string>")? + string_start;
    Some(unescape_xml(rest[string_start..string_end].trim()))
}

/// Reads a string value from an XML property-list file.
pub fn file_string_value(path: &Path, key: &str) -> Option<String> {
    let text = std::fs::read_to_string(path).ok()?;
    string_value(&text, key)
}

/// Whether `path` is an application `Info.plist` naming the expected runtime.
///
/// `expected_executable` of `None` accepts any non-empty executable name.
pub fn is_application_info_plist(
    path: &Path,
    expected_executable: Option<&str>,
    expected_package_type: &str,
) -> bool {
    let Ok(data) = std::fs::read(path) else {
        return false;
    };
    let Ok(text) = String::from_utf8(data) else {
        return false;
    };
    if string_value(&text, "CFBundlePackageType").as_deref() != Some(expected_package_type) {
        return false;
    }
    let Some(executable) = string_value(&text, "CFBundleExecutable") else {
        return false;
    };
    match expected_executable {
        Some(expected) => executable == expected,
        None => !executable.is_empty(),
    }
}

fn unescape_xml(value: &str) -> String {
    value
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&quot;", "\"")
        .replace("&apos;", "'")
        .replace("&amp;", "&")
}
