# SCCM RightClickTools

Konsolenerweiterungen ("Right-Click Tools") für die Microsoft Configuration Manager (SCCM/ConfigMgr) Admin-Konsole.

> **English TL;DR:** Legacy file-based ConfigMgr console extensions. Currently contains **CollectionMembership** – a right-click tool for device collections that shows, in two tabs (Required / Available), which collections include the selected collection via an include rule, and lets you add/remove memberships. Run `CollectionMembership\Install-Extension.ps1` as admin. **Important:** the hierarchy setting *"Only allow console extensions that are approved for the hierarchy"* must be **disabled**, otherwise file-based extensions are silently hidden. UI and menu entry are bilingual (DE/EN, auto-detected).

---

## CollectionMembership – "Mitgliedschaft verwalten"

Rechtsklick auf eine **Gerätesammlung** im Ergebnisbereich → **Mitgliedschaft verwalten**.

Der Dialog zeigt in zwei Karteikarten – **Pflicht** (`ins-req-dev-*`) und **Verfügbar** (`ins-avl-dev-*`) – welche Collections die gewählte Collection bereits als Mitglied (Include-Rule) enthalten und welche nicht. Per Pfeil-Buttons werden Collections nach links/rechts verschoben; **Speichern** legt die Include-Rules an bzw. entfernt sie.

- `...`-Button: zur Laufzeit eine andere Collection wählen (sucht automatisch nach `rol-dev`).
- Namensmuster in der Kopfzeile frei anpassbar.
- GUI **und** Menü-Eintrag zweisprachig (Deutsch/Englisch), automatisch nach Console-Sprache.

### Installation

Auf dem Rechner mit der ConfigMgr-Konsole, in einer **Administrator-PowerShell**:

```powershell
.\CollectionMembership\Install-Extension.ps1
```

Optionale Parameter:

| Parameter           | Standard          | Beschreibung                                            |
|---------------------|-------------------|---------------------------------------------------------|
| `-PatternRequired`  | `ins-req-dev-*`   | Namensmuster für die Pflicht-Karteikarte                |
| `-PatternAvailable` | `ins-avl-dev-*`   | Namensmuster für die Verfügbar-Karteikarte              |
| `-ConsolePath`      | *(auto)*          | Pfad zur AdminConsole, falls nicht automatisch gefunden |
| `-Language`         | `auto`            | `auto` \| `de` \| `en` – erzwingt die Sprache           |

Der Installer:
1. ermittelt den AdminConsole-Pfad,
2. kompiliert `nopswindow.cs` → `nopswindow.exe` (startet PowerShell ohne Konsolenfenster),
3. kopiert das GUI-Skript nach `AdminConsole\extensions\RightClickTools\`,
4. legt die Action-XML unter `AdminConsole\XmlStorage\Extensions\Actions\{a92615d6-9df3-49ba-a8c9-6ecb0e8b956b}\` ab.

Danach die Konsole **komplett beenden und neu starten**.

### ⚠️ Wichtigste Fehlerquelle: Hierarchie-Einstellung

Ab ConfigMgr 2103 gibt es die Hierarchie-Einstellung **"Only allow console extensions that are approved for the hierarchy"** (bei 2103-Baseline-Installationen **standardmäßig aktiv**). Solange sie aktiv ist, werden **alle alten file-basierten Extensions stillschweigend ausgeblendet** – kein Menüpunkt, kein Log-Eintrag.

Abschalten: **Verwaltung → Standortkonfiguration → Standorte → (Menüband) Hierarchieeinstellungen → Reiter Allgemein** → Häkchen entfernen → Konsole neu starten.

### Diagnose

```powershell
# Prüft, ob alle Dateien korrekt installiert sind:
.\CollectionMembership\Verify-Installation.ps1

# Listet Device-/Collection-bezogene ActionSpace-GUIDs (zum Anpassen an andere Objekte):
.\CollectionMembership\Find-DeviceCollectionsGUID.ps1
```

### Deinstallation

```powershell
$cp = "D:\Program Files\Microsoft Configuration Manager\AdminConsole"  # ggf. anpassen
Remove-Item "$cp\XmlStorage\Extensions\Actions\{a92615d6-9df3-49ba-a8c9-6ecb0e8b956b}" -Recurse -Force
Remove-Item "$cp\extensions\RightClickTools\Manage-CollectionMembership.ps1" -Force
Remove-Item "$cp\extensions\RightClickTools\nopswindow.exe" -Force
```

## Technische Hinweise

- **GUID `a92615d6-9df3-49ba-a8c9-6ecb0e8b956b`** = einzelne Device-Collection im Ergebnisbereich (dokumentierter, stabiler Standard). **Nicht** verwechseln mit der DeviceCollectionsNode-GUID `6d357b6b-…` (das ist der Baum-Knoten, kein Item-Rechtsklick).
- **Action-Schema** (`Class="Executable"`): die Elemente heißen `<FilePath>` und `<Parameters>`. Unbekannte Elemente/Attribute führen dazu, dass die Action **still verworfen** wird.
- Alle `.ps1` werden als **UTF-8 mit BOM** gespeichert (sonst zerstört PowerShell 5.x Umlaute).
- Laufzeit-Tokens, die die Console ersetzt: `##SUB:CollectionID##`, `##SUB:Name##`.

## Voraussetzungen

- Microsoft Configuration Manager Admin-Konsole (Current Branch)
- .NET Framework (für die Kompilierung von `nopswindow.exe` via `csc.exe`)
- Ausführung als Administrator
