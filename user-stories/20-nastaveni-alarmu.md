# Nastavení alarmů

## Cíl
Uživatel chce zapnout nebo vypnout AlarmKit a upravit pravidla opakovacích alarmů bez změny samotného plánu léků.

## Předpoklady
Pro zapnutí alarmů je potřeba iOS 26 nebo novější a oprávnění AlarmKit. Vypnout alarmy lze i bez oprávnění nebo dostupného iCloudu.

## Scénář
1. Uživatel otevře `Nastavení`.
2. Uživatel otevře `Nastavení alarmů`.
3. Aplikace zobrazí přepínač `AlarmKit`, test alarmu, interval opakování, délku série a počet nejbližších časů podání se sérií.
4. Uživatel zapne `AlarmKit` a případně povolí systémové oprávnění.
5. Aplikace uloží nastavení do tohoto zařízení a naplánuje aktuální alarmy.
6. Uživatel změní interval nebo délku opakovací série; aplikace alarmy přepočítá.
7. Uživatel může naplánovat test za jednu minutu bez zrušení běžných alarmů.
8. Uživatel vypne `AlarmKit`.
9. Aplikace uloží vypnutý stav a zruší všechny své alarmy včetně testu i případné staré lokální notifikace.
10. Po návratu z pozadí, restartu a synchronizaci zůstávají alarmy vypnuté. Testovací tlačítko je nedostupné.
11. Uživatel otevře `Alarmy` a ověří vypnutý stav a prázdný seznam čekajících alarmů.

## Očekávaný výsledek
Upozornění používají pouze AlarmKit, nebo jsou vypnutá. Nastavení platí jen pro toto zařízení; plány, potvrzení, sdílení a synchronizace se nemění. Aktualizace zachová zapnutý stav dosavadním uživatelům AlarmKitu. Nová instalace a původní režim lokálních notifikací začínají s alarmy vypnutými.

## Chybové stavy
- Pokud uživatel nastaví hodnotu mimo povolený rozsah, aplikace ji omezí na platnou mez.
- Pokud přeplánování selže, aplikace zobrazí chybu.
- Pokud zrušení některého alarmu selže, vypnutý stav zůstane uložený, aplikace zobrazí chybu a zrušení zopakuje při návratu nebo přeplánování.
- Pokud je oprávnění zamítnuté nebo AlarmKit není dostupný, zapnutí se neprovede a nevzniknou náhradní lokální notifikace.
- Pokud nejsou žádné budoucí dávky, změna nastavení nezobrazí žádné čekající alarmy.
