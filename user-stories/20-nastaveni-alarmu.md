# Nastavení alarmů

## Cíl
Uživatel chce zapnout nebo vypnout AlarmKit, vybrat pípání nebo hlas a upravit pravidla opakovacích alarmů bez změny samotného plánu léků.

## Předpoklady
Pro zapnutí alarmů je potřeba iOS 26 nebo novější a oprávnění AlarmKit. Vypnout alarmy lze i bez oprávnění nebo dostupného iCloudu.

## Scénář
1. Uživatel otevře `Nastavení`.
2. Uživatel otevře `Nastavení alarmů`.
3. Aplikace zobrazí přepínač `AlarmKit`, test alarmu, volbu zvuku, interval opakování, délku série a počet nejbližších časů podání se sérií.
4. Uživatel zapne `AlarmKit` a případně povolí systémové oprávnění.
5. Aplikace uloží nastavení do tohoto zařízení a naplánuje aktuální alarmy.
6. Uživatel změní interval nebo délku opakovací série; aplikace alarmy přepočítá.
7. Uživatel může naplánovat test za jednu minutu bez zrušení běžných alarmů.
8. Uživatel vypne `AlarmKit`.
9. Aplikace uloží vypnutý stav a zruší všechny své alarmy včetně testu i případné staré lokální notifikace.
10. Po návratu z pozadí, restartu a synchronizaci zůstávají alarmy vypnuté. Testovací tlačítko je nedostupné.
11. Uživatel otevře `Alarmy` a ověří vypnutý stav a prázdný seznam čekajících alarmů.

## Očekávaný výsledek
Upozornění používají pouze AlarmKit, nebo jsou vypnutá. Nastavení platí jen pro toto zařízení; plány, potvrzení, sdílení a synchronizace se nemění. Aktualizace zachová zapnutý stav dosavadním uživatelům AlarmKitu. Nová instalace a původní režim lokálních notifikací začínají s alarmy vypnutými.

## Otevření aplikace z alarmu
1. Uživatel naplánuje test za jednu minutu a přepne aplikaci na jinou záložku nebo ji přesune do pozadí.
2. Běžící alarm nabídne vedle systémového zastavení tlačítko `Otevřít`.
3. Klepnutí na `Otevřít` zastaví konkrétní zvonící alarm, přenese aplikaci do popředí a zvolí záložku `Dnes` s aktuálním dnem. Budoucí alarmy ani další připomínky tím nejsou zrušené.
4. Stejnou akci je potřeba ověřit při ukončené aplikaci, při zobrazeném jiném dni a při opakovaném otevření z dalšího alarmu.
5. Otevření samo nepotvrdí ani nepřeskočí žádnou dávku. Uživatel podání potvrzuje běžným tlačítkem v aplikaci.
6. Akce je stejná pro testovací i běžné dávkové alarmy. Systémové zastavení zůstává bez vlastní akce pro otevření aplikace.

Systémové zobrazení a přechod ze zamčené obrazovky je nutné ověřit také na fyzickém iPhonu. Aktualizované tlačítko se objeví u nově naplánovaných nebo přeplánovaných alarmů.

Akce dostává ID konkrétního alarmu. Opakované otevření již skončeného alarmu nic dalšího nezastaví. U starších alarmů bez předaného ID lze zastavit jediný jednoznačně zvonící alarm; při nejednoznačnosti aplikace nesmí rušit jiné alarmy. Pokud systémové zastavení selže, aplikace zkusí zrušit pouze tentýž stále zvonící jednorázový alarm. Chyba obou operací se nezamlčí.

Test `AlarmSchedulerTests.testOpenIntentStopsRealAlarmKitAlarm` je ručně spouštěný integrační test pro izolovaný simulátor bez existujících alarmů. Aktivuje se proměnnou testovacího procesu `PILLCARE_REAL_ALARMKIT_TEST=1`; jinak se přeskočí. Ověřuje skutečný stav `alerting`, zastavení přes produkční App Intent a zachování budoucího alarmu. Nenahrazuje kontrolu klepnutí ze zamčené obrazovky fyzického telefonu.

## Pípání a hlas
1. Výchozí zvuk je `Pípání`. Uživatel v sekci `Zvuk` zvolí `Pípání a hlas`.
2. Aplikace zachová současné rušení a opětovné vytváření všech alarmů, jejich agregaci, horizont a opakovací pravidla. Pro každou již sestavenou skupinu připraví jeden zvuk s původním pípáním a dávkami všech léků.
3. Například pro půl tablety Ospolutu a jednu tabletu Trelemy ve stejný čas zazní pípání, množství a název prvního léku, krátká pauza a množství a název druhého léku. Celý seznam se podle dostupné délky zvuku opakuje s pípáním mezi opakováními.
4. Při dalším přeplánování se použijí již dokončené nahrávky se stejným obsahem a hlasem. Změna množství nebo složení skupiny vybere jiný soubor. Potvrzený nebo přeskočený lék se řídí stávajícími pravidly a při dalším přeplánování se nečte.
5. Nahrávky se vytvářejí pouze pro skupiny předané stávajícím plánovačem. Žádné další budoucí fáze se předem nepřipravují.
6. Nastavení zvuku přežije restart a platí jen pro toto zařízení. Přepnutí při vypnutých alarmech je nezapne.
7. Test za jednu minutu použije vybraný zvuk. V hlasovém režimu přečte testovací zprávu bez fiktivního pokynu k užití léků.
8. Chybějící český hlas, vypršení limitu generování, chyba syntézy nebo příliš dlouhý seznam znamenají původní pípání a viditelné upozornění. Žádný lék se kvůli délce hlášení nevynechá ani neusekne. Nedokončený soubor se znovu nepoužije.

Test `AlarmAudioTests.testRealCzechSpeechRender` lze spustit s `PILLCARE_SPEECH_SMOKE_TEST=1` v testovacím procesu pro ověření skutečné české syntézy. Na fyzickém iPhonu je nutné poslechem ověřit vlastní zvuk při zamčené obrazovce a ukončené aplikaci, srozumitelnost názvů, zlomků a mililitrů i úplnost delších seznamů.

## Chybové stavy
- Pokud uživatel nastaví hodnotu mimo povolený rozsah, aplikace ji omezí na platnou mez.
- Pokud přeplánování selže, aplikace zobrazí chybu.
- Pokud zrušení některého alarmu selže, vypnutý stav zůstane uložený, aplikace zobrazí chybu a zrušení zopakuje při návratu nebo přeplánování.
- Pokud je oprávnění zamítnuté nebo AlarmKit není dostupný, zapnutí se neprovede a nevzniknou náhradní lokální notifikace.
- Pokud nejsou žádné budoucí dávky, změna nastavení nezobrazí žádné čekající alarmy.
