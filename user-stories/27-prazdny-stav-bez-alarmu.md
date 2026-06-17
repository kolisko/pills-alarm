# Prázdný stav bez alarmů

## Cíl
Uživatel chce v auditu alarmů vidět, že žádné alarmy nejsou naplánované, pokud pro ně nejsou aktuální dávky.

## Předpoklady
Aplikace má načtený CloudKit stav a neexistují budoucí nepotvrzené dávky, pro které by měl být alarm.

## Scénář
1. Uživatel otevře `Nastavení`.
2. Uživatel otevře `Alarmy`.
3. Aplikace načte čekající lokální notifikace.
4. Aplikace zjistí, že žádné dose alarmy nejsou naplánované.
5. Aplikace zobrazí prázdný stav `Žádné alarmy nejsou naplánované`.
6. Uživatel vytvoří nebo upraví plán s budoucí dávkou.
7. Aplikace přeplánuje alarmy.
8. Uživatel znovu otevře `Alarmy`.
9. Aplikace zobrazí nově čekající alarm.

## Očekávaný výsledek
Prázdný audit alarmů odpovídá aktuálním dávkám a nepůsobí jako chyba.

## Chybové stavy
- Pokud notifikace nejsou povolené, audit to zobrazí odděleně.
- Pokud načtení čekajících alarmů selže, aplikace zobrazí chybu.
- Pokud plán neobsahuje budoucí dávky větší než `0`, alarmy se nenaplánují.
