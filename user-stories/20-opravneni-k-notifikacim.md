# Oprávnění k notifikacím

## Cíl
Uživatel chce vědět, jestli aplikace skutečně může upozorňovat na dávky zvukem.

## Předpoklady
Aplikace je nainstalovaná a uživatel ještě nepovolil notifikace, nebo je později vypnul v systému.

## Scénář
1. Uživatel spustí aplikaci.
2. Aplikace požádá o oprávnění k notifikacím, pokud ještě nebylo rozhodnuto.
3. Uživatel oprávnění povolí nebo odmítne.
4. Uživatel otevře `Nastavení` > `Alarmy`.
5. Aplikace zobrazí stav notifikací, zvuku a kritických upozornění.
6. Pokud notifikace nejsou povolené, aplikace ukáže, že alarmy nemohou spolehlivě upozorňovat.
7. Uživatel může otevřít systémové Nastavení a oprávnění změnit.
8. Po návratu aplikace znovu načte stav oprávnění.

## Očekávaný výsledek
Uživatel má jasnou informaci, jestli alarmy mohou fungovat, a aplikace nevytváří falešný pocit bezpečí.

## Chybové stavy
- Pokud jsou notifikace vypnuté, aplikace to zobrazí v auditu alarmů.
- Pokud zvuk není povolený, aplikace zobrazí, že alarm nemusí houkat.
- Pokud kritická upozornění nejsou dostupná, aplikace je neprezentuje jako aktivní.
