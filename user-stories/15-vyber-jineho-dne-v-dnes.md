# Výběr jiného dne v Dnes

## Cíl
Uživatel chce zkontrolovat dávky pro včerejšek, zítřek nebo jiné datum a přitom jasně vidět, že není na dnešku.

## Předpoklady
Aplikace má načtené plány a uživatel je v záložce `Dnes`.

## Scénář
1. Uživatel otevře `Dnes`.
2. Aplikace zobrazí dávky pro dnešní den a nadpis `Dnes`.
3. Uživatel vybere jiné datum.
4. Aplikace změní nadpis podle vybraného dne, například `Včera`, `Zítra`, `Pozítří` nebo datum.
5. Aplikace zobrazí výrazný prvek s informací, že je vybraný jiný den.
6. Aplikace zobrazí dávky pro vybraný den.
7. Uživatel klepne na tlačítko `Dnes`.
8. Aplikace vrátí výběr na aktuální den.
9. Uživatel znovu vidí dnešní dávky.

## Očekávaný výsledek
Uživatel se nemůže splést, jestli sleduje dnešek nebo jiné datum.

## Chybové stavy
- Pokud pro vybraný den nejsou žádné dávky, aplikace zobrazí prázdný stav pro tento den.
- Potvrzení dávky se vždy vztahuje k vybranému konkrétnímu dni.
- Alarmy se neplánují podle toho, že uživatel pouze prohlíží jiné datum.
