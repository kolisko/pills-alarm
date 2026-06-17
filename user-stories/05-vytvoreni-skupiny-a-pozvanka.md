# Vytvoření skupiny a pozvánka

## Cíl
Uživatel chce vytvořit skupinu lidí, se kterými později může sdílet jednotlivé plány.

## Předpoklady
Uživatel je přihlášený k iCloudu a aplikace má dostupný CloudKit.

## Scénář
1. Uživatel otevře `Skupina`.
2. Zadá název skupiny a svoje jméno.
3. Aplikace vytvoří samostatné skupinové úložiště a uloží profil aktuálního uživatele.
4. Soukromé plány uživatele zůstanou v osobním úložišti a nejsou automaticky sdílené.
5. Uživatel klepne na `Pozvat přes iCloud`.
6. Aplikace připraví CloudKit share skupiny.
7. Systém zobrazí okno pro odeslání iCloud pozvánky.

## Očekávaný výsledek
Pozvánka odkazuje na skupinové úložiště. Skupina sama o sobě nenasdílí žádný plán, dokud vlastník konkrétní plán do skupiny nepřidá.

## Chybové stavy
- Pokud chybí název skupiny nebo moje jméno, aplikace nedovolí skupinu vytvořit.
- Pokud CloudKit share nejde připravit, aplikace zobrazí chybu.
- Pokud systémové okno pozvánky selže nebo ho uživatel zruší, aplikace netvrdí, že pozvánka byla odeslána.
