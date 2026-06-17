# Změna jména člena se zobrazí ostatním

## Cíl
Člen skupiny chce změnit svoje jméno a ostatní členové mají po synchronizaci vidět nové jméno v seznamu členů i u potvrzení.

## Předpoklady
Uživatel A a uživatel B jsou členové stejné sdílené skupiny a oba mají aplikaci synchronizovanou.

## Scénář
1. Uživatel B otevře `Skupina`.
2. Uživatel B změní `Moje jméno`.
3. Uživatel B klepne na `Uložit`.
4. Aplikace uživatele B uloží změnu profilu do skupinové úložištěu vlastníka.
5. Aplikace uživatele B okamžitě zobrazí nové jméno u jeho potvrzení.
6. Uživatel A provede synchronizaci.
7. Aplikace uživatele A načte profily členů ze skupinové úložištěu vlastníka.
8. Uživatel A vidí nové jméno uživatele B v `Ostatní členové`.
9. Uživatel A vidí nové jméno uživatele B i u starých a nových potvrzení.

## Očekávaný výsledek
Jméno člena je profilový údaj sdílené skupiny a po synchronizaci se propíše všem členům.

## Chybové stavy
- Pokud uložení jména selže, ostatní členové dál vidí původní jméno.
- Pokud uživatel A není online, nové jméno uvidí po dalším reloadu.
- Pokud profil člena nejde načíst, potvrzení zůstane viditelné bez zavádějícího jména.
