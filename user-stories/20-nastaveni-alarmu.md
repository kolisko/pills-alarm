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

## Ovládací centrum
1. Na iOS 26 nebo novějším uživatel po aktualizaci jednou otevře Pills Alarm a přidá si ovladač `Alarmy Pills` do Ovládacího centra.
2. Ovladač zobrazuje stejné zapnutí jako přepínač `AlarmKit` v nastavení aplikace. Změny v nastavení obnovují i stav ovladače.
   Ikona je kulatá tableta s malým zvonkem; ve vypnutém stavu je přeškrtnutý pouze zvonek. Rýha tablety vede opačným směrem než přeškrtnutí, aby byly oba stavy rozeznatelné i bez barvy. Optický střed odpovídá samotné tabletě; zvonek vyčnívá vpravo dole a nemění zarovnání. Oba vlastní vektorové symboly jsou součástí rozšíření ve formátu SF Symbols 3 s optickými okraji pro všechny velikosti a řezy. Jejich zdroj se regeneruje příkazem `swift Tools/generate-alarm-control-symbols.swift` z kořene projektu.
3. Vypnutí použije stejný plánovač v procesu aplikace a zruší všechny její alarmy včetně právě zvonících, budoucích a testovacích. Nevyžaduje načtení plánů z iCloudu a neotevírá obrazovku aplikace.
4. Zapnutí ověří oprávnění AlarmKit a načte plány, pokud ještě nejsou dostupné v paměti aplikace. Naplánuje aktuální podání podle stávajících pravidel, neobnovuje starý testovací alarm.
5. Při chybě načtení nebo oprávnění se vypnutý stav nezmění. Chyba plánování nebo rušení se vrátí systému; ovladač nesmí oznámit úspěch před dokončením operace.
6. Souběžné pozdě dokončené zapnutí nesmí přebít novější vypnutí. Následná synchronizace ani návrat do aplikace vypnuté alarmy znovu nezapnou.

Plány, potvrzení a CloudKit se nemění. Stávající lokální preference zůstává zdrojem pravdy. App Group `group.com.kolisko.pillcare.controls` obsahuje pouze kopii zapnutého/vypnutého stavu pro čtení rozšířením, nikoli zdravotní data. Při chybějícím stavu ovladač vyžádá otevření aplikace místo předstírání vypnutých alarmů. Při podpisu pro zařízení musí mít aplikace i rozšíření přidělenou tuto App Group.

`AlarmControlTests` ověřují sdílené chování nastavení a ovladače, rušení alarmů, chyby a souběžné změny. Integrační test `testControlIntentCancelsRealRingingAndFutureAlarms` vyžaduje `PILLCARE_CONTROL_INTENT_TEST=1`, `PILLCARE_ALARM_BENCHMARK=1` a izolovaný simulátor s povoleným AlarmKitem a bez alarmů. Ověřuje produkční App Intent proti skutečnému zvonícímu a budoucímu alarmu, nikoli systémové doručení klepnutí do aplikace.

Pro ruční kontrolu skutečného ovladače slouží `testActualControlTapCancelsRealAlarms` s `PILLCARE_CONTROL_UI_TEST=1` a `PILLCARE_ALARM_BENCHMARK=1`. Po naplánování je potřeba klepnout na ovladač v Ovládacím centru; test sám akci nevolá. Na fyzickém iPhonu je potřeba ověřit přidání ovladače, stav po změně v nastavení, vypnutí při zvonění i při ukončené aplikaci a opětovné zapnutí. Systém může vyžadovat odemknutí podle nastavení telefonu.

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

Test `AlarmSchedulerTests.testActualBannerTapStopsRealAlarmKitAlarm` používá `PILLCARE_REAL_BANNER_TEST=1` a izolaci od cloudového přeplánování pomocí `PILLCARE_ALARM_BENCHMARK=1`. Sám akci pro otevření nevolá. Po naplánování alarmu za 20 sekund je nutné v UI simulátoru přesunout aplikaci do pozadí a klepnout na skutečný systémový banner. Test ověří návrat do aplikace, zastavení konkrétního alarmu, zachování budoucího alarmu a přechod na `Dnes`; přiloží JSON se skutečným výsledkem. Součástí ruční kontroly je také snímek obrazovky ověřující zmizení banneru. Bez výslovného zapnutí se test přeskočí.

## Pípání a hlas
1. Výchozí zvuk je `Pípání`. Uživatel v sekci `Zvuk` zvolí `Pípání a hlas`.
2. Aplikace zachová současné rušení a opětovné vytváření všech alarmů, jejich agregaci, horizont a opakovací pravidla. Pro každou již sestavenou skupinu připraví jeden zvuk s původním pípáním a dávkami všech léků.
3. Například pro půl tablety Ospolutu a jednu tabletu Trelemy ve stejný čas zazní celá trojice původních pípnutí, množství a název prvního léku, krátká pauza a množství a název druhého léku. Celý seznam se podle dostupné délky zvuku opakuje s pípáním mezi opakováními. Zbytek nahrávky doplní pouze celé trojice s pauzami a případné ticho, žádný tón se uprostřed neusekne.
4. Při dalším přeplánování se použijí již dokončené nahrávky se stejným obsahem a hlasem. Změna množství nebo složení skupiny vybere jiný soubor. Potvrzený nebo přeskočený lék se řídí stávajícími pravidly a při dalším přeplánování se nečte.
5. Nahrávky se vytvářejí pouze pro skupiny předané stávajícím plánovačem. Žádné další budoucí fáze se předem nepřipravují.
6. Nastavení zvuku přežije restart a platí jen pro toto zařízení. Přepnutí při vypnutých alarmech je nezapne.
7. Test použije vybraný zvuk a nejbližší skutečnou skupinu z běžného plánovače včetně všech nepotvrzených dávek podle příslušné fáze. V hlasovém režimu se text sestaví stejným postupem jako u běžného alarmu a využije stejnou cache. Alarm zazní minutu po přípravě zvuku. Bez dostupných podání se zobrazí zpráva.
8. Generování hlasu nemá časový limit a všechny chybějící nahrávky se dokončí ve stejném průchodu. Chybějící český hlas, chyba syntézy nebo příliš dlouhý seznam znamenají původní pípání a viditelné upozornění. Žádný lék se kvůli délce hlášení nevynechá ani neusekne. Nedokončený soubor se znovu nepoužije.
9. Horní pohyblivá linka běží při načítání z iCloudu i při přípravě hlasu a nastavení alarmů. Zmizí až po dokončení obou kroků. Nahrazení rozpracovaného přeplánování novějším linku předčasně neschová; chyba plánování linku ukončí a zůstane viditelná v auditu.

Test `AlarmAudioTests.testRealCzechSpeechRender` lze spustit s `PILLCARE_SPEECH_SMOKE_TEST=1` v testovacím procesu pro ověření skutečné české syntézy. Na fyzickém iPhonu je nutné poslechem ověřit vlastní zvuk při zamčené obrazovce a ukončené aplikaci, srozumitelnost názvů, zlomků a mililitrů i úplnost delších seznamů.

## Měření doby přeplánování
Test `AlarmSchedulingBenchmarkTests.testColdAndReusedAudioWithSixtyRealAlarms` se spouští v izolovaném simulátoru s `PILLCARE_ALARM_BENCHMARK=1` v prostředí testovacího procesu. Vyžaduje oprávnění AlarmKit; s existujícími alarmy se přeskočí. Používá skutečnou českou syntézu, diskovou cache a skutečný AlarmKit.

Sada má 60 alarmů, každý se třemi léky. Výchozí varianta obsahuje šest různých hlášek; `PILLCARE_BENCHMARK_UNIQUE_CONTENTS=60` nastaví zátěžovou variantu se 60 různými hláškami. První průchod vymaže pouze nahrávky vlastní testovací sady a měří prázdnou cache. Následují tři opakovaná kompletní přeplánování a srovnání se samotným pípáním. U každého průchodu se ukládá celkový čas, čas audia, počet nových souborů, použití cache a náhradního pípání. Výstup je příloha JSON v `.xcresult`.

Celkový čas zahrnuje současné rušení a vytváření alarmů i přípravu jejich zvuku. Nezahrnuje spuštění testovací aplikace, dialog oprávnění ani vytvoření testovací sady. Na konci se testovací alarmy a jejich nahrávky odstraní. Jde o syntetickou zátěž; výsledky ze simulátoru nejsou měřením na fyzickém iPhonu ani nad osobními plány uživatele.

Aktuální měření bez limitu ze 17. 10. 2026: 60 různých hlášek pro 60 skutečných alarmů se vytvořilo napoprvé za 5,150 s, všechny s hlasem. Následující kompletní přeplánování s hotovými soubory trvala 0,196 / 0,197 / 0,190 s. Pípání pro srovnání trvalo 0,149 s. Měření vyprázdnilo aplikační cache audia; systémové služby syntézy už mohly být zahřáté. Měřicí režim potlačuje automatické spouštěcí a foreground přeplánování, aby nerušilo jeho vlastní alarmy. Úplné hodnoty jsou v [JSON výsledcích bez limitu](../docs/alarm-audio-benchmark-no-limit.json).

Původní měření 17. 10. 2026 ještě s osmivteřinovým limitem, který byl následně odstraněn: simulátor iPhone 17 Pro / iOS 26.5 (Xcode 27.1), vždy 60 skutečně nastavených alarmů:

| Různých hlášek | Průchod | Celkem | Nové soubory | Použití cache | Náhradní pípání |
| --- | --- | --- | --- | --- | --- |
| 6 | První | 2,081 s | 6 | 54 | 0 |
| 6 | Další 1 | 0,228 s | 0 | 60 | 0 |
| 6 | Další 2 | 0,223 s | 0 | 60 | 0 |
| 6 | Další 3 | 0,204 s | 0 | 60 | 0 |
| 60 | První | 8,641 s | 16 | 0 | 44 |
| 60 | Další 1 | 8,048 s | 40 | 16 | 4 |
| 60 | Další 2 | 1,821 s | 4 | 56 | 0 |
| 60 | Další 3 | 0,415 s | 0 | 60 | 0 |

Samotná audio část při šesti nových hláškách trvala 1,804 s; použití 60 hotových souborů trvalo 11–22 ms. Srovnávací přeplánování se samotným pípáním trvalo 0,161 s a 0,391 s v jednotlivých bězích. Tyto historické výsledky zachycují i náhradní pípání způsobené tehdejším limitem a nereprezentují aktuální chování bez limitu. Úplné hodnoty jsou v [JSON výsledcích](../docs/alarm-audio-benchmark.json).

## Chybové stavy
- Pokud uživatel nastaví hodnotu mimo povolený rozsah, aplikace ji omezí na platnou mez.
- Pokud přeplánování selže, aplikace zobrazí chybu.
- Pokud zrušení některého alarmu selže, vypnutý stav zůstane uložený, aplikace zobrazí chybu a zrušení zopakuje při návratu nebo přeplánování.
- Pokud je oprávnění zamítnuté nebo AlarmKit není dostupný, zapnutí se neprovede a nevzniknou náhradní lokální notifikace.
- Pokud nejsou žádné budoucí dávky, změna nastavení nezobrazí žádné čekající alarmy.
