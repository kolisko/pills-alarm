# Úprava plánu - shared sync

## Cíl
Vlastník chce změnit sdílený plán tak, aby se změna propsala všem členům skupiny.

## Předpoklady
Existuje skupina, sdílený plán a uživatel A je vlastník tohoto plánu.

## Scénář
1. Uživatel A otevře sdílený plán.
2. Aplikace zobrazí, že jde o sdílený plán.
3. Uživatel A změní čas, dávkování nebo fázi.
4. Aplikace uloží změnu do skupinového úložiště.
5. Aplikace uživatele A aktualizuje `Plán`, `Dnes` a alarmy.
6. Uživatel B provede synchronizaci.
7. Aplikace uživatele B načte skupinové úložiště.
8. Uživatel B vidí upravený plán s ikonou sdílení.
9. Aplikace uživatele B zachová identitu upravených dávkovacích slotů a nepřepáruje stará potvrzení nebo přeskočení podle nového času.
10. Aplikace uživatele B přepočítá sdílené dávky a alarmy.

## Očekávaný výsledek
Změna sdíleného plánu je po synchronizaci společná pro všechny členy skupiny.

## Chybové stavy
- Pokud uživatel není vlastník plánu, aplikace mu zobrazí plán jen pro čtení.
- Pokud uložení selže, plán se ostatním členům nezmění.
- Pokud člen není online, změnu uvidí po dalším úspěšném reloadu.
- Pokud vlastník smaže dávkovací slot, členové po synchronizaci odstraní jeho budoucí dávky, alarmy a odpovídající běžnou historii.
