//! `JobSystem` — chunked parallel execution on worker threads.
//!
//! Swift used a concurrent `DispatchQueue` plus a `DispatchGroup`; MIGRATION.md
//! §5.5 maps that to `std::thread` and `std::sync` with no async runtime.

use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::thread;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct JobDispatchReport {
    pub job_count: usize,
    pub worker_count: usize,
    pub executed_in_parallel: bool,
}

impl JobDispatchReport {
    #[inline]
    pub const fn new(job_count: usize, worker_count: usize, executed_in_parallel: bool) -> Self {
        JobDispatchReport {
            job_count,
            worker_count,
            executed_in_parallel,
        }
    }

    pub fn merged(reports: &[JobDispatchReport], worker_count: usize) -> JobDispatchReport {
        JobDispatchReport {
            job_count: reports.iter().map(|report| report.job_count).sum(),
            worker_count,
            executed_in_parallel: reports.iter().any(|report| report.executed_in_parallel),
        }
    }
}

impl Default for JobDispatchReport {
    fn default() -> Self {
        JobDispatchReport::new(0, 1, false)
    }
}

/// The Swift `JobSystem.shared` singleton has no direct Rust equivalent; the
/// engine host owns one instance and passes it through `Arc`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct JobSystem {
    pub worker_count: usize,
    pub minimum_chunk_size: usize,
}

impl JobSystem {
    /// Swift defaults: `workerCount` = active processor count, `minimumChunkSize` = 64.
    pub fn new(worker_count: usize, minimum_chunk_size: usize) -> Self {
        JobSystem {
            worker_count: worker_count.max(1),
            minimum_chunk_size: minimum_chunk_size.max(1),
        }
    }

    pub fn with_available_parallelism() -> Self {
        Self::new(
            thread::available_parallelism()
                .map(|value| value.get())
                .unwrap_or(1),
            64,
        )
    }

    /// `parallelFor` — runs `body` over chunked ranges of `0..count`.
    pub fn parallel_for<F>(
        &self,
        count: usize,
        minimum_chunk_size: Option<usize>,
        body: F,
    ) -> JobDispatchReport
    where
        F: Fn(std::ops::Range<usize>) + Sync,
    {
        let chunks = self.chunk_ranges(count, minimum_chunk_size);
        if chunks.is_empty() {
            return JobDispatchReport::new(0, self.worker_count, false);
        }
        if chunks.len() == 1 {
            body(chunks[0].clone());
            return JobDispatchReport::new(1, self.worker_count, false);
        }
        self.run_chunks(&chunks, |range| {
            body(range.clone());
        });
        JobDispatchReport::new(chunks.len(), self.worker_count, true)
    }

    /// `parallelCompactMap` — preserves source order across chunks.
    pub fn parallel_compact_map<Input, Output, F>(
        &self,
        items: &[Input],
        minimum_chunk_size: Option<usize>,
        transform: F,
    ) -> (Vec<Output>, JobDispatchReport)
    where
        Input: Sync,
        Output: Send + Sync,
        F: Fn(&Input) -> Option<Output> + Sync,
    {
        let chunks = self.chunk_ranges(items.len(), minimum_chunk_size);
        if chunks.is_empty() {
            return (
                Vec::new(),
                JobDispatchReport::new(0, self.worker_count, false),
            );
        }
        if chunks.len() == 1 {
            let output = chunks[0]
                .clone()
                .filter_map(|index| transform(&items[index]))
                .collect::<Vec<_>>();
            return (output, JobDispatchReport::new(1, self.worker_count, false));
        }

        let results = self.map_chunks(&chunks, |range| {
            range
                .clone()
                .filter_map(|index| transform(&items[index]))
                .collect::<Vec<_>>()
        });
        (
            results.into_iter().flatten().collect(),
            JobDispatchReport::new(chunks.len(), self.worker_count, true),
        )
    }

    /// `parallelMap` — preserves source order across chunks.
    pub fn parallel_map<Input, Output, F>(
        &self,
        items: &[Input],
        minimum_chunk_size: Option<usize>,
        transform: F,
    ) -> (Vec<Output>, JobDispatchReport)
    where
        Input: Sync,
        Output: Send + Sync,
        F: Fn(&Input) -> Output + Sync,
    {
        let chunks = self.chunk_ranges(items.len(), minimum_chunk_size);
        if chunks.is_empty() {
            return (
                Vec::new(),
                JobDispatchReport::new(0, self.worker_count, false),
            );
        }
        if chunks.len() == 1 {
            let output = chunks[0]
                .clone()
                .map(|index| transform(&items[index]))
                .collect::<Vec<_>>();
            return (output, JobDispatchReport::new(1, self.worker_count, false));
        }

        let results = self.map_chunks(&chunks, |range| {
            range
                .clone()
                .map(|index| transform(&items[index]))
                .collect()
        });
        (
            results.into_iter().flatten().collect(),
            JobDispatchReport::new(chunks.len(), self.worker_count, true),
        )
    }

    /// Mirror of Swift's `chunkRanges(count:minimumChunkSize:)`.
    #[allow(clippy::single_range_in_vec_init)]
    pub fn chunk_ranges(
        &self,
        count: usize,
        minimum_chunk_size: Option<usize>,
    ) -> Vec<std::ops::Range<usize>> {
        if count == 0 {
            return Vec::new();
        }

        let resolved_minimum = (minimum_chunk_size.unwrap_or(self.minimum_chunk_size)).max(1);
        if self.worker_count <= 1 || count <= resolved_minimum {
            return vec![0..count];
        }

        let target_chunk_count = self.worker_count.min(
            (count + resolved_minimum - 1)
                .div_ceil(resolved_minimum)
                .max(1),
        );
        let chunk_size =
            resolved_minimum.max((count + target_chunk_count - 1).div_ceil(target_chunk_count));

        let mut ranges = Vec::with_capacity(target_chunk_count);
        let mut start = 0;
        while start < count {
            let end = (start + chunk_size).min(count);
            ranges.push(start..end);
            start = end;
        }
        ranges
    }

    fn run_chunks<F>(&self, chunks: &[std::ops::Range<usize>], run: F)
    where
        F: Fn(&std::ops::Range<usize>) + Sync,
    {
        let next = AtomicUsize::new(0);
        let workers = self.worker_count.min(chunks.len()).max(1);
        thread::scope(|scope| {
            for _ in 0..workers {
                scope.spawn(|| {
                    loop {
                        let index = next.fetch_add(1, Ordering::Relaxed);
                        if index >= chunks.len() {
                            break;
                        }
                        run(&chunks[index]);
                    }
                });
            }
        });
    }

    fn map_chunks<Output, F>(&self, chunks: &[std::ops::Range<usize>], run: F) -> Vec<Vec<Output>>
    where
        Output: Send,
        F: Fn(&std::ops::Range<usize>) -> Vec<Output> + Sync,
    {
        let results: Mutex<Vec<Option<Vec<Output>>>> =
            Mutex::new((0..chunks.len()).map(|_| None).collect());
        let next = AtomicUsize::new(0);
        let workers = self.worker_count.min(chunks.len()).max(1);
        thread::scope(|scope| {
            for _ in 0..workers {
                scope.spawn(|| {
                    loop {
                        let index = next.fetch_add(1, Ordering::Relaxed);
                        if index >= chunks.len() {
                            break;
                        }
                        let output = run(&chunks[index]);
                        if let Ok(mut slots) = results.lock() {
                            slots[index] = Some(output);
                        }
                    }
                });
            }
        });
        let slots = results
            .into_inner()
            .unwrap_or_else(|error| error.into_inner());
        slots
            .into_iter()
            .map(|slot| slot.unwrap_or_default())
            .collect()
    }
}

impl Default for JobSystem {
    fn default() -> Self {
        Self::with_available_parallelism()
    }
}

/// Shared counter used by callers that need to observe a running job system.
pub type SharedJobSystem = Arc<JobSystem>;
