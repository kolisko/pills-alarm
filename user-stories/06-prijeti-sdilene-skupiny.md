# Přijetí sdílené skupiny

## Cíl
Pozvaný uživatel chce přijmout iCloud pozvánku do skupiny a vidět plány, které jejich vlastníci do skupiny přidali.

## Předpoklady
Vlastník skupiny odeslal iCloud pozvánku a pozvaný uživatel má aplikaci nainstalovanou.

## Scénář
1. Pozvaný uživatel otevře iCloud pozvánku.
2. Systém předá pozvánku aplikaci.
3. Aplikace přijme CloudKit share skupiny.
4. Aplikace načte skupinové úložiště.
5. Uživatel otevře `Skupina`.
6. Aplikace vyzve uživatele k vyplnění jeho jména ve skupině.
7. Uživatel jméno uloží.
8. Aplikace zobrazí členy skupiny a plány, které už byly do skupiny přidány.

## Očekávaný výsledek
Pozvaný člen vidí jen plány výslovně sdílené do skupiny. Bez vyplněného jména nemůže potvrzovat ani přeskakovat sdílené dávky.

## Chybové stavy
- Pokud přijetí pozvánky selže, aplikace zobrazí chybu.
- Pokud shared úložiště nejde načíst, osobní úložiště zůstane dostupné.
- Pokud uživatel nevyplní jméno, sdílené potvrzování zůstane zamčené.
