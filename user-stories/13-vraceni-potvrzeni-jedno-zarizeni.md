# Vrácení potvrzení - jedno zařízení

## Cíl
Uživatel chce opravit omylem potvrzenou nebo přeskočenou dávku.

## Předpoklady
V `Dnes` existuje dávka ve stavu `Podáno` nebo `Přeskočeno`.

Tento scénář řeší okamžitý dopad na aktuálním zařízení po úspěšném CloudKit zápisu. Propsání na další zařízení řeší `private sync` nebo `shared sync` podle prostoru, ze kterého dávka pochází.

## Scénář
1. Uživatel otevře `Dnes`.
2. Aplikace zobrazí dávku jako podanou nebo přeskočenou.
3. Uživatel klepne na `Zpět`.
4. Aplikace smaže cloudový stav `Podáno` nebo `Přeskočeno` pro stabilní identitu této dávky z CloudKitu.
5. Aplikace zobrazí dávku znovu jako nepodanou.
6. Aplikace po přepočtu přestane odpovídající záznam zobrazovat v běžné `Historii`.
7. Aplikace přepočítá lokální alarmy podle toho, jestli dávka ještě má upozorňovat.
8. Uživatel může dávku znovu podat nebo přeskočit.

## Očekávaný výsledek
Vrácení potvrzení odstraní cloudový stav dávky, UI se vrátí do nepodaného stavu a běžná `Historie` už vrácené potvrzení nebo přeskočení nezobrazuje.

## Chybové stavy
- Pokud smazání z CloudKitu selže, dávka zůstane potvrzená nebo přeskočená.
- Pokud už jiná úspěšná cloudová akce změnila stav stejné dávky, aplikace po reloadu zobrazí aktuální stav a nepředstírá lokální vrácení.
- Pokud dávka už patří do minulosti, aplikace ji může zobrazit jako nepodanou bez nového alarmu podle pravidel plánování.
- Pokud dávka pochází ze sdíleného prostoru, který není dostupný, aplikace zobrazí chybu.
