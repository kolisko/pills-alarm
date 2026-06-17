# Úprava plánu - jedno zařízení

## Cíl
Uživatel chce upravit existující plán léku a hned vidět dopad na tomto zařízení.

## Předpoklady
Existuje osobní plán uložený v CloudKitu a aplikace je online.

Tento scénář řeší okamžitý dopad na aktuálním zařízení po úspěšném CloudKit zápisu. Propsání na další zařízení řeší `private sync`.

## Scénář
1. Uživatel otevře `Plán`.
2. Aplikace zobrazí existující léky.
3. Uživatel otevře osobní plán.
4. Aplikace otevře editor plánu.
5. Uživatel změní název, čas, množství dávky nebo fázi.
6. Uživatel klepne na `Uložit`.
7. Aplikace uloží změněný plán do CloudKitu.
8. Aplikace zavře editor a aktualizuje seznam `Plán`.
9. Aplikace přepočítá dávky v `Dnes`.
10. Aplikace zachová stabilní identitu existujících dávkovacích slotů, pokud je uživatel jen upravil.
11. Aplikace přeplánuje lokální alarmy podle nového plánu.
12. Uživatel vidí upravený plán a aktualizované dávky.

## Očekávaný výsledek
Změna plánu se po uložení neztratí po reloadu a lokální alarmy odpovídají nové verzi plánu.

## Chybové stavy
- Pokud uložení selže, editor zůstane otevřený.
- Pokud změna odstraní dávku pro aktuální den, dávka zmizí z `Dnes`.
- Pokud uživatel smaže dávkovací slot, aplikace odstraní jeho budoucí dávky, alarmy a odpovídající potvrzení nebo přeskočení z běžné `Historie`.
- Pokud je plán sdílený a uživatel není vlastník, editor je jen pro čtení.
