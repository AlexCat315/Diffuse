//! Insertion-ordered string map. The guard's reports and the baseline walk must
//! keep the order declarations were first seen, exactly like the Python
//! dictionaries they replace, while a later duplicate key overwrites the value
//! in place instead of moving it.

use std::collections::HashMap;

#[derive(Clone, Debug, Default)]
pub struct OrderedMap<Value> {
    keys: Vec<String>,
    storage: HashMap<String, Value>,
}

impl<Value> OrderedMap<Value> {
    pub fn new() -> Self {
        Self {
            keys: Vec::new(),
            storage: HashMap::new(),
        }
    }

    pub fn keys(&self) -> &[String] {
        &self.keys
    }

    pub fn get(&self, key: &str) -> Option<&Value> {
        self.storage.get(key)
    }

    pub fn insert(&mut self, value: Value, key: &str) {
        if !self.storage.contains_key(key) {
            self.keys.push(key.to_string());
        }
        self.storage.insert(key.to_string(), value);
    }

    pub fn len(&self) -> usize {
        self.keys.len()
    }

    pub fn is_empty(&self) -> bool {
        self.keys.is_empty()
    }
}

impl<Value: Clone> OrderedMap<Value> {
    /// Visits every entry in first-seen order.
    pub fn entries(&self) -> Vec<(&str, &Value)> {
        self.keys
            .iter()
            .filter_map(|key| self.storage.get(key).map(|value| (key.as_str(), value)))
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::OrderedMap;

    #[test]
    fn keys_keep_first_seen_order() {
        let mut map = OrderedMap::new();
        map.insert(1, "b");
        map.insert(2, "a");
        map.insert(3, "c");
        assert_eq!(map.keys(), ["b", "a", "c"]);
    }

    #[test]
    fn a_duplicate_key_overwrites_without_moving() {
        let mut map = OrderedMap::new();
        map.insert(1, "b");
        map.insert(2, "a");
        map.insert(9, "b");
        assert_eq!(map.keys(), ["b", "a"]);
        assert_eq!(map.get("b"), Some(&9));
        assert_eq!(map.len(), 2);
    }

    #[test]
    fn entries_follow_the_key_order() {
        let mut map = OrderedMap::new();
        map.insert(1, "z");
        map.insert(2, "a");
        assert_eq!(map.entries(), [("z", &1), ("a", &2)]);
    }
}
