# PPTX MacToWindows Fix

Een kleine Mac-app in de menubalk. Ze maakt afbeeldingen die je in PowerPoint voor Mac plakt (knipsels uit een PDF) scherp wanneer de presentatie op Windows geopend wordt. Je origineel blijft ongewijzigd; de Windows-versie komt ernaast als `naam_windows.pptx`.

![icoon](assets/icon.png)

## Het probleem

Als je in PowerPoint voor Mac een stuk uit een PDF plakt, bewaart PowerPoint dat als een EMF-bestand met twee versies erin:

- de originele PDF, scherp op elke grootte. Die toont de Mac.
- een reservekopie als bitmap van meestal 400 tot 550 pixels breed. Die toont Windows, want Windows kan de PDF niet lezen.

Op een dia uitvergroot komt die reservekopie uit op 45 tot 75 ppi, en dan zie je pixels.

## Wat de app doet

1. Zoekt in de presentatie naar die EMF-bestanden met een PDF erin.
2. Tekent de PDF opnieuw als PNG van 300 ppi, op de grootte waarop hij op de dia staat (maximaal 5000 pixels). Dat gebeurt met de PDF-engine van macOS, dus het ziet eruit zoals op je Mac.
3. Vervangt het EMF-bestand door die PNG. Positie, grootte en bijsnijding blijven gelijk; alle andere onderdelen van het bestand blijven byte voor byte hetzelfde.
4. Leest het nieuwe bestand terug ter controle voor het opgeslagen wordt.

Andere afbeeldingen (gewone PNG, JPEG) raakt de app niet aan. Een presentatie zonder zulke knipsels krijgt geen Windows-versie.

## Gebruik

De app staat als toverstaf-icoon in de menubalk.

- **Slepen:** sleep een .pptx (of een map) op het icoon in de menubalk, of op de app in Finder.
- **Automatisch:** kies in het menu een map. Elke presentatie die daarin (of in een submap) terechtkomt of gewijzigd wordt, krijgt automatisch een Windows-versie ernaast. Wijzig je het origineel, dan wordt de Windows-versie bijgewerkt.
- **Starten bij inloggen:** aan te zetten in het menu.

Klik op de melding "Windows-versie klaar" om het bestand in Finder te tonen.

## Installeren

Download `PPTX-MacToWindows-Fix-macOS.zip` bij de laatste release, pak uit en sleep de app naar Programma's. De release-versie is ondertekend en genotariseerd door Apple.

## Releases

Een release publiceren op GitHub (tag bv. `v1.0.0`) bouwt, test, ondertekent en notariseert de app en hangt de zip aan de release. Werk eerst `VERSION` bij.

Elke push naar `main` bouwt en test de app ook; die versie staat als download bij de run in het tabblad Actions (ondertekend, niet genotariseerd). De logboeken van de laatste run staan op de branch `ci-report`.

Secrets (Settings > Secrets and variables > Actions), dezelfde als bij AutoSign:

| Secret | Waarde |
|---|---|
| `MACOS_CERT_P12` | *Developer ID Application*-certificaat + sleutel als .p12, base64 |
| `MACOS_CERT_PASSWORD` | Wachtwoord van de .p12 |
| `APPLE_ID` | Apple ID (voor notarisatie) |
| `APPLE_TEAM_ID` | Team ID |
| `APPLE_APP_PASSWORD` | App-specifiek wachtwoord |

## Zelf bouwen

Vereist Xcode of de Command Line Tools, macOS 13 of nieuwer.

```
./build_app.sh
tests/run_tests.sh      # vereist: pip install python-pptx pillow
```

Opdrachtregel: `"PPTX MacToWindows Fix.app/Contents/MacOS/PPTXFix" --fix in.pptx [uit.pptx]`

## Opbouw

| Bestand | Inhoud |
|---|---|
| `Sources/Zip.swift` | ZIP lezen en schrijven (geen externe bibliotheken) |
| `Sources/EMF.swift` | De PDF uit een Mac-EMF halen |
| `Sources/Render.swift` | PDF naar PNG met CoreGraphics |
| `Sources/Fixer.swift` | De presentatie aanpassen en controleren |
| `Sources/main.swift` | Menubalk, slepen, bewaakte map, meldingen |
| `tests/` | Testpresentatie maken en de uitkomst controleren |
