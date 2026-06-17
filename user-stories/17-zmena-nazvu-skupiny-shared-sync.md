# Změna názvu skupiny - shared sync

## Cíl
Uživatel chce změnit název sdílené skupiny tak, aby ostatní členové po synchronizaci viděli stejný název.

## Předpoklady
Existuje sdílená skupina a uživatel A je podle `00-pravidla-a-slovnik.md` vlastník.

## Scénář
1. Uživatel A otevře `Skupina`.
2. Aplikace zobrazí název skupiny.
3. Uživatel A změní název skupiny.
4. Uživatel A klepne na `Uložit`.
5. Aplikace uloží nový název do CloudKitu.
6. Aplikace uživatele A zobrazí nový název.
7. Uživatel B provede synchronizaci.
8. Aplikace uživatele B načte skupinové úložiště.
9. Uživatel B vidí nový název skupiny.

## Očekávaný výsledek
Název skupiny je jeden společný cloudový údaj a po synchronizaci je stejný pro všechny členy.

## Chybové stavy
- Pokud uživatel není vlastník, aplikace změnu neuloží.
- Pokud uložení selže, ostatní členové starý název nezmění.
- Pokud člen není online, nový název uvidí až po dalším reloadu.
