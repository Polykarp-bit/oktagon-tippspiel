# Oktagon Tippspiel: Einrichtung (ca. 10 Minuten, kostenlos)

Die App besteht aus zwei Dateien:

- `index.html`: die Web-App (läuft auf GitHub Pages)
- `supabase.sql`: die Datenbank (läuft kostenlos bei Supabase)

Eine Datenbank braucht es, weil GitHub Pages nur statische Seiten kann. Sonst würde jeder nur seine eigenen Tipps sehen.

## 1. Datenbank bei Supabase anlegen

1. Auf https://supabase.com kostenlos registrieren (geht mit dem GitHub-Konto) und **New project** anlegen. Region: Frankfurt.
2. Links **SQL Editor** öffnen, **New query**.
3. Den kompletten Inhalt von `supabase.sql` einfügen.
4. **Run** klicken. Es sollte "Success" erscheinen.
5. Unter **Project Settings > API** (bzw. **API Keys**) zwei Werte kopieren:
   - **Project URL**, z. B. `https://abcdefgh.supabase.co`
   - den **anon public**-Key (oder den **publishable**-Key `sb_publishable_...`)

   Nicht den `service_role`/`secret`-Key nehmen! Der anon-Key darf öffentlich in der Seite stehen. Die Datenbank lässt mit ihm nur die Funktionen der App zu.

## 2. Werte in die App eintragen

Ganz oben in `index.html` die zwei Zeilen anpassen:

```js
const SUPABASE_URL = "https://abcdefgh.supabase.co";
const SUPABASE_KEY = "eyJ...";   // anon- oder publishable-Key
```

## 3. Auf GitHub Pages veröffentlichen

1. Auf GitHub ein neues **öffentliches** Repository anlegen, z. B. `oktagon-tippspiel`.
2. **Add file > Upload files** und `index.html` hochladen.
3. **Settings > Pages**: Source **Deploy from a branch**, Branch `main`, Ordner `/ (root)`, **Save**.
4. Nach ca. 1 Minute läuft die App unter `https://DEIN-NAME.github.io/oktagon-tippspiel/`.

## 4. Am Abend (kein Admin nötig)

- **Freunde einladen:** In der App den Tab **Einladen** öffnen. Dort ist der QR-Code. Jeder wählt Name und eine 4-stellige PIN. Mit derselben Kombi kommt man auch von einem anderen Handy wieder rein.
- **Kampf beginnt:** Irgendwer drückt auf der Karte **"Kampf beginnt – Tipps sperren"**. Ab dann sind die Tipps fix, und alle sehen, wer wen getippt hat. Zu früh gedrückt? Nach dem Sperren bleiben die Tipps noch 2 Minuten verdeckt. In dieser Zeit können 2 verschiedene Mitspieler die Sperre gemeinsam aufheben. Danach ist die Sperre endgültig. Weder die App noch jemand mit dem öffentlichen Schlüssel kann den Kampf dann wieder öffnen oder Tipps ändern, das verhindert die Datenbank selbst.
- **Kampf vorbei:** Jeder kann den Sieger bestätigen (oder **Unentschieden/NC**). Das Ergebnis gilt, sobald mehr als die Hälfte der Tipper dieses Kampfes dasselbe bestätigt hat. Bei 5 Tippern braucht es also 3 gleiche Stimmen. Die eigene Stimme lässt sich ändern. Wurde versehentlich falsch bestätigt, korrigiert die Mehrheit das.
- **Fight Card geändert?** Unten in der Liste unter "Kampf fehlt? Hinzufügen" einen Kampf ergänzen. Ein Kampf ohne Tipps lässt sich wieder entfernen.
- **Protokoll:** Jede Aktion (Tipp, Änderung, Sperren, Entsperren, Ergebnis) wird mit Uhrzeit gespeichert und kann nicht geändert werden. Sobald ein Kampf entschieden ist, sieht jeder das Protokoll auf der Kampfkarte.
- **Verdeckt-Zeit anpassen:** `update settings set value = '180' where key = 'grace_seconds';` (Sekunden).
- **Mehrheit anpassen:** In Supabase im SQL Editor z. B. `update settings set value = '0.66' where key = 'quorum';` ausführen. Dann braucht es mehr als zwei Drittel.

## Regeln (so rechnet die App)

- 10 € Einsatz pro getipptem Kampf. Man muss nicht jeden Kampf tippen.
- Die Verlierer-Einsätze werden gleichmäßig unter den Gewinnern aufgeteilt. Beispiel: 3 richtig, 2 falsch. Die Falschen bekommen je −10 €, die Richtigen je +6,67 €.
- Haben alle richtig oder alle falsch getippt, oder bei Unentschieden / No Contest: 0 € für alle.
- Die Summe aller Bilanzen ist immer 0 €. Am Ende zahlen die Minus-Leute an die Plus-Leute.

## Hinweise

- Die PIN ist nur ein Schutz unter Freunden. 4 Ziffern lassen sich mit etwas Aufwand durchprobieren. Für einen Abend mit Kumpels reicht das.
- Kostenlose Supabase-Projekte pausieren nach etwa einer Woche ohne Nutzung. Dann im Supabase-Dashboard einfach auf **Restore** klicken.
- Für einen neuen Abend: im SQL Editor `delete from votes; delete from bets; delete from fights; delete from players;` ausführen und neue Kämpfe in der App hinzufügen.
