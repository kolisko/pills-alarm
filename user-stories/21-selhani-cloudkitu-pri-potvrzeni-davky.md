# Selhání CloudKitu při potvrzení dávky

## Cíl
Uživatel má jasně vidět, že dávka nebyla potvrzena, pokud CloudKit zápis selže.

## Předpoklady
V `Dnes` existuje nepodaná dávka a během potvrzení selže CloudKit.

## Scénář
1. Uživatel otevře `Dnes`.
2. Uživatel klepne na `Podat` nebo `Přeskočit`.
3. Aplikace odešle potvrzení do CloudKitu.
4. CloudKit vrátí chybu.
5. Aplikace nezmění dávku na definitivně podanou nebo přeskočenou.
6. Aplikace zobrazí centrální chybu.
7. Uživatel vidí původní stav dávky.
8. Uživatel může akci opakovat po obnovení připojení nebo iCloudu.

## Očekávaný výsledek
Potvrzení dávky je platné až po úspěšném zápisu do CloudKitu.

## Chybové stavy
- Pokud zápis selže, historie se nerozšíří o falešný záznam.
- Pokud zápis selže, alarmy se nepřepočítají jako po úspěšném potvrzení.
- Pokud jde o sdílené úložiště, chyba neovlivní osobní plány.
