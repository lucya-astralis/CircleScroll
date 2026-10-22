# CircleScroll

Kreisförmiges Scrollen à la Panasonic Let's Note für macOS.

Modifier-Taste (Standard: **⌥ Option**) halten und mit dem Finger auf dem Trackpad kreisen:

- ↻ im Uhrzeigersinn = nach unten scrollen
- ↺ gegen den Uhrzeigersinn = nach oben scrollen

Der Mauszeiger bleibt dabei stehen. Die Kreisgröße ist egal – wie weit gescrollt wird, hängt nur von der Drehung und deren Tempo ab, wie bei einem Jog-Dial.

## Einstellungen (Menüleisten-Symbol)

- Taste: ⌥ / ⌃ / ⌘ / ⇧ / fn
- Geschwindigkeit (4 Stufen)
- Beschleunigung: schnelles Kreisen scrollt weiter, langsames feiner (Aus / Leicht / Mittel / Stark)
- Richtung umkehren
- Bei Anmeldung starten
- Ein/Aus

## Bauen

Voraussetzung: macOS 13+, Swift-Toolchain (Xcode oder Command Line Tools).

```sh
./build.sh
open build/CircleScroll.app
```

Beim ersten Start fragt macOS nach dem **Bedienungshilfen**-Zugriff. Nach der Freigabe aktiviert sich die App automatisch.

Hinweis: Die App ist nur ad-hoc signiert. Nach einem Neubau muss der Eintrag unter *Systemeinstellungen → Datenschutz & Sicherheit → Bedienungshilfen* meist entfernt und neu hinzugefügt werden.
