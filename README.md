# 98_DEXCOM – Dexcom-CGM-Werte direkt in FHEM

FHEM-Modul, das den aktuellen Glukosewert eines **Dexcom-CGM** samt Trend über den
Dexcom-Share-Dienst abruft und daraus eine Tagesstatistik, den **GMI über 14 Tage** und
**Unterzuckerungs-Episoden** berechnet. Ohne Home Assistant, ohne MQTT, ohne Cloud-Dienste Dritter.

> **Kein Medizinprodukt.** Alle Werte dienen nur der Information. Für Therapieentscheidungen
> und Alarme sind ausschließlich die Dexcom-App und ihre Warnungen maßgeblich.

## Funktionen

- Aktueller Wert in mg/dL und mmol/L, Messzeitpunkt und Alter des Werts
- Trend als Text (`steigend`, `stabil`, `leicht fallend` …), Pfeil (`↗`) und Dexcom-Code
- Tagesstatistik aus **allen** Sensorwerten des Tages (5-Minuten-Takt, nicht nur aus dem, was zufällig geloggt wurde):
  Maximum, Minimum, Durchschnitt, Anteil im Zielbereich
- Tagesdurchschnitte der letzten 14 Tage und **GMI** (Glucose Management Indicator)
- **Unterzuckerungs-Episoden** nach internationalem CGM-Konsensus (≥ 15 Minuten unter der Grenze)
- Schutz vor Kontosperre: nach einer abgelehnten Anmeldung keine weiteren Versuche
- Zugangsdaten verschleiert im FHEM-Schlüsselspeicher, nicht in der `fhem.cfg`
- Ausführliche FHEM-Hilfe auf Deutsch und Englisch (`help DEXCOM`)

## Voraussetzungen

- In der **Dexcom-App ist Share aktiviert** (mit mindestens einem Follower).
- Die Zugangsdaten des Kontos, das **teilt** – also der Person, die den Sensor trägt.
  Ein Follower-Konto meldet sich zwar an, hat aber keine eigenen Werte.
- FHEM mit den Perl-Modulen `JSON` (Debian: `libjson-perl`) und `HttpUtils` (Teil von FHEM).

## Installation

**Über das FHEM-Update** (empfohlen, so kommen auch spätere Versionen automatisch):

```
update add https://raw.githubusercontent.com/Techtobi83/fhem-dexcom/main/controls_dexcom.txt
update all https://raw.githubusercontent.com/Techtobi83/fhem-dexcom/main/controls_dexcom.txt
shutdown restart
```

**Oder von Hand:** `FHEM/98_DEXCOM.pm` nach `/opt/fhem/FHEM/` kopieren (Besitzer `fhem`), dann in FHEM
`reload 98_DEXCOM`.

## Einrichtung

```
define Dexcom DEXCOM
attr Dexcom room Gesundheit
set Dexcom account <Benutzername> <Passwort>
save
```

- Benutzername wie bei der Anmeldung in der Dexcom-App (E-Mail, Benutzername oder Telefonnummer mit `+49…`).
- Ein `;` im Passwort muss in der FHEM-Befehlszeile als `;;` geschrieben werden.
- Konten außerhalb der USA (z. B. Deutschland) nutzen den Standard `region ous`. US-Konten: `attr Dexcom region us`.

Wert und Pfeil in der Geräteübersicht: `attr Dexcom stateFormat glucose trend_arrow`

## Readings

| Reading | Inhalt |
|---|---|
| `state`, `glucose`, `glucose_mmol` | aktueller Wert |
| `glucose_time`, `glucose_age` | Messzeitpunkt, Alter in Minuten |
| `trend`, `trend_arrow`, `trend_code` | Trend als Text, Pfeil, Dexcom-Code |
| `glucose_max_today`, `glucose_min_today`, `glucose_avg_today` | heute |
| `glucose_in_range_percent` | Anteil heute in `rangeLow`..`rangeHigh` (Standard 80–180) |
| `glucose_avg_yesterday`, `glucose_avg_history` | Tagesdurchschnitte (14 Tage) |
| `glucose_GMI_14_days` | 3,31 + 0,02392 × Mittel der Tagesdurchschnitte |
| `hypo_episodes_today`, `hypo_minutes_today`, `hypo_active` | Unterzuckerungen heute |
| `last_hypo`, `last_hypo_duration`, `last_hypo_lowest` | letzte Unterzuckerung |
| `lastError` | letzter Fehler oder `none` |

Attribute: `region`, `interval` (Sekunden, Standard 300), `rangeLow`, `rangeHigh`, `hypoLimit` (Standard 70), `disable`.
Alle Details in der FHEM-Hilfe: `help DEXCOM`.

## Hinweise

- Das Modul nutzt die **inoffizielle** Dexcom-Share-Schnittstelle, wie die Dexcom-Follow-App,
  Home Assistant und pydexcom. Dexcom kann sie jederzeit ändern.
- Ein Sensor-Ablaufdatum ist über Share nicht verfügbar.

## Dank

Ablauf und Fehlercodes der Share-Schnittstelle nach [pydexcom](https://github.com/gagebenne/pydexcom) (MIT-Lizenz).

## Lizenz

GPL v2 oder später, wie FHEM. Dexcom ist eine Marke der Dexcom, Inc.; dieses Projekt steht in keiner Verbindung zu Dexcom.
