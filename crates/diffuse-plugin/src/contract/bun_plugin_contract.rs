//! Static metadata emitted by the TypeScript SDK. Inspecting a package never
//! executes its code.
//!
//! Ported from `Engine/Sources/PluginRuntime/Contract/BunPluginContract.swift`.

use std::collections::{BTreeMap, BTreeSet};

use diffuse_capability::capsule_schema::{self, JsonSchema};
use serde::Deserialize;

use crate::PluginError;
use crate::contract::plugin_contract::{
    PluginContract, PluginContractError, PluginEntryContract, PluginInputField, PluginInputType,
};
use crate::contract::plugin_json::PluginJSON;
use crate::contract::plugin_manifest::{PluginImportPermission, PluginManifestValidationError};
use crate::pattern::{lower_alphanumeric_dash, lower_dash};

#[derive(Deserialize)]
struct Document {
    version: i64,
    entries: Vec<Entry>,
}

#[derive(Deserialize)]
struct Entry {
    name: String,
    title: Option<String>,
    description: Option<String>,
    input: PluginJSON,
}

pub enum BunPluginContract {}

impl BunPluginContract {
    pub fn decode(
        data: &[u8],
        imports: &[PluginImportPermission],
    ) -> Result<PluginContract, PluginError> {
        if data.len() > 1_024 * 1_024 {
            return Err(PluginContractError::SourceTooLarge.into());
        }
        let document: Document = serde_json::from_slice(data)?;
        let names: BTreeSet<&String> = document.entries.iter().map(|entry| &entry.name).collect();
        if !(document.version == 1
            && document.entries.len() <= 64
            && names.len() == document.entries.len())
        {
            return Err(PluginManifestValidationError::InvalidContribution(
                "capabilities.json".to_string(),
            )
            .into());
        }
        let mut entries = Vec::with_capacity(document.entries.len());
        for entry in &document.entries {
            if !lower_dash(&entry.name, 1, 64) {
                return Err(PluginContractError::InvalidCapabilityName(entry.name.clone()).into());
            }
            let (kind, schema) = Self::input(&entry.input, 0)?;
            // `guard case .record = type else { … }`
            if !matches!(kind, PluginInputType::Record(_)) {
                return Err(PluginContractError::UnsupportedType(
                    "entry input must be an object".to_string(),
                )
                .into());
            }
            entries.push(PluginEntryContract::new(
                entry.name.clone(),
                entry.title.clone().unwrap_or_else(|| entry.name.clone()),
                entry.description.clone().unwrap_or_default(),
                schema,
                kind,
            ));
        }
        Ok(PluginContract::new(
            imports
                .iter()
                .map(|permission| permission.raw_value().to_string())
                .collect(),
            entries,
        ))
    }

    fn input(
        value: &PluginJSON,
        depth: usize,
    ) -> Result<(PluginInputType, JsonSchema), PluginError> {
        if depth >= 16 {
            return Err(PluginContractError::TypeTooDeep.into());
        }
        match value {
            PluginJSON::String(text) if text == "string" => Ok((
                PluginInputType::String,
                capsule_schema::string(None, None, Some(65_536)),
            )),
            PluginJSON::String(text) if text == "bool" => {
                Ok((PluginInputType::Bool, capsule_schema::boolean()))
            }
            PluginJSON::String(text) if text == "number" => Ok((
                PluginInputType::F64,
                capsule_schema::number(None, None, None),
            )),
            PluginJSON::String(text) if text == "integer" => Ok((
                PluginInputType::S32,
                capsule_schema::integer(None, Some(i64::from(i32::MIN)), Some(i64::from(i32::MAX))),
            )),
            PluginJSON::Object(fields) if fields.len() == 1 => {
                if let Some(child) = fields.get("optional") {
                    let (kind, schema) = Self::input(child, depth + 1)?;
                    return Ok((
                        PluginInputType::Option(Box::new(kind)),
                        JsonSchema::choice(vec![schema, JsonSchema::null()]),
                    ));
                }
                if let Some(PluginJSON::Array(values)) = fields.get("enum")
                    && !values.is_empty()
                    && values.len() <= 256
                {
                    let names: Vec<String> = values
                        .iter()
                        .filter_map(|value| value.string_value().map(str::to_string))
                        .collect();
                    let unique: BTreeSet<&String> = names.iter().collect();
                    if !(names.len() == values.len() && unique.len() == names.len()) {
                        return Err(PluginContractError::UnsupportedType("enum".to_string()).into());
                    }
                    let schema = capsule_schema::string_enum(
                        None,
                        &names.iter().map(String::as_str).collect::<Vec<_>>(),
                    );
                    return Ok((PluginInputType::Enumeration(names), schema));
                }
                if let Some(PluginJSON::Array(values)) = fields.get("oneOf")
                    && !values.is_empty()
                    && values.len() <= 16
                {
                    let mut kinds = Vec::with_capacity(values.len());
                    let mut schemas = Vec::with_capacity(values.len());
                    for value in values {
                        let (kind, schema) = Self::input(value, depth + 1)?;
                        kinds.push(kind);
                        schemas.push(schema);
                    }
                    return Ok((PluginInputType::OneOf(kinds), JsonSchema::choice(schemas)));
                }
                if let Some(child) = fields.get("list") {
                    let (kind, schema) = Self::input(child, depth + 1)?;
                    return Ok((
                        PluginInputType::List(Box::new(kind)),
                        capsule_schema::array(schema, None, None, Some(4096)),
                    ));
                }
                if let Some(PluginJSON::Object(properties)) = fields.get("record")
                    && properties.len() <= 128
                {
                    let mut kinds: Vec<PluginInputField> = Vec::new();
                    let mut schemas: BTreeMap<String, JsonSchema> = BTreeMap::new();
                    let mut required: Vec<String> = Vec::new();
                    // `properties.keys.sorted()`
                    for (name, property) in properties {
                        if !lower_alphanumeric_dash(name, 1, 64) {
                            return Err(PluginContractError::InvalidFieldName(name.clone()).into());
                        }
                        let (kind, schema) = Self::input(property, depth + 1)?;
                        kinds.push(PluginInputField::new(name.clone(), kind.clone()));
                        schemas.insert(name.clone(), schema);
                        if !matches!(kind, PluginInputType::Option(_)) {
                            required.push(name.clone());
                        }
                    }
                    return Ok((
                        PluginInputType::Record(kinds),
                        capsule_schema::object(schemas, required, None, false),
                    ));
                }
                Err(
                    PluginContractError::UnsupportedType("capabilities.json input".to_string())
                        .into(),
                )
            }
            _ => Err(
                PluginContractError::UnsupportedType("capabilities.json input".to_string()).into(),
            ),
        }
    }
}
