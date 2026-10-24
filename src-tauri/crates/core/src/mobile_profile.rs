//! Leistungsprofil für Android/iOS: Startwerte der `options.txt` (Sichtweite, Grafik, FPS …) passend zum
//! Arbeitsspeicher des Geräts. Geschrieben wird nur eine neue `options.txt` (siehe
//! [`crate::instance::seed_game_options`]) – was der Spieler im Spiel einstellt, bleibt.
//! Dazu der Akku-Plan für iOS ([`PowerPlan`]): Auflösung des Spiels und Obergrenzen für FPS und Sichtweite.

use serde::{Deserialize, Serialize};

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

/// iOS: wie sparsam das Spiel mit dem Akku umgeht (Einstellung „Akku beim Spielen“).
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum GamePower {
    /// Volle Auflösung, keine Grenzen.
    Performance,
    /// 75 % Auflösung, höchstens 60 FPS; im Stromsparmodus wie „Akku sparen“.
    #[default]
    Balanced,
    /// Halbe Auflösung, höchstens 30 FPS und kürzere Sichtweite.
    Saver,
}

/// Unbekannte Werte (neuere Version) gelten als [`GamePower::Balanced`].
pub(crate) fn lenient_power<'de, D: serde::Deserializer<'de>>(deserializer: D) -> std::result::Result<GamePower, D::Error> {
    let value = serde_json::Value::deserialize(deserializer)?;
    Ok(serde_json::from_value(value).unwrap_or_default())
}

/// Was beim Start gilt: Auflösung (Prozent der Bildschirmpixel) und Grenzen in der `options.txt`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PowerPlan {
    /// Auflösung des Spiels.
    pub render_percent: u8,
    /// Auflösung, sobald iOS in den Stromsparmodus geht (Swift wechselt auch mitten im Spiel).
    pub low_power_render_percent: Option<u8>,
    /// Höchstens so viele Bilder pro Sekunde (`maxFps`).
    pub max_fps: Option<u32>,
    /// Höchstens diese Sichtweite (`renderDistance`) bzw. Simulationsdistanz in Chunks.
    pub render_distance: Option<u32>,
    pub simulation_distance: Option<u32>,
}

const SAVER: PowerPlan =
    PowerPlan { render_percent: 50, low_power_render_percent: Some(50), max_fps: Some(30), render_distance: Some(6), simulation_distance: Some(5) };

impl PowerPlan {
    /// Plan für die Einstellung; `low_power` = Stromsparmodus beim Start.
    pub fn new(power: GamePower, low_power: bool) -> Self {
        match power {
            GamePower::Performance => {
                PowerPlan { render_percent: 100, low_power_render_percent: None, max_fps: None, render_distance: None, simulation_distance: None }
            }
            GamePower::Balanced if low_power => PowerPlan { render_percent: 75, ..SAVER },
            GamePower::Balanced => PowerPlan {
                render_percent: 75,
                low_power_render_percent: SAVER.low_power_render_percent,
                max_fps: Some(60),
                render_distance: None,
                simulation_distance: None,
            },
            GamePower::Saver => SAVER,
        }
    }

    fn caps(&self) -> [(&'static str, Option<u32>); 3] {
        [("maxFps", self.max_fps), ("renderDistance", self.render_distance), ("simulationDistance", self.simulation_distance)]
    }
}

/// Grenzen des Plans auf den Text einer `options.txt` anwenden: Werte nur senken, fehlende Zeilen anhängen,
/// alles andere unverändert. `None`, wenn nichts zu ändern ist.
pub fn cap_options(text: &str, plan: &PowerPlan) -> Option<String> {
    let caps = plan.caps();
    let mut seen = [false; 3];
    let mut changed = false;
    let mut out = String::with_capacity(text.len() + 64);
    for line in text.lines() {
        let capped = line.split_once(':').and_then(|(key, value)| {
            let i = caps.iter().position(|(k, _)| *k == key)?;
            seen[i] = true;
            let cap = caps[i].1?;
            // Unlesbare Werte ersetzt Minecraft ohnehin durch den Standard – dann lieber die Grenze.
            let current = value.trim().parse::<f64>().ok();
            current.is_none_or(|v| v > f64::from(cap)).then(|| format!("{key}:{cap}"))
        });
        match capped {
            Some(new) => {
                out.push_str(&new);
                changed = true;
            }
            None => out.push_str(line),
        }
        out.push('\n');
    }
    for (i, (key, cap)) in caps.iter().enumerate() {
        if let (false, Some(cap)) = (seen[i], cap) {
            out.push_str(&format!("{key}:{cap}\n"));
            changed = true;
        }
    }
    changed.then_some(out)
}

/// Grenzen in die `options.txt` im Spielordner schreiben. Fehlt sie, passiert nichts – sie entsteht vorher
/// mit `version:` ([`crate::instance::seed_game_options`]); ohne die Zeile hielte Minecraft sie für uralt.
/// Liefert `true`, wenn geschrieben wurde.
pub async fn apply_power_plan(game_dir: &std::path::Path, plan: &PowerPlan) -> crate::Result<bool> {
    let path = game_dir.join("options.txt");
    // Fehlt oder nicht lesbar (z. B. kein UTF-8): lieber nichts anfassen.
    let Ok(text) = tokio::fs::read_to_string(&path).await else { return Ok(false) };
    let Some(capped) = cap_options(&text, plan) else { return Ok(false) };
    crate::fsutil::write_atomic(&path, capped.as_bytes()).await?;
    Ok(true)
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

    #[test]
    fn power_plans() {
        let performance = PowerPlan::new(GamePower::Performance, true);
        assert_eq!((performance.render_percent, performance.low_power_render_percent, performance.max_fps), (100, None, None));
        let balanced = PowerPlan::new(GamePower::Balanced, false);
        assert_eq!((balanced.render_percent, balanced.low_power_render_percent, balanced.max_fps), (75, Some(50), Some(60)));
        assert_eq!(balanced.render_distance, None);
        // Stromsparmodus beim Start: Grenzen wie „Akku sparen“, Auflösung wechselt Swift selbst.
        let low = PowerPlan::new(GamePower::Balanced, true);
        assert_eq!((low.render_percent, low.max_fps, low.render_distance), (75, Some(30), Some(6)));
        assert_eq!(PowerPlan::new(GamePower::Saver, false), PowerPlan::new(GamePower::Saver, true));
        assert_eq!(PowerPlan::new(GamePower::Saver, false).render_percent, 50);
    }

    #[test]
    fn power_setting_is_lenient() {
        #[derive(Deserialize)]
        struct S {
            #[serde(deserialize_with = "lenient_power")]
            p: GamePower,
        }
        let read = |json: &str| serde_json::from_str::<S>(json).unwrap().p;
        assert_eq!(read(r#"{"p":"saver"}"#), GamePower::Saver);
        assert_eq!(read(r#"{"p":"performance"}"#), GamePower::Performance);
        assert_eq!(read(r#"{"p":"turbo"}"#), GamePower::Balanced);
        assert_eq!(serde_json::to_value(GamePower::Saver).unwrap(), "saver");
    }

    #[test]
    fn caps_only_lower_values() {
        let saver = PowerPlan::new(GamePower::Saver, false);
        let text = "version:3955\nmaxFps:120\nrenderDistance:4\nsimulationDistance:12\nlang:de_de\n";
        let capped = cap_options(text, &saver).unwrap();
        assert_eq!(capped, "version:3955\nmaxFps:30\nrenderDistance:4\nsimulationDistance:5\nlang:de_de\n");
        // Schon sparsam genug: nichts zu schreiben.
        assert_eq!(cap_options(&capped, &saver), None);
        assert_eq!(cap_options(text, &PowerPlan::new(GamePower::Performance, false)), None);
    }

    #[test]
    fn caps_add_missing_and_fix_unreadable_lines() {
        let balanced = PowerPlan::new(GamePower::Balanced, false);
        assert_eq!(cap_options("version:100\r\nmaxFps:260\r\n", &balanced).unwrap(), "version:100\nmaxFps:60\n");
        assert_eq!(cap_options("version:100\n", &balanced).unwrap(), "version:100\nmaxFps:60\n");
        assert_eq!(cap_options("maxFps:viel\nrenderDistance:3", &PowerPlan::new(GamePower::Saver, false)).unwrap(), "maxFps:30\nrenderDistance:3\nsimulationDistance:5\n");
        // Ähnliche Schlüssel bleiben unberührt.
        assert_eq!(cap_options("maxFpsMenu:200\nmaxFps:30\n", &balanced), None);
    }

    #[tokio::test]
    async fn applies_plan_to_existing_options_only() {
        let dir = tempfile::tempdir().unwrap();
        let saver = PowerPlan::new(GamePower::Saver, false);
        assert!(!apply_power_plan(dir.path(), &saver).await.unwrap());
        assert!(!dir.path().join("options.txt").exists());
        std::fs::write(dir.path().join("options.txt"), "version:3955\nmaxFps:120\n").unwrap();
        assert!(apply_power_plan(dir.path(), &saver).await.unwrap());
        let text = std::fs::read_to_string(dir.path().join("options.txt")).unwrap();
        assert_eq!(text, "version:3955\nmaxFps:30\nrenderDistance:6\nsimulationDistance:5\n");
        assert!(!apply_power_plan(dir.path(), &saver).await.unwrap());
    }
}
