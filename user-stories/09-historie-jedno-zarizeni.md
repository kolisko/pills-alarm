# Historie - jedno zařízení

## Cíl
Uživatel chce na zařízení, které právě používá, vidět dostupná cloudová potvrzení a přeskočení.

## Předpoklady
Existuje alespoň jedno potvrzení nebo přeskočení dávky.

`Historie` je odvozený pohled nad aktuálními potvrzeními a přeskočeními v dostupných CloudKit prostorech, ne append-only audit log.

Tento scénář řeší zobrazení aktuální historie na tomto zařízení. Propsání nových potvrzení nebo přeskočení na další zařízení řeší `private sync` nebo `shared sync`.

## Scénář
1. Uživatel otevře `Historie`.
2. Aplikace načte potvrzení z dostupných CloudKit prostorů.
3. Aplikace spojí potvrzení nebo přeskočení s dávkou podle stabilní identity dávkovacího slotu a konkrétního dne.
4. Aplikace zobrazí záznamy od nejnovějšího po nejstarší.
5. Uživatel vidí stav dávky, množství, plánovaný čas a čas potvrzení.
6. Pokud záznam pochází ze sdíleného prostoru, aplikace zobrazí ikonu sdílení.

## Očekávaný výsledek
Historie odpovídá potvrzením uloženým v CloudKitu, rozlišuje osobní a sdílené záznamy a nepáruje je podle názvu léku nebo času.

## Chybové stavy
- Pokud historie nejde načíst, aplikace zobrazí chybu.
- Pokud historie neobsahuje žádné záznamy, aplikace zobrazí prázdný stav.
- Pokud záznam nemá dostupné jméno člena, aplikace ho zobrazí bez jména.
- Pokud byl plán nebo dávkovací slot smazaný, odpovídající potvrzení nebo přeskočení se v běžné `Historii` nezobrazí.
