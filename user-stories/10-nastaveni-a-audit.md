# Nastavení a audit

## Cíl
Uživatel nebo tester chce ověřit verzi aplikace, CloudKit prostředí, stav notifikací a aktuálně naplánované alarmy.

## Předpoklady
Aplikace je spuštěná a uživatel má dostupnou záložku `Nastavení`.

## Scénář
1. Uživatel otevře `Nastavení`.
2. Aplikace zobrazí položky `Alarmy`, `Nastavení alarmů` a `Verze`.
3. Uživatel otevře `Alarmy`.
4. Aplikace zobrazí stav notifikačních oprávnění.
5. Aplikace zobrazí počet čekajících alarmů a čas posledního přeplánování.
6. Uživatel vidí seznam nejbližších čekajících alarmů.
7. Uživatel klepne na `Přeplánovat alarmy`.
8. Aplikace přepočítá alarmy podle aktuálních cloudových dat.
9. Uživatel otevře `Verze`.
10. Aplikace zobrazí verzi, build, typ buildu, CloudKit prostředí, push prostředí, bundle identifier a iCloud container.

## Očekávaný výsledek
Tester dokáže z aplikace poznat, jaký build běží, proti jakému prostředí pracuje a jestli alarmy odpovídají aktuálním datům.

## Chybové stavy
- Pokud nejsou žádné alarmy, aplikace zobrazí prázdný stav.
- Pokud notifikace nejsou povolené, aplikace to jasně ukáže.
- Pokud přeplánování selže, aplikace zobrazí chybu bez posunutí hlavního layoutu.
