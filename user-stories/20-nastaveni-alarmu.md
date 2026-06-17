# Nastavení alarmů

## Cíl
Uživatel chce upravit pravidla opakovacích alarmů bez změny samotného plánu léků.

## Předpoklady
Aplikace má povolené notifikace a existují budoucí dávky.

## Scénář
1. Uživatel otevře `Nastavení`.
2. Uživatel otevře `Nastavení alarmů`.
3. Aplikace zobrazí interval opakování, délku série a počet nejbližších dávek se sérií.
4. Uživatel změní interval nebo délku opakovací série.
5. Aplikace uloží nové nastavení.
6. Aplikace přepočítá lokální alarmy podle nového nastavení.
7. Uživatel otevře `Alarmy`.
8. Aplikace zobrazí čekající alarmy odpovídající novému nastavení.

## Očekávaný výsledek
Změna nastavení alarmů se projeví v lokálně naplánovaných alarmových sériích bez nutnosti upravit plán léku.

## Chybové stavy
- Pokud uživatel nastaví hodnotu mimo povolený rozsah, aplikace ji omezí na platnou mez.
- Pokud přeplánování selže, aplikace zobrazí chybu.
- Pokud nejsou žádné budoucí dávky, změna nastavení nezobrazí žádné čekající alarmy.
