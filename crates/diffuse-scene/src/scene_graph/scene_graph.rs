//! Scene graph traversal over [`RuntimeWorld`].
//!
//! Ported from `SceneRuntime/SceneGraph/SceneGraph.swift`. Every helper keeps
//! Swift's traversal order: depth-first uses a stack whose children are pushed
//! reversed, breadth-first uses a head index into a growing queue.

use std::collections::BTreeMap;

use diffuse_math::simd::simd_compat::Float4x4;

use crate::entity_id::EntityID;
use crate::runtime_world::{RuntimeWorld, WorldTransform};

impl RuntimeWorld {
    // MARK: Subtree queries

    /// All descendants of `entity` (depth-first, pre-order).
    pub fn descendants(&self, entity: EntityID) -> Vec<EntityID> {
        if !self.contains(entity) {
            return Vec::new();
        }
        let mut result: Vec<EntityID> = Vec::new();
        let mut stack = self.children(entity);
        while let Some(child) = stack.pop() {
            if !self.contains(child) {
                continue;
            }
            result.push(child);
            for descendant in self.children(child).into_iter().rev() {
                stack.push(descendant);
            }
        }
        result
    }

    /// All ancestors from `entity` up to the root (parent, grandparent, ...).
    pub fn ancestors(&self, entity: EntityID) -> Vec<EntityID> {
        if !self.contains(entity) {
            return Vec::new();
        }
        let mut result: Vec<EntityID> = Vec::new();
        let mut current = self.parent(entity);
        while let Some(parent) = current {
            result.push(parent);
            current = self.parent(parent);
        }
        result
    }

    /// Depth of `entity` in the hierarchy (root = 0).
    pub fn depth(&self, entity: EntityID) -> usize {
        self.ancestors(entity).len()
    }

    /// The root ancestor of `entity`.
    pub fn root_ancestor(&self, entity: EntityID) -> Option<EntityID> {
        self.ancestors(entity).last().copied()
    }

    // MARK: Subtree iteration

    /// Depth-first pre-order traversal of the subtree rooted at `entity`,
    /// including `entity` itself.
    pub fn traverse_depth_first(&self, entity: EntityID) -> Vec<EntityID> {
        if !self.contains(entity) {
            return Vec::new();
        }
        let mut result: Vec<EntityID> = Vec::new();
        let mut stack: Vec<EntityID> = vec![entity];
        while let Some(current) = stack.pop() {
            result.push(current);
            for child in self.children(current).into_iter().rev() {
                stack.push(child);
            }
        }
        result
    }

    /// Breadth-first traversal of the subtree rooted at `entity`,
    /// including `entity` itself.
    pub fn traverse_breadth_first(&self, entity: EntityID) -> Vec<EntityID> {
        if !self.contains(entity) {
            return Vec::new();
        }
        let mut result: Vec<EntityID> = Vec::new();
        let mut queue: Vec<EntityID> = vec![entity];
        let mut head = 0;
        while head < queue.len() {
            let current = queue[head];
            head += 1;
            result.push(current);
            queue.extend(self.children(current));
        }
        result
    }

    // MARK: Global traversal

    /// All entities in the world, traversed depth-first from each root.
    pub fn all_entities_depth_first(&self) -> Vec<EntityID> {
        self.roots()
            .into_iter()
            .flat_map(|root| self.traverse_depth_first(root))
            .collect()
    }

    /// All entities in the world, traversed breadth-first from each root.
    pub fn all_entities_breadth_first(&self) -> Vec<EntityID> {
        self.roots()
            .into_iter()
            .flat_map(|root| self.traverse_breadth_first(root))
            .collect()
    }

    // MARK: Leaf queries

    /// Returns true when `entity` has no children.
    pub fn is_leaf(&self, entity: EntityID) -> bool {
        self.children(entity).is_empty()
    }

    /// All leaf entities in the subtree rooted at `entity`.
    pub fn leaves(&self, entity: EntityID) -> Vec<EntityID> {
        self.traverse_depth_first(entity)
            .into_iter()
            .filter(|candidate| self.is_leaf(*candidate))
            .collect()
    }

    // MARK: Subtree transforms

    /// Collects the [`WorldTransform`] for every entity in the subtree rooted
    /// at `entity`, keyed by entity ID.
    ///
    /// Requires transform propagation to have run first so the world matrices
    /// are up to date.
    pub fn world_transforms_in_subtree(
        &self,
        subtree: EntityID,
    ) -> BTreeMap<EntityID, WorldTransform> {
        let ids = self.traverse_depth_first(subtree);
        let mut result: BTreeMap<EntityID, WorldTransform> = BTreeMap::new();
        for id in ids {
            if let Some(world_transform) = self.world_transform(id) {
                result.insert(id, world_transform);
            }
        }
        result
    }

    /// Computes the local transform that, when applied to `entity`'s children,
    /// yields `world`.
    ///
    /// Swift's guard falls back to `world` itself (so the declared optional is
    /// never `nil`); the same always-`Some` behaviour is preserved here.
    pub fn local_transform_for_world(&self, world: Float4x4, entity: EntityID) -> Option<Float4x4> {
        if let Some(parent) = self.parent(entity) {
            if let Some(parent_world) = self.world_transform(parent) {
                return Some(parent_world.matrix.inverse() * world);
            }
        }
        Some(world)
    }
}
