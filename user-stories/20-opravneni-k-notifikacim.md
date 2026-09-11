# Oprávnění k AlarmKitu

## Cíl
Uživatel chce vědět, jestli aplikace skutečně může upozorňovat na dávky zvukem.

## Předpoklady
Aplikace je nainstalovaná na iOS 26 nebo novějším a uživatel ještě nepovolil AlarmKit, nebo ho později zakázal v systému.

## Scénář
1. Uživatel otevře `Nastavení` > `Nastavení alarmů` a zapne `AlarmKit`.
2. Aplikace požádá o oprávnění k AlarmKitu, pokud ještě nebylo rozhodnuto. O oprávnění k lokálním notifikacím nežádá.
3. Uživatel oprávnění povolí nebo odmítne.
4. Uživatel otevře `Nastavení` > `Alarmy`.
5. Aplikace zobrazí lokální zapnutí alarmů a stav systémového oprávnění AlarmKit.
6. Pokud uživatel oprávnění odmítl, přepínač zůstane vypnutý a aplikace zobrazí chybu.
7. Uživatel může otevřít systémové Nastavení a oprávnění změnit.
8. Po změně systémového oprávnění uživatel znovu zapne přepínač; audit načte aktuální stav při otevření nebo obnovení.

## Očekávaný výsledek
Uživatel má jasnou informaci, jestli alarmy mohou fungovat, a aplikace nevytváří falešný pocit bezpečí.

## Chybové stavy
- Pokud je AlarmKit zakázaný, aplikace to zobrazí v auditu alarmů a při pokusu o plánování ukáže chybu.
- Pokud uživatel později zruší oprávnění v systému, aplikace nepřejde na lokální notifikace.
- Na iOS starším než 26 je přepínač nedostupný a alarmy jsou vypnuté.
