# ESTADO.md — Estado de la implementación

Documento vivo. Se actualiza al terminar cada paso, no al final de la sesión. El plan
completo de cada fase vive en `ILoveVigoRoutes-HANDOFF.md`; esto es solo "dónde estamos".

---

## Resumen

| Fase | Estado |
|---|---|
| Fase 0 — Verificación y cimientos | ✅ Hecha |
| Fase 1 — Paradas y tiempo real | ✅ Hecha |
| Fase 2 — Ferry de la ría | ⬜ No empezada |
| **Fase 3 — Planificador de rutas (RAPTOR)** | ✅ Completa (solo bus) |
| Fase 4 — Pulido y comodidades | 🟡 Parcial: lugares/trayectos guardados, refresco en segundo plano, orden de pestañas, estrella unificada. Sin widget, atajos de Siri ni accesibilidad |
| **Fase 5 — El mapa como planificador** | 🟡 En curso: 2/11 pasos (sonda + máquina de estados) |

---

## Fase 3 — Planificador de rutas

Plan detallado (arquitectura, ficheros, secuencia completa de 11 pasos) en
`~/.claude/plans/actua-como-un-planificador-immutable-parnas.md`. Resumen de decisiones:
solo bus (ferry fuera hasta que exista Fase 2), solo consultas hacia delante, tiempo real
fuera del motor, RAPTOR y no CSA, `Timetable` en memoria sin migración de esquema.

### Hecho

- [x] **1/11 — `PlannerOptions` + `WalkModel`** (`b4edb59`)
  `VigoCore/Sources/VigoCore/Planner/PlannerOptions.swift`,
  `VigoCore/Sources/VigoCore/Planner/WalkModel.swift`.
  9 parámetros de política documentados. Conversión metros→segundos redondeando siempre
  hacia arriba. `footpaths(stops:)` con barrido por latitud, contrastado por test contra
  escaneo cuadrático completo (200 paradas, semilla fija).

- [x] **Fix de deuda, no planeado** — `f4a1282`
  `GTFSImporter.import` tomaba `Date()` real en vez del reloj que el llamador ya usaba;
  dos tests de `FeedServiceTests` solo pasaban antes de las 09:00 (Madrid). Ahora
  `import(importedAt:)` recibe el reloj, y `GTFSFeedService` le pasa el mismo `now` que usa
  para la hora de comprobación. Sin esto no se podía seguir con paso 2 con la suite verde.

- [x] **2/11 — `Timetable` + `TimetableBuilder`** (`1639109`)
  `VigoCore/Sources/VigoCore/Planner/Timetable.swift`,
  `VigoCore/Sources/VigoCore/Planner/TimetableBuilder.swift`.
  Snapshot en memoria, arrays CSR en `Int32`, sin migración de esquema. Pliega tres días de
  servicio sobre un eje temporal único; el desplazamiento entre días es la diferencia real
  entre medianoches (no 86400 fijo, por el cambio de hora). Separa patrones que se
  adelantan. Contra el feed real: 188 patrones, 1892 viajes, 70679 tiempos, 0,6 MB,
  construido en 34 ms — dentro del presupuesto de <1s con margen amplio.
  Verificado por mutación: desactivar la separación por adelantamiento tumba 4/15 tests.

- [x] **3/11 — `RaptorEngine`** (`e017e57`)
  `VigoCore/Sources/VigoCore/Planner/RaptorEngine.swift`.
  Función pura `(Timetable, RaptorQuery) -> RaptorResult`. Rondas = frente de Pareto
  (llegada, transbordos). Embarca con la etiqueta de la ronda anterior, no la actual. Un
  solo salto a pie por ronda (sin punto fijo — la desigualdad triangular lo hace seguro).
  Poda por objetivo desde el inicio.
  **Aviso importante:** los 14 tests iniciales pasaron a la primera. Se probaron 4
  mutaciones deliberadas del motor; 2 pasaban desapercibidas porque la red sintética de
  pruebas no tenía la forma para exponerlas (embarcar con etiqueta de ronda en curso;
  encadenar caminatas). Se amplió la red (parada E, línea L6) hasta que las 4 mutaciones
  fallan. Ver commit `e017e57` para el detalle — es la evidencia de que "tests en verde"
  no bastaba por sí solo.

- [x] **4/11 — `BruteForceReference` + contraste aleatorizado**
  `VigoCore/Tests/VigoCoreTests/BruteForceReference.swift`,
  `VigoCore/Tests/VigoCoreTests/BruteForceReferenceTests.swift`.
  Referencia exhaustiva (sin búsqueda binaria, sin cola de posiciones, cada patrón
  reescaneado entero cada ronda) contra timetables sintéticos aleatorios construidos
  directamente sobre los arrays de `Timetable` (sin pasar por GTFS), 200 instancias con
  semilla fija (`SeededGenerator`, splitmix64).
  **Encontró un bug real en `RaptorEngine`, no solo en la referencia**: el paso 4 de
  relajación de footpaths (`RaptorEngine.swift`) leía `arrival[base + stop]` en vivo como
  origen de cada caminata. Si una parada `X` alcanzada en bici/bus en esta ronda recibía
  además una caminata entrante *antes* de que le tocara su turno como origen (`X` está en
  `riddenStops`, solo que más adelante en la lista), esa lectura recogía el valor ya
  corregido por la caminata entrante en vez del de la subida — encadenando dos caminatas en
  una ronda sin que ninguno de los dos bucles lo notara, justo lo que el diseño prohíbe
  explícitamente («un solo salto a pie por ronda») y lo que el test
  `oneWalkPerRound` no cazaba porque solo mira el `parent` final, no los valores
  intermedios usados para calcularlo. Arreglado tomando una foto (`rideArrival: [Int:
  Int32]`) de las llegadas en bus antes de que el bucle de caminatas escriba nada; la
  referencia tenía el mismo fallo y se corrigió igual. Sin el contraste aleatorizado este
  bug no tenía ningún test que lo detectara — los 14+4 tests de ejemplo del paso 3 pasaban
  igual de verdes con o sin él.

- [x] **5/11 — Reconstrucción de viajes + ajuste hacia atrás + selección de alternativas**
  `VigoCore/Sources/VigoCore/Planner/Place.swift`, `Journey.swift`, `JourneyReconstruction.swift`;
  tests en `VigoCore/Tests/VigoCoreTests/JourneyReconstructionTests.swift`.
  `Place` (parada, o coordenada con etiqueta — ubicación/mapa) y `Journey`/`JourneyLeg` tal
  como los describe el plan. `JourneyReconstruction.alternatives` recorre los `parent` de
  `RaptorResult` hacia atrás por ronda (un `.ride` retrocede a la ronda anterior en la
  parada de subida, un `.walk` se queda en la misma ronda), arma la cadena hacia delante y
  aplica la pasada de ajuste: desde la llegada fija del último tramo, cada tramo en autobús
  se recalcula al **viaje más tardío** del mismo patrón que sigue llegando a tiempo, y el
  límite se propaga hacia atrás restando `minTransferSeconds` (mismo andén),
  `footpathBufferSeconds` + segundos de la caminata (transbordo a pie), o nada (tramo de
  acceso, que fija la hora de salida real). Una ronda por candidata (ya es frente de
  Pareto por construcción: más transbordos solo aparece si mejora la llegada), filtrado por
  `extraTransferWorthSeconds` contra la última alternativa aceptada, orden por llegada,
  tope de 3.
  Verificado por mutación: anular la pasada de ajuste (usar siempre el viaje ya encontrado)
  tumba el test dedicado con una red construida a propósito (tres viajes de un mismo patrón
  cada 5 minutos hacia una única conexión fija) — sin esa red los ejemplos del paso 3/4 no
  tenían margen suficiente para exponerlo, exactamente el mismo patrón de riesgo que ya
  apareció en los pasos anteriores.
  **Desviación del plan:** el fichero de test se llama `JourneyReconstructionTests.swift`,
  no `JourneyPlannerTests.swift` — ese nombre lo tomará el paso 6, cuando exista de verdad
  la fachada `JourneyPlanner` que el plan describe para ese fichero.

- [x] **6/11 — `TimetableStore` + `JourneyPlanner` + todos los `PlanOutcome`**
  `VigoCore/Sources/VigoCore/Planner/TimetableStore.swift`, `JourneyPlanner.swift`;
  tests en `JourneyPlannerTests.swift` (facade), `TimetableStoreTests.swift`.
  `TimetableStore` es el segundo actor del paquete (junto a `ThrottledRealtimeProvider`),
  pero más simple: `TimetableBuilder.build` no tiene ningún punto de suspensión dentro, así
  que la propia serialización del actor ya basta para que dos peticiones concurrentes
  esperen a una sola construcción — no hace falta el `inFlight`/`Task` que sí necesita
  `ThrottledRealtimeProvider` (esa sí llama a una red asíncrona real). Caché LRU de 3
  entradas, clave (día ancla, `feedStatus.importedAt`).
  `JourneyPlanner.plan` sigue el orden literal del plan: resuelve accesos/salidas por
  `nearbyStops` con el radio de acceso, comprueba ventana del feed y día de servicio, pide
  el `Timetable` al store, corre `RaptorEngine`, reconstruye con `JourneyReconstruction`, y
  decide entre `.journeys`, `.walkOnly` y `.noJourneyFound` comparando la caminata directa
  contra la mejor alternativa en autobús.
  **Desviación del plan, justificada:** el plan no dice cuándo `.noJourneyFound` debe
  ganarle a `.walkOnly` — tal cual estaba escrito ("si caminar es más rápido... walkOnly"),
  caminar siempre "gana" cuando no hay autobús, y `.noJourneyFound` quedaría inalcanzable
  pese a ser un caso que el propio plan pide probar. Añadido un límite: la caminata directa
  solo es una alternativa válida si tarda `<= options.searchHorizon` (el mismo presupuesto
  que ya usa la búsqueda en autobús); si no, y no hay autobús, es `.noJourneyFound`.
  Verificado por mutación: anular el recorte por capacidad de `TimetableStore` tumba el
  test de desalojo con un mismatch de contenido, no solo un contador.
  El nombre `JourneyPlannerTests.swift` que el paso 5 dejó pendiente para "cuando exista de
  verdad la fachada" ya está en uso, tal como el plan lo preveía.

- [x] **7/11 — Integración con el feed real + asserción de <1s**
  `VigoCore/Tests/VigoCoreTests/RealFeedIntegrationTests.swift` (ampliado).
  Nuevo test `realJourneyPlan`: Praza de América → Urzaiz (~1,3 km, centro de Vigo) con
  `JourneyPlanner` contra el archivo real, aceptando `.journeys`, `.walkOnly` o
  `.noServiceOnDay` (un hueco real de calendario no es un defecto) y fallando para
  cualquier otro caso. `RealFeedTimingTests.importTimings` añade la única asserción dura de
  la fase: `planElapsed < 1.0` sobre una construcción de `Timetable` **en frío** (el caso
  peor: nunca se había construido para ese día) más `RaptorEngine` más reconstrucción —
  medido: **40 ms** contra el feed real (1154 paradas, 3801 viajes, 137456 stopTimes),
  25× de margen sobre el presupuesto de 1s del handoff.
  **Detalle no obvio:** la consulta usa el día del propio `feed.serviceWindow`, no "hoy" —
  el archivo descargado es una foto fija y su ventana de 7 días no siempre incluye la fecha
  real en la que corre el test (el archivo usado aquí, descargado el 2026-09-04, reporta
  ventana 20260905–20260911, es decir *empieza mañana*). Usar `Date()` directamente habría
  dado `.outsideFeedWindow` de forma intermitente según cuándo se ejecute la suite.

- [x] **8/11 — App: cirugía de `RootView`, "Fuentes" a Favoritas, `AppEnvironment`**
  `App/ILoveVigoRoutes/Views/RootView.swift`, `Views/FavouritesView.swift`,
  `AppEnvironment.swift`, `Info.plist`.
  `AppTab` gana `.planner` (quinta posición ocupada, así que `.sources` desaparece);
  pestaña "Planificar" (`arrow.triangle.turn.up.right.diamond`) en 3ª posición, entre
  "Cercanas" y "Buscar". "Fuentes" pasa a un botón de información en la barra de
  navegación de `FavouritesView`, a nivel del `NavigationStack` (no dentro de
  `content(_:)`), para que exista también con cero favoritas; abre `DataSourcesView` en
  una hoja en vez de empujarla en la propia `NavigationStack` de Favoritas.
  `AppEnvironment` gana `let planner: JourneyPlanner` y un `TimetableStore` propio,
  precalentado en `init` con `Task.detached(priority: .utility)` para el día de hoy — el
  mismo patrón que ya usa `refreshFeed`. `Info.plist` amplía la descripción de ubicación
  para mencionar la planificación.
  **Desviación del plan, señalada por necesidad, no por elección:** el plan reserva
  `PlannerView.swift` para el paso 9, así que la pestaña "Planificar" de este paso apunta a
  un `PlannerPlaceholderView` provisional en el propio `RootView.swift` — se sustituye por
  la vista real en el paso 9.
  Verificado en el simulador (iPhone 17 Pro): las 5 pestañas se ven correctas
  (Favoritas/Cercanas/Planificar/Buscar/Mapa, sin "Fuentes"), el botón de información abre
  la hoja de "Fuentes de datos" con el `feedStatus` real, y la pestaña "Planificar" muestra
  el placeholder. De paso, confirma en vivo lo que el paso 7 ya había medido: la ventana del
  feed real descargado hoy es 05/09–11/09, es decir, no cubre "hoy" (04/09).

- [x] **9/11 — `PlannerView` + `PlacePickerView`**
  `App/ILoveVigoRoutes/Views/PlannerView.swift`, `PlacePickerView.swift`,
  `MapPointPickerView.swift`, `JourneyRows.swift`.
  `PlannerModel` sigue el patrón de `StopDetailModel`: origen/destino como `Place?`,
  intercambio, modo de salida (ahora / a una hora), y `plan()` llamando a
  `environment.planner.plan(_:)`. `PlacePickerView` cubre las cuatro formas de elegir sitio
  que pide el handoff — mi ubicación, favorita, resultado de `searchStops` (sin debounce,
  igual que `SearchView`), y "elegir en el mapa" vía `MapPointPickerView` (mismo patrón de
  `Map`/`MapCameraPosition` que ya usa `StopsMapView`, pin fijo en el centro en vez de
  anotación arrastrable). `JourneyRows.swift` trae `JourneyAlternativeRow` (resumen: hora,
  hora, duración, chips por tramo) y `JourneyLegRow` (tramo expandido, para cuando exista
  `JourneyDetailView` en el paso 10), reutilizando `LineBadge`/`WaitTime` de
  `DataProvenanceViews.swift`.
  Verificado en el simulador (iPhone 17 Pro) contra el feed real completo: Praza de
  América → Rúa de Urzáiz un día dentro de la ventana (05/09) encuentra la ruta real
  (línea 29, directo, 14 min, con los tramos a pie de entrada y salida correctos); el mismo
  origen/destino "ahora" (04/09, fuera de ventana) devuelve el mensaje de
  `outsideFeedWindow` correcto. Confirma en el simulador, con interacción real, lo que los
  pasos 6 y 7 ya habían probado por código.
- [x] **10/11 — `JourneyDetailView` con trazado real desde `shapePoint`**
  `App/ILoveVigoRoutes/Views/JourneyDetailView.swift`;
  `VigoCore/Sources/VigoCore/Persistence/TransitRepository.swift` gana `trip(id:)`.
  Primer uso real de `shapePoint`/`TransitRepository.shape(id:)`, importados e indexados
  desde la Fase 0 pero sin ningún lector hasta ahora. Cada tramo en autobús resuelve
  `tripID → Trip → shapeID → [ShapePoint]` y recorta el trazado entero de la línea a la
  parte realmente recorrida: el helper que pedía el plan, por punto más cercano (no por
  índice de secuencia, porque GTFS no promete un `shapePoint` exacto en cada parada, solo
  que la parada cae cerca del trazado). `Map` con `MapPolyline` + marcadores de
  origen/subida/bajada/destino, y debajo la lista de tramos con `JourneyLegRow` (ya escrito
  en el paso 9). `PlannerView` engancha cada alternativa con un `NavigationLink`.
  Verificado en el simulador contra el feed real: el tramo en autobús (línea 23,
  Avda. de Castrelos → Rúa de Pizarro) dibuja el trazado real siguiendo las calles, no una
  línea recta entre las dos paradas.
  Añadido de paso: `RepositoryTests.tripLookup` cubre el `trip(id:)` nuevo (encuentra el
  `shapeID`, y `nil` para un id inexistente).
- [x] **11/11 — Anotación con tiempo real del primer embarque + `README.md`**
  `App/ILoveVigoRoutes/Views/JourneyDetailView.swift`; `README.md` (tabla de estado).
  `JourneyDetailView` cruza el primer tramo en autobús con `environment.arrivals` (la
  misma `ArrivalsService` que ya usa el resto de la app): mismo `normalizedLine`, y de entre
  las llegadas de esa línea en la parada de subida, la que tiene una hora implícita
  (`ahora + minutos`) más cercana a la hora de salida ya fijada por la reconstrucción —
  aceptada solo dentro de 15 minutos de margen, para no confundir el autobús que se busca
  con el siguiente de la misma línea. Fuera del motor por diseño (la decisión de Fase 3 lo
  dice explícitamente): el tiempo real solo anota, nunca decide la ruta. Con una consulta a
  fecha futura (no "ahora") no hay nunca coincidencia, que es lo correcto — el tiempo real
  no puede saber nada de un autobús que aún no está por llegar.
  `README.md`: Fase 1 pasa de "Pendiente" a "Completa" (ya lo estaba, era una tabla
  desactualizada) y Fase 3 pasa de "No iniciada" a "Completa (solo bus; el ferry entra
  cuando exista la Fase 2)".
  Verificado en el simulador contra el feed real: sin coincidencia para una consulta a
  futuro (05/09 con "hoy" en 04/09) no aparece ningún aviso, y no hay ningún fallo — el
  camino más frecuente en la práctica, ya que el feed real de esta sesión no cubre "ahora".

**Fase 3 completa — 11/11 pasos.** Motor RAPTOR contrastado por fuerza bruta, reconstrucción
con ajuste hacia atrás, planificador cacheado con presupuesto de <1s medido en 40 ms contra
el feed real, y las cuatro pantallas de la app (pestaña, selector de sitio, detalle con
trazado real, anotación de tiempo real) verificadas a mano en el simulador. Commits
`fa01bd8`..`HEAD` en `main`. Próximo trabajo de fondo: Fase 2 (ferry) o Fase 4 (pulido) —
ver `ILoveVigoRoutes-HANDOFF.md` para su alcance, que este documento no cubre.

### Cambio posterior — geocodificación de direcciones

- [x] El selector de origen/destino acepta ahora direcciones y puntos de interés mediante
  Apple Mapas, siempre acotados a una región fija de Vigo. `MapKitAddressSearchService` queda
  aislado detrás de `AddressSearching`; `AddressSearchModel` hace debounce de 300 ms y las
  pruebas del target de app verifican el contrato con un stub, sin tocar `VigoCore`.
- [x] La interfaz distingue las direcciones de las paradas, explica qué texto se envía a Apple
  y nunca envía la ubicación del usuario. Una coordenada de `placemark` puede ser el centroide
  de una calle y no el portal exacto, así que el tramo a pie hacia una dirección es menos fino
  que el que termina en una parada.

### Cambio posterior — origen automático, 4 alternativas y mapa de navegación

- [x] **Origen por defecto = tu ubicación.** `PlacePickerView` devuelve ahora un `PickedPlace`
  (el lugar y si vino del GPS), porque `Place` no puede distinguir "Mi ubicación" de una
  dirección resuelta: las dos son `.coordinate`. `PlannerModel` guarda esa distinción en
  `originFollowsLocation`: mientras sea cierto, cada nuevo fix actualiza el origen; elegir un
  sitio a mano o intercambiar origen y destino lo apaga, y el botón "Usar mi ubicación" lo
  vuelve a encender. `PlannerModel` pasa a recibir el `JourneyPlanner` en vez del
  `AppEnvironment` entero, lo que lo hace comprobable sin CoreLocation ni base de datos en
  disco (`App/ILoveVigoRoutesTests/PlannerModelTests.swift`, 6 tests).
- [x] **4 alternativas, con salidas posteriores.** Una sola ejecución de RAPTOR solo varía los
  transbordos: todas sus opciones salen a la misma hora, y con el filtro de
  `extraTransferWorthSeconds` el resultado real era casi siempre 1. `JourneyPlanner` hace ahora
  un escaneo tipo rRAPTOR: tras cada pasada reinicia la búsqueda un segundo después del primer
  embarque encontrado, lo que obliga a la siguiente a coger un vehículo posterior. Cota doble
  (`maxDepartureScans`, y el horizonte de búsqueda como fecha límite) para que el bucle termine
  siempre. El conjunto se deduplica, se filtran los trayectos dominados (salir antes, llegar
  después y con más transbordos no es alternativa de nadie) y se ordena por llegada, con tope
  `maxAlternatives` (4). El `.prefix(3)` incrustado en `JourneyReconstruction` pasa a ser esa
  misma opción.
  Contra el feed real (Praza de América → Urzaiz, 09:00): **4 alternativas** con líneas
  distintas — 17 (9:02→9:15), 11 (9:07→9:21), 10 (9:11→9:31) y C1 (9:15→9:33), todas directas.
  Coste: 129 ms en frío (construcción del `Timetable` incluida) y **21,6 ms en caliente**, con
  el presupuesto en 1 s.
- [x] **Del minimapa al mapa de navegación.** `JourneyTraceBuilder` y `JourneyMapContent`
  (`App/ILoveVigoRoutes/Views/JourneyTrace.swift`) sacan de `JourneyDetailView` la
  construcción del trazado, el recorte por punto más cercano y los marcadores, para que las dos
  pantallas dibujen exactamente el mismo trayecto. De paso, el encuadre deja de ser "el primer
  punto con span fijo" y pasa a ser el rectángulo mínimo que contiene todo el trayecto: antes
  los recorridos largos se salían de la vista.
  El minimapa del detalle es ahora una vista previa no interactiva (`allowsHitTesting(false)`,
  sin lo cual el `Map` se come el toque y el `NavigationLink` nunca dispara) que empuja
  `JourneyMapView`: mapa a pantalla completa, `UserAnnotation`, cámara `.userLocation`
  siguiendo con rumbo, botones "Seguirme" (visible en cuanto se mueve el mapa a mano) y "Ver
  todo el trayecto". Mientras está abierto se desactiva el autobloqueo y `LocationProvider`
  pide precisión `Best`, que restaura al salir; sigue siendo permiso `WhenInUse` y solo primer
  plano, sin cambios en `Info.plist`. Sin lógica de progreso ni avisos de bajada: decisión
  explícita, porque todo eso son promesas sobre el vehículo que el horario solo no puede
  cumplir.

## Fase 4 — Lugares/trayectos guardados y refresco en segundo plano

Plan detallado en `~/.claude/plans/humble-hopping-backus.md`. Alcance: lo que pedía el
propietario (CRUD completo de lugares y trayectos guardados, orden de pestañas, estrella de
favorito unificada, refresco del GTFS en segundo plano), descartando explícitamente el widget
de WidgetKit — y con él el App Group y la reubicación de la base de datos — por complejidad
desproporcionada para lo que aporta ahora mismo.

### Hecho

- [x] **Reordenar pestañas.** `App/ILoveVigoRoutes/Views/RootView.swift`: Mapa → Planificar →
  Favoritas → Buscar → Cercanas. La pestaña de arranque sigue siendo Favoritas
  (`selection = .favourites`) — el orden de declaración de las `Tab` no decide cuál se
  selecciona al arrancar, solo el orden visual.

- [x] **`FavouritesStore`: una sola fuente de verdad para el estado de favorito.**
  `App/ILoveVigoRoutes/FavouritesStore.swift` (nuevo), propiedad de `AppEnvironment`.
  Arregla el bug real que motivó este paso: `StopDetailModel.isFavourite` se fotografiaba en
  el `init` y `FavouritesModel` guardaba su propia copia de `[Stop]`, así que marcar una
  parada en una pantalla dejaba la estrella de otra pantalla equivocada hasta que recargara
  por su cuenta. `TransitRepository` gana `favouriteStopRows()` (todas las filas, incluida la
  de una parada que el feed vigente ya no tiene) para poder decirlo en voz alta
  (`unresolvedIDs`) en vez de descartarla en silencio. `AppEnvironment.refreshFeed` recarga el
  store tras cada reimportación.
  Test de regresión: `App/ILoveVigoRoutesTests/FavouritesStoreTests.swift` — un store, dos
  lectores, mutar por un camino y comprobar que el otro lo ve.

- [x] **Estrella de favorito en todas las pantallas.**
  `App/ILoveVigoRoutes/Views/FavouriteAffordance.swift` (nuevo): `FavouriteStarButton`
  (barra), swipe (borde izquierdo) + menú contextual reutilizables vía
  `.favouriteActions(for:)`. Aplicado a `NearbyView`, `SearchView` y a las filas de parada de
  `PlacePickerView`. `StopsMapView` no necesitó nada nuevo: su hoja de selección ya empuja
  `StopDetailView`, cuya estrella pasa a leer del store. `JourneyDetailView`/`JourneyRows.swift`
  usa solo menú contextual (dos entradas explícitas, una por parada) porque una fila `.ride`
  muestra origen y destino a la vez — un swipe ahí sería ambiguo sobre cuál de los dos.

- [x] **VigoCore: persistencia de lugares y trayectos guardados.**
  `VigoCore/Sources/VigoCore/Persistence/SavedPlaceRecords.swift` (nuevo): `SavedPlace`,
  `SavedJourney`, `SavedPlaceAnchor` (`.stop` / `.orphanedStop` / `.coordinate`),
  `SavedEndpoint` (enlace vivo a un lugar guardado, con una instantánea congelada para cuando
  el enlace desaparece). Migración `"v2"` en `AppDatabase.swift` (tablas `savedPlace` y
  `savedJourney`, sin FK a `stop` — el importador la borra y reescribe entera cada semana).
  CRUD completo en `TransitRepository.swift`. Regla que gobierna todo el diseño: nunca se
  persiste un `Stop`; un lugar anclado a parada guarda `stopID` + coordenada de respaldo y se
  resuelve contra la tabla `stop` viva en cada lectura, degradando a `.orphanedStop` (todavía
  planificable) si el feed ya no la tiene.
  Verificado por tests: `SavedPlacesTests.swift` (19 tests — CRUD completo, plantillas no son
  huecos únicos, resolución contra el `Stop` vivo tras reimportar, orfandad, propagación de
  renombrados a un trayecto, `customLabel` frente a derivado, extremos ad-hoc nunca
  enlazados), `MigrationTests.swift` (datos de `v1` sobreviven a `v2`), y ampliación de
  `RepositoryTests.swift` (lugares/trayectos sobreviven a una reimportación; una favorita cuya
  parada desapareció se queda en las filas crudas pero no en la lista resuelta).

- [x] **UI de lugares y trayectos guardados.**
  `App/ILoveVigoRoutes/SavedPlacesStore.swift` (nuevo, hermano de `FavouritesStore`),
  `Views/SavedPlaceEditorView.swift` y `Views/SavedJourneyEditorView.swift` (nuevos, crear y
  editar comparten formulario). Plantillas (Casa/Trabajo/Hospital/Centro de salud/Gimnasio/
  Otro) solo prerrellenan nombre e icono al crear — no hay columna de plantilla ni singleton,
  dos lugares de la misma plantilla conviven con nombres propios.
  `FavouritesView.swift` reescrita con tres secciones (Trayectos guardados, Lugares, Paradas
  favoritas), cada una con `.onDelete`/`.onMove`/menú contextual (Editar/Duplicar/Eliminar) y
  un menú "+" para crear. Tocar un trayecto lo planifica al instante
  (`SavedJourneyPlanModel` + `.navigationDestination(item:)` hacia la mejor alternativa).
  `PlacePickerView` gana secciones "Lugares guardados" y "Trayectos guardados" (esta última
  solo cuando se le pasa un `role: .origin`/`.destination`, para elegir el extremo correcto y
  no recursar al elegir el extremo de un trayecto nuevo), más un swipe "Guardar" en filas de
  parada y de dirección resuelta (`SavedPlaceEditorView(mode: .createFrom(place))`).
  **Bug encontrado y corregido durante la verificación en el simulador:** el aviso de
  extremo "ya no existe" se disparaba también para un extremo elegido ad-hoc a propósito
  (`Elegir otro lugar`), que es `isDetached == true` por diseño, no por borrado — un aviso
  falso. Corregido para avisar solo cuando el ancla de un extremo está realmente huérfana
  (`anchor.isOrphaned`, parada que el feed ya no tiene), la única señal que de verdad se puede
  verificar.
  Verificado en el simulador (iPhone 17 Pro) contra el feed real: crear un lugar desde
  plantilla, elegir punto en el mapa, guardar; crear un trayecto con un extremo enlazado y
  otro ad-hoc; tocarlo planifica y empuja `JourneyDetailView` con el tramo real; marcar
  favorita una parada desde "Buscar" aparece de inmediato en "Favoritas" sin recargar —
  confirma en vivo el arreglo del bug de estrella desincronizada.
  Tests: `App/ILoveVigoRoutesTests/SavedPlacesStoreTests.swift` (plantillas no son
  singleton, ciclo CRUD completo, `reload()` recoge mutaciones externas), ampliación de
  `PlannerModelTests.swift` (fijar origen desde un lugar guardado usa su nombre y apaga el
  seguimiento del GPS).

- [x] **Refresco del GTFS en segundo plano.**
  `App/ILoveVigoRoutes/BackgroundRefresh.swift` + `AppDelegate.swift` (nuevos).
  `BGProcessingTask`, no `BGAppRefreshTask`: la importación descarga ~16 MB, descomprime,
  parsea y escribe ~280k filas en una sola transacción — muy por encima de lo que una ventana
  de app-refresh puede terminar. `AppDelegate` pasa a ser el único dueño de `AppEnvironment`
  (antes vivía en `@State` de `ILoveVigoRoutesApp`) porque el registro de la tarea tiene que
  ocurrir antes de que `didFinishLaunchingWithOptions` termine, y ese es el único punto del
  ciclo de vida donde eso está garantizado. `handle` llama a `environment.refreshFeed()` sin
  `force` — `GTFSFeedService.shouldCheck` ya tiene la política correcta para una ejecución
  oportunista — y reprograma siempre al terminar. El `refreshFeed()` de arranque en frío se
  mantiene como red de seguridad: iOS puede no llegar a ejecutar nunca la tarea de fondo.
  Cubre solo el feed GTFS; los endpoints de tiempo real siguen sin sondearse nunca en segundo
  plano, por diseño.
  Verificado en el simulador vía `log show`: `BGTaskScheduler` registra y envía
  `BGProcessingTaskRequest` con el identificador, `requiresNetworkConnectivity=1` y
  `requiresExternalPower=0` correctos — un identificador no declarado en
  `BGTaskSchedulerPermittedIdentifiers` habría hecho crashear la app al registrar, y no
  crasheó.

**Fase 4, parcial.** CRUD de lugares y trayectos guardados, estrella de favorito unificada,
orden de pestañas y refresco en segundo plano — hechos y verificados. Widget de WidgetKit,
atajos de Siri y accesibilidad exhaustiva quedan fuera por decisión del propietario.

## Fase 5 — El mapa como planificador

Plan detallado en `~/.claude/plans/quiero-que-me-ayudes-mapful-astrolabe.md`. Alcance: el mapa
pasa a ser la pantalla del producto — seleccionar cualquier sitio (parada, POI de Apple,
dirección, punto suelto) y planificar sin salir de ahí, con hoja por detentes; y las paradas
dejan de dibujarse por defecto, pasando a ser una capa conmutable. La pestaña "Planificar"
sigue viva a propósito hasta que el mapa cubra la lista de paridad de 11 puntos del plan.

### Hecho

- [x] **0/11 — Sonda de MapKit en dispositivo real** (`5c5ce4c`, revertida en el commit
  siguiente).
  `App/ILoveVigoRoutes/Views/Map/MapSpikeView.swift` + un botón solo en DEBUG en la barra del
  mapa. Código desechable por diseño: existe únicamente para contestar en un iPhone las cuatro
  preguntas que la interfaz del SDK no puede responder, y se borra al cerrar el paso. Queda en
  el historial por si hiciera falta rescatarla.
  **Sin simulador en ningún momento** — decisión del propietario: compilación contra
  `generic/platform=iOS` con `CODE_SIGNING_ALLOWED=NO` como único oráculo local, y la conducta
  verificada a mano en un iPhone con iOS 26.6.1.

  **Contestado por compilación** (Debug y Release, sin avisos):
  `Map(position:selection:)` con `Binding<MapSelection<StopID>?>` compila, y la etiqueta
  correcta del marcador es `.tag(MapSelection(stop.id))`, no `.tag(stop.id)`.
  `.mapFeatureSelectionAccessory(_:)` acepta un ternario a `nil`. `MapProxy.convert(_:from:)`
  dentro de `MapReader` da la coordenada de un punto de pantalla. Release compila **sin** la
  sonda, así que el `#if DEBUG` no deja referencias colgando.

  **Contestado en el iPhone:**
  - **P1 — selección mixta: SÍ.** La misma binding devuelve `.value` al tocar un `Marker`
    propio (paradas 3067 y 3027) y `.feature` al tocar un POI de Apple (Castelo do Castro,
    `MKPOICategoryCastle`; El Corte Inglés, `MKPOICategoryStore`). Esto es lo que sostiene la
    exigencia nº 1 del propietario, y era el riesgo R1 del plan: **cerrado**.
  - **P2 — `mapFeatureSelectionAccessory(nil)` apaga la tarjeta nativa: SÍ.** Los dos POIs se
    seleccionaron con el conmutador en OFF sin que Apple pintara su propia tarjeta.
  - **P3 — pulsación larga: SÍ, la receta A funciona.** `simultaneousGesture` de
    `DragGesture(minimumDistance: 0)` (que solo anota la posición del dedo) más
    `LongPressGesture(minimumDuration: 0.45)` da coordenadas correctas sin robarle el paneo al
    mapa. La receta B (retícula central) se probó como control y también funciona, pero **no
    hace falta**: el plan B queda descartado.
  - **P4 — mapa manipulable con la hoja arriba: SÍ.**

  **Dos hallazgos que NO coinciden con lo que el paso esperaba.** Se anotan porque los dos
  cambian código futuro:

  1. **Deseleccionar no pone la binding a `nil`.** Tras seleccionar El Corte Inglés y tocar
     mapa vacío, saltó la rama que la sonda llevaba puesta como detector de anomalías:
     *selección no vacía pero sin `.value` ni `.feature`*. La explicación está en la propia
     interfaz del SDK: `MapSelection` tiene `init(_ feature: MapFeature?)`, que **acepta
     `nil`**, así que al deseleccionar MapKit escribe un `MapSelection` vacío en vez de un
     `nil`. Consecuencia directa para el paso 4: tratar `selection != nil` como "hay algo
     seleccionado" dejaría la hoja abierta para siempre después de deseleccionar. La condición
     correcta es `selection?.value != nil || selection?.feature != nil`. Sin la sonda, este
     bug se habría descubierto con la hoja ya escrita.
  2. **El mapa seguía manipulable en el detente `.large`**, con
     `presentationBackgroundInteraction(.enabled(upThrough: .fraction(0.45)))`, que debería
     haberlo bloqueado a partir de medio. La pregunta que de verdad importaba —¿se puede
     mover el mapa con la hoja en el detente pequeño?— no se anotó por separado, pero queda
     contestada por implicación: `upThrough` es monótono, así que si la interacción está viva
     por encima del umbral, lo está también por debajo. El diseño no cambia y el efecto es
     benigno (en `.large` la hoja tapa casi todo el mapa de todas formas), pero el modificador
     **no se puede usar como si bloqueara nada**: si algún día hace falta bloquear de verdad,
     habrá que medirlo otra vez en iOS 26.

  **Detalle menor para el paso 4:** `MapFeature.pointOfInterestCategory` devuelve el valor
  crudo (`MKPOICategoryStore`). Como subtítulo hay que traducirlo, no pintarlo tal cual.

  La sonda y su botón de DEBUG se eliminan en el commit que cierra este paso.

- [x] **1/11 — `MapPlace` + `MapNavigationState`, en `VigoCore`**
  `VigoCore/Sources/VigoCore/MapFlow/MapPlace.swift`, `MapNavigationState.swift`;
  tests en `VigoCore/Tests/VigoCoreTests/MapNavigationStateTests.swift` (17 tests).

  **Desviación del plan, por la restricción de "sin simulador".** El plan situaba
  `MapScreenModel` entero en el target de app. Los tests del target de app necesitan un
  simulador para correr, así que aquí no habría podido verificar nada yo. El tipo se parte en
  dos por esa línea:
  - `MapNavigationState` — **`struct` en `VigoCore`**, con todas las transiciones como
    métodos `mutating` puros. Es el 100% de la lógica del flujo, y lo cubre `swift test` en
    el Mac sin simulador ni dispositivo.
  - `MapScreenModel` — el `@Observable @MainActor` del target de app, que poseerá uno de
    estos y añadirá solo lo que de verdad necesita un dispositivo: la llamada al planificador,
    el geocodificador, `@AppStorage` y CoreLocation. Se escribe en el paso 3, con la vista.

  No es un contorsionismo para poder probar: la partición cae donde ya estaba la costura. Lo
  que queda en la app es exactamente lo que no es una función pura del estado.

  `MapPlace` es `Place` más procedencia (`.stop` / `.pointOfInterest` / `.address` /
  `.savedPlace` / `.droppedPin` / `.currentLocation`), porque `Place` aplana en
  `.coordinate(_, label:)` todo lo que no es parada y la ficha del mapa necesita saber si hay
  una `Stop` detrás (llegadas en vivo, estrella de favorito), qué escribir de subtítulo y qué
  glifo dibujar. La Fase 3 ya había tenido que recuperar **un** bit de eso con `PickedPlace`;
  aquí hacen falta más. `Origin.pointOfInterest` no lleva `MKPointOfInterestCategory`: MapKit
  no entra en este paquete, y su valor crudo (`MKPOICategoryStore`) no es texto para enseñar
  a nadie — la app lo traduce antes de construir el `MapPlace`. Es el hallazgo menor del
  paso 0, ya cerrado.

  `MapNavigationState` fija la regla que sostiene la pantalla: **las vistas no deciden
  transiciones**. Un gesto se traduce en una llamada, y la vista dibuja lo que dice `mode`.
  Lo que hay dentro, con su razón:
  - `dismiss()` es **una sola tabla**: `.journeyDetail → .routing → ficha del destino →
    mapa limpio`, con `.browsing` como suelo. Repartida entre los gestos de la hoja (arrastrar,
    X, tocar fuera) dejaría de ser predecible, que es justo lo que se nota al usarla.
  - `clearSelection()` existe por el **hallazgo nº 1 del paso 0**: deseleccionar deja un
    `MapSelection` no nulo y vacío, así que la vista no puede usar "binding != nil" como
    "hay selección". Y solo cierra la ficha: deseleccionar un pin no cancela una ruta.
  - `invalidateResult()` tira el resultado en cuanto cambia la pregunta. Sin él, el mapa
    seguiría pintando el trazado anterior bajo unos extremos recién editados, y un detalle
    abierto sería el de una ruta que ya nadie pidió.
  - `planningFinished(.journeys([]))` **no** es un éxito vacío: se pliega a fallo. Una lista
    vacía en pantalla diría "hay opciones y no caben" cuando lo cierto es que no hay ninguna.
  - `originFollowsLocation` repite el contrato que la Fase 3 fijó para `PlannerModel`, y
    `swapEnds()` lo apaga: sin eso, el siguiente fix del GPS deshace el intercambio en
    silencio.
  - `routeQuery(now:)` recibe el reloj en vez de leerlo, por la misma razón que el paso de
    deuda de la Fase 3 (`f4a1282`) tuvo que arreglar en `GTFSImporter`: un test que depende
    de la hora real solo pasa a ciertas horas.

  **Verificado por mutación, seis veces** — los 17 tests pasaron a la primera, que es
  exactamente la señal que el paso 3/11 de la Fase 3 dejó escrita como sospechosa. Cada una de
  estas mutaciones tumba al menos un test: (1) `swapEnds` sin apagar el seguimiento del GPS;
  (2) `invalidateResult` sin salir del detalle; (3) `clearSelection` sin el guard de modo;
  (4) lista vacía tratada como éxito; (5) `dismiss` saltando del detalle al mapa limpio;
  (6) `selectAlternative` sin comprobar el índice.

  Suite de `VigoCore`: **211 tests en verde** (194 antes de la Fase 5, +17). Target de app sin
  cambios; Debug y Release compilan contra `generic/platform=iOS`.


## Verificación rápida del estado

```bash
cd VigoCore && swift test 2>&1 | tail -3
xcodebuild -scheme ILoveVigoRoutes -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
git log --oneline -5
```
Al escribir este documento: **211 tests de `VigoCore` en verde** (170 antes de la Fase 4;
+24 en la Fase 4 entre `SavedPlacesTests`, `MigrationTests` y `RepositoryTests`; +17 en la
Fase 5 en `MapNavigationStateTests`), incluida la suite del feed real con `VIGO_GTFS_ZIP`
apuntando al archivo publicado, y **23 tests del target de app** (12 antes de la Fase 4; +5
en `FavouritesStoreTests`, +5 en `SavedPlacesStoreTests`, +1 en `PlannerModelTests`).

Desde la Fase 5 el propietario prueba **solo en dispositivo**, no en simulador. Aquí se
verifica con `swift test` (que corre en el Mac) y con compilación contra
`generic/platform=iOS`; los tests del target de app requieren simulador y por tanto los
ejecuta él. Es la razón por la que la lógica nueva del mapa vive en `VigoCore` y no en la
app.
