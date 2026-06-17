# Přihlášení k iCloudu

## Cíl
Uživatel chce aplikaci používat jen nad reálnými cloudovými daty, aby nevznikl falešně prázdný nebo lokální stav.

## Předpoklady
Na zařízení není přihlášený iCloud účet, nebo iCloud není pro aplikaci dostupný.

## Scénář
1. Uživatel spustí aplikaci.
2. Aplikace ověří stav iCloud účtu v systému.
3. Systém vrátí, že iCloud není dostupný.
4. Aplikace nenačte prázdný plán jako náhradní stav.
5. Uživatel vidí obrazovku `iCloud` s vysvětlením, že plán, historie, alarmy a sdílení vyžadují iCloud.
6. Uživatel otevře systémové Nastavení, přihlásí se k Apple účtu a vrátí se do aplikace.
7. Aplikace znovu ověří iCloud.
8. Aplikace načte osobní úložiště a dostupná sdílená úložiště.
9. Uživatel vidí běžné záložky aplikace.

## Očekávaný výsledek
Aplikace nepokračuje bez iCloudu a po přihlášení načte skutečný CloudKit stav.

## Chybové stavy
- Pokud je iCloud omezený, aplikace zobrazí srozumitelnou chybu.
- Pokud je zařízení offline a nemá načtený poslední známý stav, aplikace vysvětlí, že je potřeba internet.
- Pokud zařízení offline poslední známý stav má, aplikace ho může zobrazit s varováním, ale zakáže akce zapisující do iCloudu.
- Pokud je iCloud dočasně nedostupný, aplikace nabídne opakování.
