# Kammer – Vorrat, Einkauf & Haushalt

SwiftUI-App für iPhone (iOS 17+). Daten liegen lokal auf dem Gerät (SwiftData).

## Was drin ist

- **Vorrat**: Basics als Kacheln mit Füllstand, leer/knapp-Markierung, Bestand per Plus/Minus, „Ist leer“, „Aufgefüllt“, Mindesthaltbarkeit, Preisverlauf.
- **Produkt hinzufügen**: Name, REWE-Artikelnummer, REWE-Link (aus der REWE-App über „Teilen“) oder Barcode-Scan. Barcode holt Name und Nährwerte aus Open Food Facts. Bezugsquelle REWE / Metzger / Sonstiges, „Warnen ab“, „Auffüllen auf“, Packungsgröße, Preis, Ausweichartikel.
- **Prognose**: rechnet mit dem Wochenplan, ob ein Produkt bis zur nächsten Lieferung (REWE) bzw. zum Metzger-Tag reicht. Knappe Produkte landen automatisch auf der passenden Liste – mit Packungsanzahl.
- **Täglicher Check** (Standard 18:00): fragt nur 3–6 unsichere Produkte ab.
- **Mahlzeiten**: Vorlagen aus euren Produkten, „Gegessen“ aus dem Wochenplan, freie Einträge. Kalorien, Makros und Kosten pro Mahlzeit; Zutaten werden vom Vorrat abgebucht.
- **Wochenplan**: Vorlagen auf Tage und Mahlzeiten verteilen, „Montag auf alle Tage übertragen“.
- **Einkauf**: REWE-, Metzger- und Sonstiges-Liste mit Preisschätzung, Teilen, „Lieferung erhalten“/„Eingekauft“ füllt den Vorrat auf und bucht den Betrag (Kassenbon-Scan liest die Summe auf dem Gerät aus).
- **Ausgaben**: Monat gegen Budget (800 €), Aufteilung REWE/Metzger, Prognose fürs Monatsende, Kosten pro Woche/Mahlzeit/100 g Protein, 6-Monats-Verlauf.
- **Benachrichtigungen** (alle lokal, funktionieren auch bei Sideloading): täglicher Check, „wird knapp“, Mindesthaltbarkeit, Metzger-Tag mit Liste, Budget-Warnung.
- **Einstellungen**: Bestelltag, Liefertag/-fenster, Zeitpunkt Warenkorb-Befüllung, Metzger-Tag, Budget, Erinnerungen, Tagesziele.

Zum Ausprobieren gibt es im leeren Vorrat „Beispiel-Basics laden“ (Nährwerte = grobe Richtwerte).

## Neu in 1.1

- **Name & Icon**: „Kammer“. Bundle-ID bleibt `de.egler.wocheneinkauf`, Build-Nummer zählt automatisch hoch – Updates installieren sich über die alte Version.
- **Haushalt & andere Läden**: Produkte von Biomarkt, Amazon, dm … mit Laden, Link und Foto. Verbrauch pro Woche (z. B. Waschmittel: 60 Anwendungen, 6 pro Woche) wird automatisch abgezogen; Warnung X Tage vorher.
- **Wunschliste**: einmalige Dinge mit Link (übernimmt Name, Laden, Bild), Foto, Preis und Erinnerungsdatum. Abhaken bucht den Preis unter „Haushalt & Wünsche“ – getrennt vom Lebensmittel-Budget.
- **Gemeinsam nutzen**: Supabase-Datenbank, beide iPhones gleichen sich ab (beim Öffnen und jede Minute). Zweites iPhone tritt per QR-Code bei. Die aktuelle Einkaufsliste liegt zusätzlich als Datensatz `shoppinglist` für die REWE-Automatik bereit.

## Datenbank einrichten (einmalig)

1. Kostenloses Projekt auf supabase.com anlegen.
2. SQL Editor → `supabase/schema.sql` einfügen → Run.
3. Project Settings → API: Project URL und anon-/publishable-Key kopieren.
4. In der App: Einstellungen → Gemeinsam nutzen → URL + Key → „Haushalt anlegen“.
5. Zweites iPhone: Einstellungen → Gemeinsam nutzen → „QR-Code scannen“.

## Neueste Version

Immer unter: https://github.com/schp123/Haushalt_App/releases/latest/download/Kammer.ipa

## Bauen

### Variante A – auf dem Mac mit Xcode
```bash
brew install xcodegen
cd Wocheneinkauf
xcodegen generate
open Wocheneinkauf.xcodeproj
```
In Xcode unter *Signing & Capabilities* dein Team wählen und auf dem iPhone starten.

### Variante B – IPA automatisch über GitHub
Ordner als Repository auf GitHub hochladen. Der Workflow `.github/workflows/build-ipa.yml` baut bei jedem Push auf `main` eine **unsignierte IPA** (unter *Actions → Artifacts*). Die IPA im Sideload-Store hochladen – der signiert sie beim Installieren.

## Nächste Ausbaustufen

3. **REWE-Automatik**: geplante Claude-Aufgabe Mittwoch 20:00 auf dem Mac – legt die REWE-Liste über Claude in Chrome in den Warenkorb, speichert gefundene Artikelnummern und Preise, trägt nach der Lieferung den Rechnungsbetrag ein, Push „Warenkorb gefüllt“ über ntfy. Angebots-Hinweise für Stammprodukte.
4. **Komfort**: Mahlzeit per Foto/Sprache (Claude API), Apple Health, Home-Screen-Widget, Siri-Kurzbefehl „Milch ist leer“.
