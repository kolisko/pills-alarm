# Historie a identita - shared sync

## Cíl
Členové skupiny chtějí vidět v historii aktuální jméno člověka, který dávku podal nebo přeskočil.

## Předpoklady
Ve sdílené skupině existují potvrzení navázaná na profily členů.

## Scénář
1. Uživatel A potvrdí sdílenou dávku.
2. Aplikace uloží potvrzení s vazbou na profil uživatele A.
3. Uživatel B otevře `Historie`.
4. Aplikace načte potvrzení a profily členů ze skupinové úložištěu vlastníka.
5. Uživatel B vidí potvrzení se jménem uživatele A.
6. Uživatel A změní svoje jméno ve skupině.
7. Aplikace uloží změnu profilu uživatele A do skupinové úložištěu vlastníka.
8. Uživatel B provede synchronizaci.
9. Aplikace uživatele B znovu načte profily členů.
10. Uživatel B vidí stará i nová potvrzení s aktuálním jménem uživatele A.

## Očekávaný výsledek
Historie nepoužívá starý text jména uložený u potvrzení jako pravdu. Jméno se odvozuje z aktuálního profilu člena.

## Chybové stavy
- Pokud profil člena nejde načíst, potvrzení zůstane viditelné bez jména.
- Pokud změna jména není sesynchronizovaná, druhý uživatel může krátce vidět staré jméno.
- Pokud potvrzení ukazuje na neznámého člena, aplikace nezobrazí zavádějící jméno.
