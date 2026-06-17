# Přeskočení dávky - shared sync

## Cíl
Člen skupiny chce označit dávku jako přeskočenou, aby ostatní členové věděli, že ji nemají podávat.

## Předpoklady
Existuje nepodaná sdílená dávka a uživatel má ve skupině vyplněné jméno.

## Scénář
1. Uživatel otevře `Dnes`.
2. Aplikace zobrazí sdílenou dávku.
3. Uživatel klepne na `Přeskočit`.
4. Aplikace zobrazí potvrzovací dialog.
5. Uživatel potvrdí přeskočení.
6. Aplikace zapíše stav `Přeskočeno` pro stabilní identitu dávky do skupinové úložištěu vlastníka.
7. Aplikace lokálně zobrazí dávku jako přeskočenou.
8. Aplikace přeplánuje lokální alarmy.
9. Ostatní členové po synchronizaci vidí dávku jako přeskočenou.
10. Ostatní členové vidí jméno člena, který dávku přeskočil.

## Očekávaný výsledek
Přeskočení dávky je ve sdílené skupině společný stav, který po synchronizaci zastaví další lokální upozornění.

## Chybové stavy
- Pokud uživatel zruší dialog, nic se nezapíše.
- Pokud zápis selže, dávka zůstane nepodaná.
- Pokud jiný člen mezitím úspěšně zapsal pro stejnou dávku jiný stav, první úspěšný cloudový stav vyhrává.
- Pokud jiné zařízení ještě není sesynchronizované, může krátce zobrazovat starý stav.
