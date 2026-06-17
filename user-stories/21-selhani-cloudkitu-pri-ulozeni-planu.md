# Selhání CloudKitu při uložení plánu

## Cíl
Uživatel má jasně vidět, že plán nebyl uložen, pokud CloudKit zápis selže.

## Předpoklady
Uživatel upravuje nebo vytváří plán a během ukládání selže síť, iCloud nebo CloudKit.

## Scénář
1. Uživatel otevře editor plánu.
2. Uživatel provede změnu.
3. Uživatel klepne na `Uložit`.
4. Aplikace odešle zápis do CloudKitu.
5. CloudKit vrátí chybu.
6. Aplikace nezavře editor jako úspěšně uložený.
7. Aplikace zobrazí centrální chybu.
8. Uživatel může chybu opravit, počkat nebo zkusit uložit znovu.
9. Aplikace nezmění plán v seznamu tak, aby vypadal definitivně uložený.

## Očekávaný výsledek
Selhaný zápis se nepředstírá jako úspěch a CloudKit zůstává jediný zdroj pravdy.

## Chybové stavy
- Pokud je iCloud odhlášený, aplikace zobrazí výzvu k přihlášení.
- Pokud je síť nedostupná, aplikace zobrazí chybu připojení.
- Pokud CloudKit odmítne schéma nebo oprávnění, aplikace zobrazí konkrétní chybu pro testera.
