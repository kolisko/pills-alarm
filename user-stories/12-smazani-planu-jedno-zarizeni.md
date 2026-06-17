# Smazání plánu - jedno zařízení

## Cíl
Uživatel chce odstranit lék, který už nemá být v plánu.

## Předpoklady
Existuje osobní plán uložený v CloudKitu.

Tento scénář řeší okamžitý dopad na aktuálním zařízení po úspěšném CloudKit zápisu. Propsání na další zařízení řeší `private sync`.

## Scénář
1. Uživatel otevře `Plán`.
2. Aplikace zobrazí seznam léků.
3. Uživatel smaže osobní plán.
4. Aplikace požádá o potvrzení, pokud jde o destruktivní akci.
5. Uživatel smazání potvrdí.
6. Aplikace smaže plán z CloudKitu.
7. Aplikace smaže potvrzení a přeskočení patřící k tomuto plánu z běžné `Historie`.
8. Aplikace odstraní plán ze seznamu `Plán`.
9. Aplikace odstraní budoucí dávky tohoto léku z `Dnes`.
10. Aplikace zruší nebo přepočítá lokální alarmy související s tímto plánem.
11. Uživatel už plán v aplikaci nevidí.

## Očekávaný výsledek
Smazaný plán se po reloadu z CloudKitu nevrátí, jeho běžná historie se už nezobrazuje a jeho budoucí alarmy už nejsou naplánované.

## Chybové stavy
- Pokud smazání v CloudKitu selže, plán zůstane viditelný.
- Pokud uživatel potvrzení zruší, nic se nesmaže.
- Pokud je plán sdílený a uživatel není vlastník, nejde ho smazat jako vlastní.
