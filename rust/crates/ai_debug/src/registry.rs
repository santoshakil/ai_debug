//! Tool registry: declarative metadata for every registered command.

use parking_lot::RwLock;
use std::collections::BTreeMap;

#[derive(Clone, Debug)]
pub struct ToolSpec {
    pub name: String,
    pub description: String,
    pub input_schema_json: String,
    pub output_schema_json: Option<String>,
    pub streaming: bool,
}

pub struct ToolRegistry {
    inner: RwLock<BTreeMap<String, ToolSpec>>,
}

impl ToolRegistry {
    pub fn new() -> Self {
        Self { inner: RwLock::new(BTreeMap::new()) }
    }

    pub fn insert(&self, spec: ToolSpec) -> bool {
        let mut m = self.inner.write();
        m.insert(spec.name.clone(), spec).is_none()
    }

    pub fn remove(&self, name: &str) -> bool {
        self.inner.write().remove(name).is_some()
    }

    pub fn get(&self, name: &str) -> Option<ToolSpec> {
        self.inner.read().get(name).cloned()
    }

    pub fn list(&self) -> Vec<ToolSpec> {
        self.inner.read().values().cloned().collect()
    }
}

impl Default for ToolRegistry {
    fn default() -> Self { Self::new() }
}
