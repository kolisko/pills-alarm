# Pozvánka selže nebo je prázdná

## Cíl
Uživatel chce jasně vědět, že pozvánka do skupiny nebyla odeslaná, pokud systémové sdílení selže.

## Předpoklady
Uživatel vlastní skupinu a klepne na `Pozvat přes iCloud`.

## Scénář
1. Aplikace připraví CloudKit share skupiny.
2. Systém se pokusí otevřít okno pro odeslání pozvánky.
3. Systémové okno selže, je prázdné, nebo uložení sdílení selže.
4. Aplikace zobrazí srozumitelnou chybu.
5. Uživatel zůstane na obrazovce `Skupina`.

## Očekávaný výsledek
Aplikace nepředstírá úspěšné odeslání pozvánky a nemění sdílení žádného plánu.

## Chybové stavy
- Pokud CloudKit share nejde připravit, systémové okno se neotevře jako úspěšné.
- Pokud uživatel sdílení zruší, aplikace nehlásí chybu ani úspěšné pozvání.
