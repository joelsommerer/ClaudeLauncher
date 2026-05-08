# Signing & Notarization Setup

Einmaliges Setup für Developer ID Signing + Apple Notarization. Danach kannst
du jeden Build mit `./package.sh` automatisch signieren und notarisieren.

## Vorbereitung — einmal auf diesem Mac

### 1. Developer ID Application Zertifikat erstellen

1. **Öffne Keychain Access** (Schlüsselbund)
2. Menü → **Schlüsselbundverwaltung → Zertifikatassistent → Zertifikat von einer Zertifizierungsinstanz anfordern…**
3. Eintragen:
   - **E-Mail-Adresse:** deine Apple-ID-E-Mail
   - **Allgemeiner Name:** dein Name oder Firmenname (erscheint später im Zertifikat)
   - **CA-E-Mail:** leer lassen
   - **Anforderung:** "Auf der Festplatte sichern" + "Schlüsselpaar-Information angeben"
4. **Schlüsselgröße: 2048 Bit, Algorithmus: RSA**
5. Speichere die `.certSigningRequest`-Datei auf dem Desktop
6. Öffne https://developer.apple.com/account/resources/certificates/add
7. Wähle **"Developer ID Application"** → Continue
8. Lade die `.certSigningRequest` hoch → Continue
9. Lade das fertige Zertifikat (`.cer`) herunter
10. **Doppelklick** auf die `.cer` → wird automatisch in den "login"-Schlüsselbund installiert

Verifizieren:

```bash
security find-identity -v -p codesigning
```

Sollte jetzt eine Zeile zeigen wie:

```
1) ABCDEF1234... "Developer ID Application: Joel Sommerer (XXXXXXXXXX)"
```

### 2. App-spezifisches Passwort für Notarization

1. Öffne https://account.apple.com → **Anmelden & Sicherheit → App-spezifische Passwörter**
2. **+ App-spezifisches Passwort erstellen**
3. Name: `notarytool` (oder beliebig)
4. Apple zeigt dir ein Passwort wie `abcd-efgh-ijkl-mnop` — kopieren

### 3. Credentials im Keychain hinterlegen

```bash
xcrun notarytool store-credentials "ClaudeLauncher-Notary" \
    --apple-id <deine-apple-id-email> \
    --team-id <dein-team-id> \
    --password <app-spezifisches-passwort>
```

Deine **Team-ID** findest du:
- In `security find-identity` Output (in Klammern: `(XXXXXXXXXX)`)
- Oder unter https://developer.apple.com/account → "Membership Details"

`store-credentials` speichert die Daten sicher im Keychain — du musst sie nie
wieder eingeben.

## Build mit Signing + Notarization

```bash
./package.sh
```

Das Script:
1. Baut die App (`./build.sh`)
2. Signiert mit Developer ID Application + Hardened Runtime + Entitlements
3. Submitted für Notarization (`xcrun notarytool submit --wait`)
4. Stapelt das Notarization-Ticket
5. Erzeugt notarisiertes DMG in `dist/`

Wenn das Zertifikat nicht im Keychain ist, fällt das Script auf Ad-hoc-Signing
zurück (mit Gatekeeper-Warnung beim Erstöffnen, aber installierbar).

## Erste Notarization — was zu erwarten ist

- Submit dauert typisch 2–10 Minuten
- Apple scannt nach Malware, prüft Hardened Runtime + Entitlements
- Erfolgreich = ein "Ticket" wird zurückgegeben, das wir per `staple` an die
  App heften
- Ab dann öffnet die App auf JEDEM Mac ohne Gatekeeper-Warnung, auch offline
  (das Ticket wird lokal verifiziert)

## Troubleshooting

**"errSecInternalComponent" beim Signen:**
Das Zertifikat hat keinen privaten Schlüssel. Du hast wahrscheinlich die `.cer`
auf einem anderen Mac heruntergeladen. Lösung: CSR auf DIESEM Mac erstellen,
neues Zertifikat erstellen.

**Notarization rejected:**
`xcrun notarytool log <submission-id> --keychain-profile ClaudeLauncher-Notary`
zeigt dir die exakten Reasons. Häufig: fehlendes Hardened Runtime oder
Entitlements-Konflikt.

**App startet auf anderem Mac trotzdem nicht:**
Quarantine-Attribut prüfen: `xattr /Applications/ClaudeLauncher.app` — sollte
`com.apple.quarantine` zeigen, weil aus dem Internet geladen. Wenn `spctl
--assess --type execute /Applications/ClaudeLauncher.app` erfolgreich ist und
die App trotzdem nicht startet, ist die Notarization unvollständig.
