# Vrácení potvrzení - shared sync

## Cíl
Člen skupiny chce opravit potvrzení sdílené dávky tak, aby opravu viděli ostatní členové.

## Předpoklady
Ve sdílené skupině existuje dávka označená jako podaná nebo přeskočená.

Člen může vrátit vlastní potvrzení nebo přeskočení. Vrácení cizího potvrzení nebo přeskočení smí podle `00-pravidla-a-slovnik.md` jen vlastník.

## Scénář
1. Uživatel A otevře `Dnes`.
2. Uživatel A klepne u vlastní sdílené dávky na `Zpět`, nebo vlastník klepne na `Zpět` u dávky potvrzené či přeskočené jiným členem.
3. Aplikace smaže cloudový stav `Podáno` nebo `Přeskočeno` pro stabilní identitu dávky ze skupinové úložištěu vlastníka.
4. Aplikace uživatele A zobrazí dávku jako nepodanou.
5. Aplikace uživatele A přeplánuje lokální alarmy.
6. Uživatel B provede synchronizaci.
7. Aplikace uživatele B načte skupinové úložiště.
8. Aplikace uživatele B zjistí podle stabilní identity dávky, že cloudový stav už neexistuje.
9. Uživatel B vidí dávku jako nepodanou.
10. Aplikace uživatele B přeplánuje lokální alarmy.

## Očekávaný výsledek
Vrácení sdíleného potvrzení je společný stav skupiny, po synchronizaci se projeví všem členům a vrácené potvrzení se už nezobrazuje v běžné `Historii`.

## Chybové stavy
- Pokud shared smazání selže, dávka zůstane potvrzená nebo přeskočená.
- Pokud člen není online, opravu uvidí až po dalším reloadu.
- Pokud je uživatel členem skupiny a má vyplněné jméno, může vrátit i cizí potvrzení nebo přeskočení ve sdíleném plánu.
- Pokud jiný člen mezitím úspěšně zapsal pro stejnou dávku nový stav, první úspěšný cloudový stav po vrácení vyhrává podle pravidel v `00-pravidla-a-slovnik.md`.
