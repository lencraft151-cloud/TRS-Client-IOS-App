//! Leistungsprofil für Android/iOS: Startwerte der `options.txt` (Sichtweite, Grafik, FPS …) passend zum
//! Arbeitsspeicher des Geräts. Geschrieben wird nur eine neue `options.txt` (siehe
//! [`crate::instance::seed_game_options`]) – was der Spieler im Spiel einstellt, bleibt.

/// Geräteklasse nach Arbeitsspeicher.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Tier {
    /// Unter ~3,5 GB (ältere iPhones/Android-Geräte).
    Low,
    /// ~4–5 GB (z. B. iPhone 12/13 mini, viele Mittelklasse-Androids).
    Mid,
    /// Ab ~6 GB (Pro-Modelle, iPads, Oberklasse).
    High,
}

/// Unbekannter Speicher gilt als Mittelklasse.
pub fn tier(device_mb: Option<u32>) -> Tier {
    match device_mb {
        Some(mb) if mb < 3500 => Tier::Low,
        Some(mb) if mb < 5500 => Tier::Mid,
        Some(_) => Tier::High,
        None => Tier::Mid,
    }
}

/// Startwerte je Klasse. `graphicsMode` (ab 1.16) und `fancyGraphics` (ältere Versionen) stehen beide drin –
/// Minecraft liest den passenden und überspringt den anderen. VSync an, damit das Gerät nicht unnötig heiß wird.
pub fn game_options(tier: Tier) -> &'static [(&'static str, &'static str)] {
    match tier {
        Tier::Low => &[
            ("renderDistance", "5"),
            ("simulationDistance", "5"),
            ("graphicsMode", "0"),
            ("fancyGraphics", "false"),
            ("particles", "2"),
            ("entityShadows", "false"),
            ("biomeBlendRadius", "0"),
            ("mipmapLevels", "0"),
            ("entityDistanceScaling", "0.75"),
            ("maxFps", "30"),
            ("enableVsync", "true"),
        ],
        Tier::Mid => &[
            ("renderDistance", "7"),
            ("simulationDistance", "6"),
            ("graphicsMode", "0"),
            ("fancyGraphics", "false"),
            ("particles", "1"),
            ("entityShadows", "false"),
            ("biomeBlendRadius", "1"),
            ("mipmapLevels", "2"),
            ("maxFps", "60"),
            ("enableVsync", "true"),
        ],
        Tier::High => &[
            ("renderDistance", "10"),
            ("simulationDistance", "8"),
            ("graphicsMode", "1"),
            ("fancyGraphics", "true"),
            ("particles", "0"),
            ("entityShadows", "true"),
            ("biomeBlendRadius", "2"),
            ("mipmapLevels", "4"),
            ("maxFps", "60"),
            ("enableVsync", "true"),
        ],
    }
}

/// Speicher, von dem der Java-Heap höchstens die Hälfte bekommt (siehe [`crate::mobile_launch::mobile_heap_mb`]).
/// iOS: was die App bis zur Speichergrenze von iOS noch belegen darf – das Spiel läuft im selben Prozess wie der
/// Launcher, und iOS beendet die App beim Überschreiten sofort. Android: der Arbeitsspeicher des Geräts.
pub fn heap_base_mb() -> Option<u32> {
    if cfg!(target_os = "ios") {
        crate::platform::available_memory_mb().or_else(crate::platform::total_memory_mb)
    } else {
        crate::platform::total_memory_mb()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tiers_follow_device_memory() {
        assert_eq!(tier(Some(2048)), Tier::Low);
        assert_eq!(tier(Some(3072)), Tier::Low);
        // iPhone 13 mini: 4 GB (iOS meldet etwas weniger).
        assert_eq!(tier(Some(3800)), Tier::Mid);
        assert_eq!(tier(Some(5800)), Tier::High);
        assert_eq!(tier(Some(8192)), Tier::High);
        assert_eq!(tier(None), Tier::Mid);
    }

    #[test]
    fn weaker_devices_get_lighter_settings() {
        let value = |t: Tier, key: &str| game_options(t).iter().find(|(k, _)| *k == key).map(|(_, v)| v.parse::<f32>().unwrap()).unwrap();
        assert!(value(Tier::Low, "renderDistance") < value(Tier::Mid, "renderDistance"));
        assert!(value(Tier::Mid, "renderDistance") < value(Tier::High, "renderDistance"));
        assert!(value(Tier::Low, "maxFps") <= value(Tier::Mid, "maxFps"));
        for t in [Tier::Low, Tier::Mid, Tier::High] {
            assert!(value(t, "simulationDistance") <= value(t, "renderDistance"));
            assert!(game_options(t).iter().all(|(k, v)| !k.is_empty() && !v.is_empty() && !k.contains(':') && !v.contains('\n')));
        }
    }
}
