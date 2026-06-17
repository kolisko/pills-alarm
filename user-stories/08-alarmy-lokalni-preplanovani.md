# Alarmy - lokální přeplánování

## Cíl
Aplikace má po každé změně lokálně zrušit neaktuální alarmy a naplánovat jen dávky, které ještě mají houkat.

## Předpoklady
Existuje budoucí dávka a aplikace má povolené notifikace se zvukem.

## Scénář
1. Aplikace načte aktuální CloudKit data.
2. Aplikace vypočítá budoucí dávky z osobních a sdílených plánů.
3. Aplikace porovná plánované alarmy s aktuálními dávkami a potvrzeními podle stabilní identity dávkovacích slotů.
4. Aplikace zruší alarmy pro dávky, které už jsou podané, přeskočené nebo změněné.
5. Aplikace naplánuje alarmy pro aktuální budoucí dávky.
6. Uživatel otevře `Nastavení` > `Alarmy`.
7. Uživatel vidí aktuální počet čekajících alarmů a čas posledního přeplánování.

## Očekávaný výsledek
Lokální alarmy jsou pouze odvozený stav z CloudKitu, ne samostatná pravda.

## Chybové stavy
- Pokud systém nepovolil notifikace, aplikace to ukáže v nastavení.
- Pokud přeplánování selže, aplikace zobrazí chybu.
- Pokud neexistují budoucí dávky, seznam čekajících alarmů je prázdný.
- Pokud byl dávkovací slot nebo plán smazaný, aplikace zruší jeho alarmy a po reloadu už neukazuje odpovídající běžnou historii.
