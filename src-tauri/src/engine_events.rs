//! Spielstart auf Android/iOS: Ereignisse der Engine, die ankommen, bevor die Sitzung im Spiele-Manager steht, werden
//! gesammelt und danach in Reihenfolge nachgereicht (sonst gingen frühe Zeilen verloren).
//!
//! Hier wird nie auf den Start gewartet: iOS meldet „starting“ noch im selben Aufruf (Tauri ruft Rust-Listener auf dem
//! sendenden Thread auf) und weitere Ereignisse auf dem Haupt-Thread, während der Start auf ihn wartet. Eine Sperre um
//! den ganzen Start hing deshalb jedes Mal bei „Starte Spiel 98 %“.
#![cfg_attr(not(mobile), allow(dead_code))]

use std::sync::{Mutex, MutexGuard, PoisonError};

/// Sammelstelle für frühe Ereignisse (am Handy läuft immer nur ein Spiel, also ein Start zur Zeit).
pub struct EarlyEvents<T> {
    inner: Mutex<State<T>>,
}

struct State<T> {
    starting: bool,
    early: Vec<T>,
}

impl<T> EarlyEvents<T> {
    pub const fn new() -> Self {
        Self { inner: Mutex::new(State { starting: false, early: Vec::new() }) }
    }

    fn lock(&self) -> MutexGuard<'_, State<T>> {
        self.inner.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// Ein Start beginnt: Ereignisse ab jetzt sammeln.
    pub fn begin(&self) -> Starting<'_, T> {
        let mut state = self.lock();
        state.starting = true;
        state.early.clear();
        Starting { events: self }
    }

    /// Ereignis zustellen: während eines Starts sammeln, sonst gleich `handle`. Blockiert nie.
    pub fn deliver(&self, event: T, handle: impl FnOnce(T)) {
        {
            let mut state = self.lock();
            if state.starting {
                state.early.push(event);
                return;
            }
        }
        handle(event);
    }
}

/// Laufender Start. Endet er ohne [`Starting::attached`] (Fehler), fallen die gesammelten Ereignisse weg.
pub struct Starting<'a, T> {
    events: &'a EarlyEvents<T>,
}

impl<T> Starting<'_, T> {
    /// Die Sitzung steht im Spiele-Manager: Gesammeltes in Reihenfolge nachreichen – auch, was währenddessen ankommt.
    /// `handle` läuft ohne Sperre.
    pub fn attached(self, mut handle: impl FnMut(T)) {
        loop {
            let batch = {
                let mut state = self.events.lock();
                if state.early.is_empty() {
                    state.starting = false;
                    return;
                }
                std::mem::take(&mut state.early)
            };
            batch.into_iter().for_each(&mut handle);
        }
    }
}

impl<T> Drop for Starting<'_, T> {
    fn drop(&mut self) {
        let mut state = self.events.lock();
        state.starting = false;
        state.early.clear();
    }
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;

    use super::*;

    #[test]
    fn delivers_directly_without_a_start() {
        let events = EarlyEvents::new();
        let mut seen = Vec::new();
        events.deliver(1, |e| seen.push(e));
        assert_eq!(seen, [1]);
    }

    #[test]
    fn same_thread_event_during_start_does_not_block() {
        // Wie iOS: Der Start selbst meldet „starting“ – auf demselben Thread, der den Start ausführt.
        let events = EarlyEvents::new();
        let starting = events.begin();
        let mut direct = Vec::new();
        events.deliver("starting", |e| direct.push(e));
        assert!(direct.is_empty(), "gesammelt, nicht sofort");
        let mut replayed = Vec::new();
        starting.attached(|e| replayed.push(e));
        assert_eq!(replayed, ["starting"]);
        events.deliver("running", |e| replayed.push(e));
        assert_eq!(replayed, ["starting", "running"]);
    }

    #[test]
    fn other_thread_event_during_start_does_not_wait() {
        // Wie der iOS-Haupt-Thread: liefert, während der Start noch läuft, und darf dabei nicht hängen.
        let events = Arc::new(EarlyEvents::new());
        let starting = events.begin();
        let other = Arc::clone(&events);
        std::thread::spawn(move || other.deliver(7, |_| panic!("während des Starts nicht direkt")))
            .join()
            .expect("Thread kehrt zurück, ohne auf den Start zu warten");
        let mut replayed = Vec::new();
        starting.attached(|e| replayed.push(e));
        assert_eq!(replayed, [7]);
    }

    #[test]
    fn events_arriving_during_replay_keep_their_order() {
        let events = Arc::new(EarlyEvents::new());
        let starting = events.begin();
        events.deliver(1, |_| unreachable!());
        let seen = Arc::new(Mutex::new(Vec::new()));
        let (inner_events, inner_seen) = (Arc::clone(&events), Arc::clone(&seen));
        starting.attached(|e| {
            seen.lock().unwrap().push(e);
            // Während des Nachreichens kommt das nächste Ereignis – es muss danach drankommen.
            if e == 1 {
                let s = Arc::clone(&inner_seen);
                inner_events.deliver(2, move |x| s.lock().unwrap().push(x));
            }
        });
        events.deliver(3, |e| seen.lock().unwrap().push(e));
        assert_eq!(*seen.lock().unwrap(), [1, 2, 3]);
    }

    #[test]
    fn failed_start_drops_collected_events() {
        let events = EarlyEvents::new();
        {
            let _starting = events.begin();
            events.deliver(1, |_| unreachable!());
        }
        let mut seen = Vec::new();
        events.deliver(2, |e| seen.push(e));
        assert_eq!(seen, [2]);
    }
}
