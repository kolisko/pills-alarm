# Prázdný stav bez plánu

## Cíl
Nový uživatel chce pochopit, že zatím nemá vytvořený žádný plán a jak ho založit.

## Předpoklady
Uživatel je přihlášený k iCloudu a neexistuje žádný dostupný osobní ani sdílený plán.

## Scénář
1. Uživatel otevře aplikaci.
2. Aplikace načte iCloud a zjistí, že neexistuje žádný dostupný osobní ani sdílený plán.
3. Uživatel otevře `Plán`.
4. Aplikace zobrazí prázdný stav, že zatím není vytvořený žádný plán.
5. Uživatel vidí tlačítko `+`.
6. Uživatel klepne na `+`.
7. Aplikace otevře editor nového plánu.

## Očekávaný výsledek
Prázdný stav nevypadá jako chyba synchronizace a uživatel má jasnou cestu k vytvoření prvního plánu.

## Chybové stavy
- Pokud iCloud není dostupný, aplikace nezobrazí prázdný plán jako skutečný stav.
- Pokud reload selže, aplikace zobrazí chybu místo zavádějícího prázdného stavu.
- Pokud uživatel přijme sdílení, prázdný stav zmizí po synchronizaci sdílených plánů.
