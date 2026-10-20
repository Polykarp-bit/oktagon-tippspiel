# Oktagon Tippspiel: Einrichtung (ca. 10 Minuten, kostenlos)

Die App besteht aus zwei Dateien:

- `index.html`: die Web-App (läuft auf GitHub Pages)
- `supabase.sql`: die Datenbank (läuft kostenlos bei Supabase)

Eine Datenbank braucht es, weil GitHub Pages nur statische Seiten kann. Sonst würde jeder nur seine eigenen Tipps sehen.

## 1. Datenbank bei Supabase anlegen

1. Auf https://supabase.com kostenlos registrieren (geht mit dem GitHub-Konto) und **New project** anlegen. Region: Frankfurt.
2. Links **SQL Editor** öffnen, **New query**.
3. Den kompletten Inhalt von `supabase.sql` einfügen.
4. In Abschnitt 5 `HIER-ADMIN-PASSWORT` durch ein eigenes Admin-Passwort ersetzen.
5. **Run** klicken. Es sollte "Success" erscheinen.
6. Unter **Project Settings > API** (bzw. **API Keys**) zwei Werte kopieren:
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

## 4. Am Abend

- **Freunde einladen:** In der App den Tab **Einladen** öffnen. Dort ist der QR-Code. Jeder wählt Name und eine 4-stellige PIN. Mit derselben Kombi kommt man auch von einem anderen Handy wieder rein.
- **Admin-Modus:** Die Adresse mit `#admin` am Ende aufrufen, also `https://DEIN-NAME.github.io/oktagon-tippspiel/#admin`, und das Admin-Passwort eingeben. Dann gibt es den Tab **Admin**, und auf jeder Kampfkarte erscheinen Knöpfe.
- **Kampf beginnt:** Auf der Karte **"Kampf beginnt – sperren"** drücken. Ab dann sind die Tipps fix, und alle sehen, wer wen getippt hat.
- **Kampf vorbei:** Sieger antippen (oder **Unentschieden/NC**). Die Tabelle rechnet sofort neu.
- **Vertippt beim Eintragen?** Mit "Ergebnis zurücknehmen" oder "wieder öffnen" lässt sich alles korrigieren.
- **Kämpfe ändern:** Die Fight Card kann sich bis zum Abend noch ändern. Im Tab **Admin** lassen sich Kämpfe bearbeiten, hinzufügen und löschen.
- **Anmeldung schließen:** Geht im Tab **Admin**, wenn alle drin sind. Dann kann sich kein Fremder mehr anmelden.

## Regeln (so rechnet die App)

- 10 € Einsatz pro getipptem Kampf. Man muss nicht jeden Kampf tippen.
- Die Verlierer-Einsätze werden gleichmäßig unter den Gewinnern aufgeteilt. Beispiel: 3 richtig, 2 falsch. Die Falschen bekommen je −10 €, die Richtigen je +6,67 €.
- Haben alle richtig oder alle falsch getippt, oder bei Unentschieden / No Contest: 0 € für alle.
- Die Summe aller Bilanzen ist immer 0 €. Am Ende zahlen die Minus-Leute an die Plus-Leute.

## Hinweise

- Die PIN ist nur ein Schutz unter Freunden. 4 Ziffern lassen sich mit etwas Aufwand durchprobieren. Für einen Abend mit Kumpels reicht das.
- Kostenlose Supabase-Projekte pausieren nach etwa einer Woche ohne Nutzung. Dann im Supabase-Dashboard einfach auf **Restore** klicken.
- Für einen neuen Abend: im SQL Editor `delete from bets; delete from fights; delete from players;` ausführen und neue Kämpfe im Admin-Tab anlegen.
