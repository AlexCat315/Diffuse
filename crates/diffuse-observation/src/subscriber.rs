//! `SubscriberToken` and the push subscriptions built on the bus.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::thread::{self, JoinHandle};
use std::time::Duration;

use crate::event_envelope::EventEnvelope;
use crate::publisher::{ObservationBus, ObservationSubscription, SubscriptionSpec};

/// RAII lifetime token. Unsubscribes from the bus when cancelled or dropped.
pub struct SubscriberToken {
    pub subscription_id: String,
    bus: Arc<ObservationBus>,
    cancelled: AtomicBool,
    stop: Arc<(Mutex<bool>, Condvar)>,
    worker: Mutex<Option<JoinHandle<()>>>,
}

impl SubscriberToken {
    fn new(bus: Arc<ObservationBus>, subscription_id: String) -> Self {
        SubscriberToken {
            subscription_id,
            bus,
            cancelled: AtomicBool::new(false),
            stop: Arc::new((Mutex::new(false), Condvar::new())),
            worker: Mutex::new(None),
        }
    }

    pub fn cancel(&self) {
        if self.cancelled.swap(true, Ordering::SeqCst) {
            return;
        }
        let (lock, condvar) = &*self.stop;
        if let Ok(mut stopped) = lock.lock() {
            *stopped = true;
            condvar.notify_all();
        }
        self.bus.unsubscribe(&self.subscription_id);
    }

    #[inline]
    pub fn is_cancelled(&self) -> bool {
        self.cancelled.load(Ordering::SeqCst)
    }

    fn attach(&self, handle: JoinHandle<()>) {
        if let Ok(mut slot) = self.worker.lock() {
            *slot = Some(handle);
        }
    }
}

impl Drop for SubscriberToken {
    fn drop(&mut self) {
        self.cancel();
        if let Ok(mut slot) = self.worker.lock()
            && let Some(handle) = slot.take()
        {
            let _ = handle.join();
        }
    }
}

impl ObservationBus {
    /// Push-based subscription: `handler` runs on a polling thread every
    /// `interval` whenever new events arrive. Dropping or cancelling the token
    /// unsubscribes.
    pub fn sink<F>(
        self: &Arc<Self>,
        spec: SubscriptionSpec,
        interval: Duration,
        handler: F,
    ) -> Arc<SubscriberToken>
    where
        F: Fn(Vec<EventEnvelope>) + Send + 'static,
    {
        let subscription = self.subscribe(spec);
        let token = Arc::new(SubscriberToken::new(self.clone(), subscription.id.clone()));
        let task_token = token.clone();
        let stop = token.stop.clone();
        let handle = thread::spawn(move || {
            loop {
                {
                    let (lock, condvar) = &*stop;
                    let Ok(stopped) = lock.lock() else {
                        break;
                    };
                    let result = condvar.wait_timeout(stopped, interval);
                    match result {
                        Ok((guard, _)) if *guard => break,
                        Ok(_) => {}
                        Err(_) => break,
                    }
                }
                if task_token.is_cancelled() {
                    break;
                }
                let events = subscription.drain();
                if !events.is_empty() {
                    handler(events);
                }
            }
        });
        token.attach(handle);
        token
    }

    /// Same as `sink`, but hands the subscription to a caller-owned receiver.
    pub fn events_stream(
        self: &Arc<Self>,
        spec: SubscriptionSpec,
        interval: Duration,
    ) -> (
        Arc<SubscriberToken>,
        std::sync::mpsc::Receiver<EventEnvelope>,
    ) {
        let (sender, receiver) = std::sync::mpsc::channel();
        let subscription = self.subscribe(spec);
        let token = Arc::new(SubscriberToken::new(self.clone(), subscription.id.clone()));
        let task_token = token.clone();
        let stop = token.stop.clone();
        let handle = thread::spawn(move || {
            loop {
                {
                    let (lock, condvar) = &*stop;
                    let Ok(stopped) = lock.lock() else {
                        break;
                    };
                    match condvar.wait_timeout(stopped, interval) {
                        Ok((guard, _)) if *guard => break,
                        Ok(_) => {}
                        Err(_) => break,
                    }
                }
                if task_token.is_cancelled() {
                    break;
                }
                for envelope in subscription.drain() {
                    if sender.send(envelope).is_err() {
                        return;
                    }
                }
            }
        });
        token.attach(handle);
        (token, receiver)
    }
}

/// Keeps the concrete subscription type reachable for callers that need it.
pub type Subscription = ObservationSubscription;
