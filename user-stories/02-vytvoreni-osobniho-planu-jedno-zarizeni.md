# Vytvoření osobního plánu - jedno zařízení

## Cíl
Uživatel chce vytvořit plán léku a ihned ho vidět v aplikaci na zařízení, na kterém plán vytvořil.

## Předpoklady
Uživatel je přihlášený k iCloudu a aplikace má připravené osobní úložiště.

Tento scénář řeší okamžitý dopad na aktuálním zařízení po úspěšném CloudKit zápisu. Propsání na další zařízení řeší `private sync`.

## Scénář
1. Uživatel otevře `Plán`.
2. Aplikace zobrazí aktuální osobní a sdílené plány.
3. Uživatel klepne na `+`.
4. Aplikace otevře editor nového osobního plánu.
5. Uživatel zadá název léku, časy a dávky.
6. Uživatel klepne na `Uložit`.
7. Aplikace uloží plán do osobního CloudKit úložiště.
8. Aplikace po úspěšném uložení zavře editor.
9. Uživatel vidí nový plán v `Plán`.
10. Aplikace přepočítá `Dnes` a lokální alarmy.
11. Uživatel vidí dávky nového plánu v `Dnes`, pokud podle data a času existují.

## Očekávaný výsledek
Plán se po uložení neztratí ani po následném reloadu z CloudKitu.

## Chybové stavy
- Pokud zápis do CloudKitu selže, editor zůstane otevřený.
- Pokud plán nemá žádnou dávku větší než `0`, v `Dnes` se nezobrazí žádná dávka.
- Pokud iCloud není dostupný, aplikace plán neuloží do lokální náhrady.
