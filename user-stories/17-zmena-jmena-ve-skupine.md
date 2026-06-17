# Změna jména ve skupině

## Cíl
Uživatel chce změnit svoje jméno ve skupině a mít nové jméno viditelné u starých i nových potvrzení.

## Předpoklady
Uživatel je členem skupiny a má vytvořený profil člena.

## Scénář
1. Uživatel otevře `Skupina`.
2. Aplikace zobrazí pole `Moje jméno`.
3. Uživatel změní svoje jméno.
4. Uživatel klepne na `Uložit`.
5. Aplikace uloží změnu profilu člena do skupinové úložištěu vlastníka.
6. Aplikace aktualizuje lokální stav profilu.
7. Uživatel otevře `Dnes` nebo `Historie`.
8. Aplikace zobrazí stará i nová potvrzení s aktuálním jménem uživatele.

## Očekávaný výsledek
Jméno u potvrzení je svázané s profilem člena, takže změna profilu se projeví i u historických záznamů.

## Chybové stavy
- Pokud uložení jména selže, staré jméno zůstane platné.
- Pokud uživatel zadá prázdné jméno ve sdílené skupině, aplikace mu nedovolí potvrzovat sdílené dávky.
- Pokud jiný člen ještě nesynchronizoval data, může krátce vidět staré jméno.
