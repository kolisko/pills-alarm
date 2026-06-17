# Smazání plánu - shared sync

## Cíl
Vlastník chce odstranit sdílený plán pro všechny členy sdílení.

## Předpoklady
Existuje sdílený plán a uživatel A je vlastník tohoto plánu.

## Scénář
1. Uživatel A otevře `Plán`.
2. Uživatel A smaže sdílený plán.
3. Aplikace požádá o potvrzení destruktivní akce.
4. Uživatel A smazání potvrdí.
5. Aplikace smaže plán ze skupinového úložiště.
6. Aplikace uživatele A odstraní plán, dávky, odpovídající běžnou historii a související budoucí alarmy.
7. Uživatel B provede synchronizaci.
8. Aplikace uživatele B načte skupinové úložiště.
9. Aplikace uživatele B odstraní smazaný plán, dávky, odpovídající běžnou historii a související budoucí alarmy.

## Očekávaný výsledek
Sdílený plán po smazání zmizí všem členům po jejich synchronizaci včetně jeho běžné historie.

## Chybové stavy
- Pokud uživatel není vlastník plánu, aplikace smazání ani odebrání ze skupiny nenabídne nebo ho odmítne.
- Pokud smazání selže, plán zůstane viditelný.
- Pokud člen není online, změnu uvidí po dalším úspěšném reloadu.
