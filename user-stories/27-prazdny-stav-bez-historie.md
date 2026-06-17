# Prázdný stav bez historie

## Cíl
Uživatel chce při otevření historie vidět, že zatím nebyla podána ani přeskočena žádná dávka.

## Předpoklady
Aplikace má načtený CloudKit stav a v dostupných prostorech neexistují žádná aktuální potvrzení ani přeskočení.

## Scénář
1. Uživatel otevře `Historie`.
2. Aplikace načte osobní i sdílená potvrzení.
3. Aplikace zjistí, že běžná `Historie` nemá žádný aktuální záznam odvozený z CloudKitu.
4. Aplikace zobrazí prázdný stav `Zatím žádná historie`.
5. Uživatel se vrátí do `Dnes`.
6. Uživatel podá nebo přeskočí dávku.
7. Uživatel znovu otevře `Historie`.
8. Aplikace zobrazí nově vzniklé potvrzení nebo přeskočení.

## Očekávaný výsledek
Prázdná historie je jasný stav, ne chyba nebo ztráta dat. Vrácená potvrzení, přeskočení a stavy patřící ke smazanému plánu nebo dávkovacímu slotu se v běžné historii nezobrazují.

## Chybové stavy
- Pokud historie nejde načíst, aplikace zobrazí chybu.
- Pokud existují jen sdílené záznamy, aplikace je zobrazí s ikonou sdílení.
- Pokud potvrzení selhalo při zápisu, historie se o něj nerozšíří.
