# Opakování pozvánky

## Cíl
Uživatel chce znovu pozvat člověka do existující skupiny.

## Předpoklady
Existuje skupina a uživatel je jejím vlastníkem.

## Scénář
1. Uživatel otevře `Skupina`.
2. Klepne na `Pozvat přes iCloud`.
3. Aplikace použije existující CloudKit share skupiny nebo ho bezpečně znovu připraví.
4. Systém zobrazí okno pro odeslání pozvánky.
5. Pozvaný uživatel může pozvánku přijmout.

## Očekávaný výsledek
Opakované odeslání pozvánky nevytvoří duplicitní skupinu ani automaticky nenasdílí soukromé plány.

## Chybové stavy
- Pokud existující share nejde načíst, aplikace zobrazí chybu.
- Pokud uživatel odeslání zruší, stav skupiny se nezmění.
