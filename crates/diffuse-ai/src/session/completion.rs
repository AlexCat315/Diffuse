//! Ported from `Engine/Sources/AIRuntime/Session/Completion.swift`.
//!
//! A single text answer without tools, scene context or conversation history:
//! for rewriting prose, drafting commit messages and similar self-contained
//! requests. Nothing is recorded in the session.

use diffuse_capability::contracts::exports::SessionApiFormat;
use serde_json::{Value, json};

use crate::session::session::{Session, SessionError};

impl Session {
    pub fn complete(
        &self,
        instructions: &str,
        prompt: &str,
        max_tokens: Option<i64>,
    ) -> Result<String, SessionError> {
        let limit = max_tokens.unwrap_or(self.config().max_tokens);
        let body = match self.config().api_format {
            SessionApiFormat::Anthropic => json!({
                "model": self.config().model,
                "max_tokens": limit,
                "system": instructions,
                "messages": [{ "role": "user", "content": prompt }],
            }),
            SessionApiFormat::OpenAiCompatible => json!({
                "model": self.config().model,
                "max_tokens": limit,
                "messages": [
                    { "role": "system", "content": instructions },
                    { "role": "user", "content": prompt },
                ],
            }),
            SessionApiFormat::OpenAiResponses => json!({
                "model": self.config().model,
                "max_output_tokens": limit,
                "instructions": instructions,
                "input": prompt,
            }),
        };
        let data = self.post(&body)?;
        let text = Self::completion_text(&data, self.config().api_format)?;
        if text.trim().is_empty() {
            return Err(SessionError::malformed("the model returned no text"));
        }
        Ok(text)
    }

    pub fn complete_with_defaults(
        &self,
        instructions: &str,
        prompt: &str,
    ) -> Result<String, SessionError> {
        self.complete(instructions, prompt, None)
    }

    pub fn completion_text(data: &[u8], format: SessionApiFormat) -> Result<String, SessionError> {
        let json: Value = serde_json::from_slice(data)
            .map_err(|_| SessionError::malformed("top-level JSON is not an object"))?;
        if !json.is_object() {
            return Err(SessionError::malformed("top-level JSON is not an object"));
        }
        match format {
            SessionApiFormat::Anthropic => {
                let content = json
                    .get("content")
                    .and_then(Value::as_array)
                    .map(Vec::as_slice)
                    .unwrap_or(&[]);
                Ok(content
                    .iter()
                    .filter(|block| block.get("type").and_then(Value::as_str) == Some("text"))
                    .filter_map(|block| block.get("text").and_then(Value::as_str))
                    .collect())
            }
            SessionApiFormat::OpenAiCompatible => Ok(json
                .get("choices")
                .and_then(Value::as_array)
                .and_then(|choices| choices.first())
                .and_then(|choice| choice.get("message"))
                .and_then(|message| message.get("content"))
                .and_then(Value::as_str)
                .unwrap_or("")
                .to_string()),
            SessionApiFormat::OpenAiResponses => {
                let output = json
                    .get("output")
                    .and_then(Value::as_array)
                    .map(Vec::as_slice)
                    .unwrap_or(&[]);
                let content = output
                    .iter()
                    .filter(|item| item.get("type").and_then(Value::as_str) == Some("message"))
                    .flat_map(|item| {
                        item.get("content")
                            .and_then(Value::as_array)
                            .map(Vec::as_slice)
                            .unwrap_or(&[])
                    });
                Ok(content
                    .filter(|block| {
                        block.get("type").and_then(Value::as_str) == Some("output_text")
                    })
                    .filter_map(|block| block.get("text").and_then(Value::as_str))
                    .collect())
            }
        }
    }
}
