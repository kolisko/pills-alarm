# Prázdný stav bez dávek pro den

## Cíl
Uživatel chce při prohlížení dne bez dávek jasně vidět, že pro daný den není nic naplánováno.

## Předpoklady
Aplikace má načtené plány a pro vybraný den nevychází žádná dávka větší než `0`.

## Scénář
1. Uživatel otevře `Dnes`.
2. Aplikace zobrazí vybraný den.
3. Pro vybraný den neexistuje žádná dávka.
4. Aplikace zobrazí prázdný stav `Na tento den nejsou naplánované dávky`.
5. Uživatel změní datum na den, kdy dávky existují.
6. Aplikace zobrazí dávky pro nově vybraný den.

## Očekávaný výsledek
Uživatel pozná rozdíl mezi dnem bez dávek a chybou načtení.

## Chybové stavy
- Pokud reload selže, aplikace zobrazí chybu synchronizace.
- Pokud je vybraný jiný než dnešní den, aplikace to jasně označí.
- Pokud je dávka nastavená na `0`, nezobrazuje se jako dávka k podání.
