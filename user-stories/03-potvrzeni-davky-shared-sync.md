# Potvrzení dávky - shared sync

## Cíl
Člen sdílené skupiny chce potvrdit dávku tak, aby ostatní členové viděli, že už byla podaná.

## Předpoklady
Uživatel A a uživatel B jsou členové stejné sdílené skupiny a oba mají ve skupině vyplněné svoje jméno.

## Scénář
1. Uživatel A otevře `Dnes`.
2. Aplikace zobrazí sdílenou dávku s ikonou sdílení.
3. Uživatel A klepne na `Podat`.
4. Aplikace zapíše potvrzení pro stabilní identitu sdílené dávky do skupinové úložištěu vlastníka.
5. Aplikace uživatele A označí dávku jako podanou a přeplánuje jeho lokální alarmy.
6. Aplikace uživatele B dostane synchronizační příležitost.
7. Aplikace uživatele B načte skupinové úložiště.
8. Aplikace uživatele B najde potvrzení stejné sdílené dávky podle její stabilní identity.
9. Uživatel B vidí dávku jako podanou a vidí jméno člena, který ji potvrdil.
10. Aplikace uživatele B zruší zastaralé alarmy pro tuto dávku.

## Očekávaný výsledek
Jedno potvrzení ve sdíleném prostoru platí pro všechny členy skupiny a jejich zařízení po synchronizaci.

## Chybové stavy
- Pokud uživatel B není online, potvrzení uvidí až po dalším reloadu.
- Pokud uživatel A nemá vyplněné jméno ve skupině, aplikace mu potvrzení nedovolí.
- Pokud jiný člen mezitím úspěšně zapsal pro stejnou dávku jiný stav, první úspěšný cloudový stav vyhrává.
- Pokud shared sync selže, aplikace zobrazí chybu, ale osobní data zůstanou dostupná.
